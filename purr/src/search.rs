//! Search Engine (Tantivy with bucket ranking + word-level highlighting)
//!
//! Tantivy handles retrieval via trigram indexing with per-word PhraseQuery boosts.
//! Phase 2 bucket re-ranking (in indexer.rs) provides Milli-style lexicographic
//! ranking. Highlighting uses `does_word_match` from the ranking module to ensure
//! what's highlighted matches what's ranked (exact, prefix, fuzzy edit-distance).
//! Short queries (< 3 chars) use a streaming fallback.

use crate::indexer::{Indexer, IndexerResult, SearchCandidate};
use crate::interface::{HighlightKind, HighlightRange, MatchData, ItemMatch};
use crate::models::StoredItem;
use crate::ranking::{does_word_match, WordMatchKind};
use chrono::Utc;
use tokio_util::sync::CancellationToken;

/// Maximum results to return from search.
pub(crate) const MAX_RESULTS: usize = 2000;

pub(crate) const MIN_TRIGRAM_QUERY_LEN: usize = 3;

/// Maximum recency boost multiplier for Phase 1 trigram recall.
/// 0.5 = up to 50% boost for brand new items, ensuring recent items make the candidate set.
pub(crate) const RECENCY_BOOST_MAX: f64 = 0.5;
/// Half-life for recency decay: 3 days (stronger recency bias than 7-day default)
pub(crate) const RECENCY_HALF_LIFE_SECS: f64 = 3.0 * 24.0 * 60.0 * 60.0;

/// Boost factor for prefix matches in short query scoring
const PREFIX_MATCH_BOOST: f64 = 2.0;

/// Boost for entries where highlighted chars cover most of the document.
const COVERAGE_BOOST_MAX: f64 = 3.0;
const COVERAGE_BOOST_THRESHOLD: f64 = 0.4;

/// Boost for matches starting in the first N characters of content.
const POSITION_BOOST_MAX: f64 = 1.5;
const POSITION_BOOST_MIN: f64 = 1.1;
const POSITION_BOOST_WINDOW: usize = 50;

/// Context chars to include before/after match in snippet
pub(crate) const SNIPPET_CONTEXT_CHARS: usize = 200;

#[derive(Debug, Clone)]
pub(crate) struct FuzzyMatch {
    pub(crate) id: i64,
    pub(crate) score: f64,
    pub(crate) highlight_ranges: Vec<HighlightRange>,
    pub(crate) timestamp: i64,
    pub(crate) content: String,
    /// Whether this was a prefix match (for short query scoring)
    pub(crate) is_prefix_match: bool,
}

/// Search using Tantivy with bucket re-ranking for trigram queries (>= 3 chars).
/// Phase 1 (trigram recall) and Phase 2 (bucket re-ranking) happen inside indexer.search().
/// This function handles highlighting via rayon parallelism with cancellation support.
pub(crate) fn search_trigram(indexer: &Indexer, query: &str, token: &CancellationToken) -> IndexerResult<Vec<FuzzyMatch>> {
        if query.trim().is_empty() {
            return Ok(Vec::new());
        }
        let trimmed = query.trim_start();
        let query_words_owned = tokenize_words(trimmed.trim_end());
        let query_words: Vec<&str> = query_words_owned.iter().map(|(_, _, w)| w.as_str()).collect();
        let last_word_is_prefix = trimmed.trim_end().ends_with(|c: char| c.is_alphanumeric());

        // Bucket-ranked candidates from two-phase search
        #[cfg(feature = "perf-log")]
        let t0 = std::time::Instant::now();
        let candidates = indexer.search(trimmed.trim_end(), MAX_RESULTS)?;
        #[cfg(feature = "perf-log")]
        let num_candidates = candidates.len();

        // Assign rank before parallelizing so we can restore bucket order after
        let ranked: Vec<(usize, SearchCandidate)> = candidates.into_iter().enumerate().collect();

        #[cfg(feature = "perf-log")]
        let t1 = std::time::Instant::now();
        use rayon::prelude::*;
        let mut sorted: Vec<FuzzyMatch> = ranked
            .into_par_iter()
            .take_any_while(|_| !token.is_cancelled())
            .map(|(rank, c)| {
                let mut m = highlight_candidate(c.id, c.content(), c.content_lower(), c.doc_words(), c.timestamp, c.tantivy_score, &query_words, last_word_is_prefix);
                // Preserve bucket ranking order: score = inverse rank so sort is stable
                m.score = (MAX_RESULTS - rank) as f64;
                m
            })
            .filter(|m| !m.highlight_ranges.is_empty())
            .collect();

        // par_iter + take_any_while doesn't preserve order — restore bucket ranking
        sorted.sort_unstable_by(|a, b| b.score.total_cmp(&a.score));

        #[cfg(feature = "perf-log")]
        {
            let t2 = std::time::Instant::now();
            eprintln!(
                "[perf] indexer_total={:.1}ms highlight={:.1}ms candidates={} highlighted={}",
                (t1 - t0).as_secs_f64() * 1000.0,
                (t2 - t1).as_secs_f64() * 1000.0,
                num_candidates,
                sorted.len(),
            );
        }

    Ok(sorted)
}

/// Score candidates for short queries (< 3 chars)
/// Uses recency as primary metric with prefix match boost
pub(crate) fn score_short_query_batch(
    candidates: impl Iterator<Item = (i64, String, i64, bool)> + Send, // (id, content, timestamp, is_prefix)
    query: &str,
    token: &CancellationToken,
) -> Vec<FuzzyMatch> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Vec::new();
        }

        let query_lower = trimmed.to_lowercase();
        let now = Utc::now().timestamp();

        use rayon::prelude::*;
        let query_len = query_lower.len();
        let mut results: Vec<FuzzyMatch> = candidates
            .par_bridge()
            .take_any_while(|_| !token.is_cancelled())
            .filter_map(|(id, content, timestamp, is_prefix_match)| {
                let content_lower = content.to_lowercase();

                // Find ALL match positions for highlighting (not just the first)
                let positions: Vec<usize> = content_lower
                    .match_indices(&query_lower)
                    .map(|(pos, _)| pos)
                    .collect();
                if positions.is_empty() {
                    return None;
                }

                let highlight_ranges: Vec<HighlightRange> = positions.iter()
                    .map(|&pos| HighlightRange {
                        start: pos as u64,
                        end: (pos + query_len) as u64,
                        kind: HighlightKind::Exact,
                    })
                    .collect();

                // Score based on recency with prefix boost
                let base_score = 1000.0_f64;
                let mut score = if is_prefix_match {
                    base_score * PREFIX_MATCH_BOOST
                } else {
                    base_score
                };

                // Word-boundary boost: prefer "hi there" over "within" for query "hi"
                let chars: Vec<char> = content_lower.chars().collect();
                let has_word_boundary_match = positions.iter().any(|&pos| {
                    let at_start = pos == 0 || !chars.get(pos - 1).map_or(false, |c| c.is_alphanumeric());
                    let at_end = pos + query_len >= chars.len()
                        || !chars.get(pos + query_len).map_or(false, |c| c.is_alphanumeric());
                    at_start && at_end
                });
                if has_word_boundary_match {
                    score *= PREFIX_MATCH_BOOST;
                }

                // Coverage boost
                let content_char_len = chars.len().max(1);
                let matched_char_count: u64 = highlight_ranges.iter().map(|r| r.end - r.start).sum();
                let coverage = matched_char_count as f64 / content_char_len as f64;
                if coverage > COVERAGE_BOOST_THRESHOLD {
                    let t = (coverage - COVERAGE_BOOST_THRESHOLD) / (1.0 - COVERAGE_BOOST_THRESHOLD);
                    score *= 1.0 + (COVERAGE_BOOST_MAX - 1.0) * t;
                }

                // Position boost for matches near the start
                if positions[0] < POSITION_BOOST_WINDOW {
                    let t = 1.0 - (positions[0] as f64 / POSITION_BOOST_WINDOW as f64);
                    let boost = POSITION_BOOST_MIN + (POSITION_BOOST_MAX - POSITION_BOOST_MIN) * t;
                    score *= boost;
                }

                Some(FuzzyMatch {
                    id,
                    score,
                    highlight_ranges,
                    timestamp,
                    content,
                    is_prefix_match,
                })
            })
            .collect();

        // Sort by blended score (recency primary, prefix boost)
        results.sort_unstable_by(|a, b| {
            let score_a = recency_weighted_score(a.score, a.timestamp, now, a.is_prefix_match);
            let score_b = recency_weighted_score(b.score, b.timestamp, now, b.is_prefix_match);
            score_b.total_cmp(&score_a).then_with(|| b.timestamp.cmp(&a.timestamp))
        });

    results.truncate(MAX_RESULTS);
    results
}

/// Map a `WordMatchKind` from ranking to a `HighlightKind` for the UI.
fn word_match_to_highlight_kind(wmk: WordMatchKind) -> HighlightKind {
    match wmk {
        WordMatchKind::Exact => HighlightKind::Exact,
        WordMatchKind::Prefix => HighlightKind::Prefix,
        WordMatchKind::Fuzzy(_) => HighlightKind::Fuzzy,
        WordMatchKind::Subsequence(_) => HighlightKind::Subsequence,
        WordMatchKind::None => HighlightKind::Exact, // unreachable in practice
    }
}

/// Highlight a candidate using the same word-matching criteria as ranking
/// (exact, prefix, fuzzy edit-distance) via `does_word_match`. This ensures
/// what's highlighted matches what was ranked in Phase 2 bucket scoring.
///
/// `content_lower` and `doc_words` are pre-computed in Phase 2 to avoid
/// redundant lowercasing and tokenization (~4000 allocations per search).
pub(crate) fn highlight_candidate(
        id: i64,
        content: &str,
        _content_lower: &str,
        doc_words: &[(usize, usize, String)],
        timestamp: i64,
        tantivy_score: f32,
        query_words: &[&str],
        last_word_is_prefix: bool,
    ) -> FuzzyMatch {
        let mut word_highlights: Vec<(usize, usize, HighlightKind)> = Vec::new();
        let mut matched_query_words = vec![false; query_words.len()];

        let query_lower: Vec<String> = query_words.iter().map(|w| w.to_lowercase()).collect();
        let last_qi = query_lower.len().saturating_sub(1);

        for (char_start, char_end, doc_word) in doc_words {
            for (qi, qw) in query_lower.iter().enumerate() {
                let allow_prefix = qi == last_qi && last_word_is_prefix;
                let wmk = does_word_match(qw, doc_word, allow_prefix);
                if wmk != WordMatchKind::None {
                    matched_query_words[qi] = true;
                    word_highlights.push((*char_start, *char_end, word_match_to_highlight_kind(wmk)));
                    break; // Don't double-highlight from multiple query words
                }
            }
        }

        // Sort by start position
        word_highlights.sort_unstable_by_key(|&(s, _, _)| s);

        // Bridge gaps between adjacent highlighted ranges where intervening chars are all
        // non-whitespace punctuation or ranges are directly adjacent (e.g. "://" in URLs,
        // "." in domains, "/" in paths). Inherit the first range's kind.
        let content_chars: Vec<char> = content.chars().collect();
        let mut bridged: Vec<(usize, usize, HighlightKind)> = Vec::with_capacity(word_highlights.len());
        for wh in &word_highlights {
            if let Some(last) = bridged.last_mut() {
                let gap_start = last.1;
                let gap_end = wh.0;
                if gap_start <= gap_end
                    && gap_end <= content_chars.len()
                    && (gap_start == gap_end
                        || content_chars[gap_start..gap_end]
                            .iter()
                            .all(|c| !c.is_alphanumeric() && !c.is_whitespace()))
                {
                    // Merge into previous range, inheriting its kind
                    last.1 = wh.1;
                    continue;
                }
            }
            bridged.push(*wh);
        }

        // Convert to HighlightRange
        let highlight_ranges: Vec<HighlightRange> = bridged
            .iter()
            .map(|&(s, e, k)| HighlightRange { start: s as u64, end: e as u64, kind: k })
            .collect();

        // Start with tantivy score for display scoring (coverage/position boosts)
        let mut score = tantivy_score as f64;

        if !highlight_ranges.is_empty() {
            let content_char_len = content.chars().count().max(1);
            let matched_char_count: usize = highlight_ranges.iter().map(|r| (r.end - r.start) as usize).sum();

            // Coverage boost based on unique query words matched
            let unique_matched = matched_query_words.iter().filter(|&&m| m).count();
            let query_coverage = unique_matched as f64 / query_words.len().max(1) as f64;
            let content_coverage = matched_char_count as f64 / content_char_len as f64;
            let coverage = query_coverage.min(content_coverage);
            if coverage > COVERAGE_BOOST_THRESHOLD {
                let t = (coverage - COVERAGE_BOOST_THRESHOLD) / (1.0 - COVERAGE_BOOST_THRESHOLD);
                score *= 1.0 + (COVERAGE_BOOST_MAX - 1.0) * t;
            }

            // Position boost
            let first_match_pos = highlight_ranges[0].start as usize;
            if first_match_pos < POSITION_BOOST_WINDOW {
                let t = 1.0 - (first_match_pos as f64 / POSITION_BOOST_WINDOW as f64);
                let boost = POSITION_BOOST_MIN + (POSITION_BOOST_MAX - POSITION_BOOST_MIN) * t;
                score *= boost;
            }
        }

    FuzzyMatch {
        id,
        score,
        highlight_ranges,
        timestamp,
        content: content.to_string(),
        is_prefix_match: false,
    }
}

/// Convert matched indices to highlight ranges with a specified kind
#[cfg(test)]
fn indices_to_ranges_with_kind(indices: &[u32], kind: HighlightKind) -> Vec<HighlightRange> {
    if indices.is_empty() { return Vec::new(); }

    let mut sorted = indices.to_vec();
    sorted.sort_unstable();
    sorted.dedup();

    sorted[1..].iter().fold(vec![(sorted[0], sorted[0] + 1)], |mut acc, &idx| {
        let last = acc.last_mut().unwrap();
        if idx == last.1 { last.1 = idx + 1; } else { acc.push((idx, idx + 1)); }
        acc
    }).into_iter().map(|(start, end)| HighlightRange { start: start as u64, end: end as u64, kind }).collect()
}

/// Convert matched indices to highlight ranges (defaults to Exact kind)
#[cfg(test)]
fn indices_to_ranges(indices: &[u32]) -> Vec<HighlightRange> {
    indices_to_ranges_with_kind(indices, HighlightKind::Exact)
}

/// Find the highlight in the densest cluster of highlights using a sliding window.
pub(crate) fn find_densest_highlight(highlights: &[HighlightRange], window_size: u64) -> Option<usize> {
    if highlights.is_empty() {
        return None;
    }
    if highlights.len() == 1 {
        return Some(0);
    }

    let mut indexed: Vec<(usize, &HighlightRange)> = highlights.iter().enumerate().collect();
    indexed.sort_by_key(|(_, h)| h.start);

    let mut left = 0;
    let mut best_left = 0;
    let mut best_coverage = 0u64;
    let mut current_coverage = 0u64;

    for right in 0..indexed.len() {
        while indexed[left].1.start + window_size <= indexed[right].1.start {
            current_coverage -= indexed[left].1.end - indexed[left].1.start;
            left += 1;
        }
        current_coverage += indexed[right].1.end - indexed[right].1.start;

        if current_coverage > best_coverage {
            best_coverage = current_coverage;
            best_left = left;
        }
    }

    Some(indexed[best_left].0)
}

/// Generate a generous text snippet around the densest cluster of highlights.
pub fn generate_snippet(content: &str, highlights: &[HighlightRange], max_len: usize) -> (String, Vec<HighlightRange>, u64) {
    let content_char_len = content.chars().count();

    if highlights.is_empty() {
        let preview = normalize_snippet(content, 0, content_char_len, max_len);
        return (preview, Vec::new(), 0);
    }

    let density_window = SNIPPET_CONTEXT_CHARS as u64;
    let center_idx = find_densest_highlight(highlights, density_window).unwrap_or(0);
    let center_highlight = &highlights[center_idx];
    let match_start_char = center_highlight.start as usize;
    let match_end_char = center_highlight.end as usize;

    let line_number = content
        .chars()
        .take(match_start_char.min(content_char_len))
        .filter(|&c| c == '\n')
        .count() as u64
        + 1;

    let match_char_len = match_end_char.saturating_sub(match_start_char);
    let remaining_space = max_len.saturating_sub(match_char_len);

    let context_before = (remaining_space / 2).min(SNIPPET_CONTEXT_CHARS).min(match_start_char);
    let context_after = (remaining_space - context_before).min(content_char_len.saturating_sub(match_end_char));

    let mut snippet_start_char = match_start_char - context_before;
    let snippet_end_char = (match_end_char + context_after).min(content_char_len);

    if snippet_start_char > 0 {
        let search_start_char = snippet_start_char.saturating_sub(10);
        let search_range: String = content
            .chars()
            .skip(search_start_char)
            .take(snippet_start_char - search_start_char)
            .collect();
        if let Some(space_pos) = search_range.rfind(char::is_whitespace) {
            if search_range.is_char_boundary(space_pos) {
                let char_offset = search_range[..space_pos].chars().count();
                let new_start = search_start_char + char_offset + 1;
                if new_start <= match_start_char.saturating_sub(context_before) {
                    snippet_start_char = new_start;
                }
            }
        }
    }

    let ellipsis_reserve = (if snippet_start_char > 0 { 1 } else { 0 })
        + (if snippet_end_char < content_char_len { 1 } else { 0 });
    let effective_max_len = max_len.saturating_sub(ellipsis_reserve);
    let (normalized_snippet, pos_map) = normalize_snippet_with_mapping(content, snippet_start_char, snippet_end_char, effective_max_len);

    let truncated_from_start = snippet_start_char > 0;
    let truncated_from_end = snippet_end_char < content_char_len;

    let prefix_offset = if truncated_from_start { 1 } else { 0 };
    let mut final_snippet = if truncated_from_start {
        format!("\u{2026}{}", normalized_snippet)
    } else {
        normalized_snippet.clone()
    };
    if truncated_from_end {
        final_snippet.push('\u{2026}');
    }

    let adjusted_highlights: Vec<HighlightRange> = highlights
        .iter()
        .filter_map(|h| {
            let orig_start = (h.start as usize).checked_sub(snippet_start_char)?;
            let orig_end = (h.end as usize).saturating_sub(snippet_start_char);

            let norm_start = map_position(orig_start, &pos_map)?;
            let norm_end = map_position(orig_end, &pos_map).unwrap_or(normalized_snippet.len());

            if norm_start < normalized_snippet.len() {
                Some(HighlightRange {
                    start: (norm_start + prefix_offset) as u64,
                    end: (norm_end.min(normalized_snippet.len()) + prefix_offset) as u64,
                    kind: h.kind,
                })
            } else {
                None
            }
        })
        .collect();

    (final_snippet, adjusted_highlights, line_number)
}

/// Create MatchData from a FuzzyMatch
pub(crate) fn create_match_data(fuzzy_match: &FuzzyMatch) -> MatchData {
    let full_content_highlights = fuzzy_match.highlight_ranges.clone();
    let max_len = SNIPPET_CONTEXT_CHARS * 2;
    let (text, adjusted_highlights, line_number) = generate_snippet(
        &fuzzy_match.content,
        &full_content_highlights,
        max_len,
    );

    let densest_highlight_start = find_densest_highlight(&full_content_highlights, SNIPPET_CONTEXT_CHARS as u64)
        .map(|idx| full_content_highlights[idx].start)
        .unwrap_or(0);

    MatchData {
        text,
        highlights: adjusted_highlights,
        line_number,
        full_content_highlights,
        densest_highlight_start,
    }
}

/// Create ItemMatch from StoredItem and FuzzyMatch
pub(crate) fn create_item_match(item: &StoredItem, fuzzy_match: &FuzzyMatch) -> ItemMatch {
    ItemMatch {
        item_metadata: item.to_metadata(),
        match_data: create_match_data(fuzzy_match),
    }
}

/// Tokenize text into tokens with char offsets.
/// Produces both alphanumeric word tokens and non-whitespace punctuation tokens.
/// Whitespace is skipped (acts as a separator).
/// Punctuation tokens allow matching symbols like "://", ".", "/" in URLs/paths.
pub(crate) fn tokenize_words(content: &str) -> Vec<(usize, usize, String)> {
    let chars: Vec<char> = content.chars().collect();
    let mut tokens = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i].is_whitespace() {
            i += 1;
            continue;
        }
        let start = i;
        if chars[i].is_alphanumeric() {
            while i < chars.len() && chars[i].is_alphanumeric() {
                i += 1;
            }
        } else {
            while i < chars.len() && !chars[i].is_alphanumeric() && !chars[i].is_whitespace() {
                i += 1;
            }
        }
        let token: String = chars[start..i].iter().collect();
        tokens.push((start, i, token));
    }
    tokens
}

/// Whether a token from `tokenize_words` is an alphanumeric word (vs punctuation).
/// Tokens are homogeneous runs — either all alphanumeric or all punctuation —
/// so checking the first character is sufficient.
pub(crate) fn is_word_token(token: &str) -> bool {
    token.starts_with(|c: char| c.is_alphanumeric())
}

/// Combine a base relevance score with exponential recency decay and prefix boost.
fn recency_weighted_score(fuzzy_score: f64, timestamp: i64, now: i64, is_prefix_match: bool) -> f64 {
    let base_score = fuzzy_score;

    let age_secs = (now - timestamp).max(0) as f64;
    let recency_factor = (-age_secs * 2.0_f64.ln() / RECENCY_HALF_LIFE_SECS).exp();

    let prefix_boost = if is_prefix_match { PREFIX_MATCH_BOOST } else { 1.0 };

    base_score * prefix_boost * (1.0 + RECENCY_BOOST_MAX * recency_factor)
}

fn normalize_snippet_with_mapping(content: &str, start: usize, end: usize, max_chars: usize) -> (String, Vec<usize>) {
    if end <= start {
        return (String::new(), vec![0]);
    }

    let mut result = String::with_capacity(max_chars);
    let mut pos_map = Vec::with_capacity(end - start + 1);
    let mut last_was_space = false;
    let mut norm_idx = 0;

    for ch in content.chars().skip(start).take(end - start) {
        pos_map.push(norm_idx);

        if norm_idx >= max_chars {
            continue;
        }

        let ch = match ch {
            '\n' | '\t' | '\r' => ' ',
            c => c,
        };

        if ch == ' ' {
            if last_was_space {
                continue;
            }
            last_was_space = true;
        } else {
            last_was_space = false;
        }

        result.push(ch);
        norm_idx += 1;
    }

    pos_map.push(norm_idx);

    if result.ends_with(' ') {
        result.pop();
    }

    (result, pos_map)
}

fn map_position(orig_pos: usize, pos_map: &[usize]) -> Option<usize> {
    pos_map.get(orig_pos).copied()
}

fn normalize_snippet(content: &str, start: usize, end: usize, max_chars: usize) -> String {
    normalize_snippet_with_mapping(content, start, end, max_chars).0
}

/// Generate a preview from content (no highlights, starts from beginning)
pub fn generate_preview(content: &str, max_chars: usize) -> String {
    let trimmed = content.trim_start();
    let (preview, _, _) = generate_snippet(trimmed, &[], max_chars);
    preview
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_indices_to_ranges() {
        let indices = vec![0, 1, 2, 5, 6, 10];
        let ranges = super::indices_to_ranges(&indices);
        assert_eq!(ranges.len(), 3);
        assert_eq!(ranges[0], HighlightRange { start: 0, end: 3, kind: HighlightKind::Exact });
        assert_eq!(ranges[1], HighlightRange { start: 5, end: 7, kind: HighlightKind::Exact });
        assert_eq!(ranges[2], HighlightRange { start: 10, end: 11, kind: HighlightKind::Exact });
    }

    /// Helper: create a HighlightRange with Exact kind (for tests that don't care about kind)
    fn hr(start: u64, end: u64) -> HighlightRange {
        HighlightRange { start, end, kind: HighlightKind::Exact }
    }

    #[test]
    fn test_generate_snippet_basic() {
        let content = "This is a long text with some interesting content that we want to highlight";
        let highlights = vec![hr(28, 39)];
        let (snippet, adj_highlights, _line) = super::generate_snippet(content, &highlights, 50);
        assert!(snippet.contains("interesting"));
        assert!(!adj_highlights.is_empty());
    }

    #[test]
    fn test_snippet_contains_match_mid_content() {
        let content = "The quick brown fox jumps over the lazy dog and runs away fast";
        let highlights = vec![hr(35, 39)];
        let (snippet, adj_highlights, _) = super::generate_snippet(content, &highlights, 30);
        assert!(snippet.contains("lazy"), "Snippet should contain the match");
        assert!(!adj_highlights.is_empty());
        let h = &adj_highlights[0];
        let highlighted: String = snippet.chars()
            .skip(h.start as usize)
            .take((h.end - h.start) as usize)
            .collect();
        assert_eq!(highlighted, "lazy");
    }

    #[test]
    fn test_snippet_match_at_start() {
        let content = "Hello world";
        let highlights = vec![hr(0, 5)];
        let (snippet, adj_highlights, _) = super::generate_snippet(content, &highlights, 50);
        assert_eq!(adj_highlights[0].start, 0, "Highlight should start at 0");
        assert_eq!(snippet, "Hello world");
    }

    #[test]
    fn test_snippet_normalizes_whitespace() {
        let content = "Line one\n\nLine two";
        let highlights = vec![hr(0, 4)];
        let (snippet, adj_highlights, _) = super::generate_snippet(content, &highlights, 50);
        assert!(!snippet.contains('\n'));
        assert!(!snippet.contains("  "));
        let h = &adj_highlights[0];
        let highlighted: String = snippet.chars()
            .skip(h.start as usize)
            .take((h.end - h.start) as usize)
            .collect();
        assert_eq!(highlighted, "Line");
    }

    #[test]
    fn test_snippet_highlight_adjustment_long_content() {
        let content = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaTARGET text here";
        let highlights = vec![hr(46, 52)];
        let (snippet, adj_highlights, _) = super::generate_snippet(content, &highlights, 30);
        assert!(snippet.contains("TARGET"));
        let h = &adj_highlights[0];
        let highlighted: String = snippet.chars()
            .skip(h.start as usize)
            .take((h.end - h.start) as usize)
            .collect();
        assert_eq!(highlighted, "TARGET");
    }

    #[test]
    fn test_snippet_very_long_content() {
        let long_prefix = "a".repeat(100);
        let long_suffix = "z".repeat(100);
        let content = format!("{}MATCH{}", long_prefix, long_suffix);
        let highlights = vec![hr(100, 105)];
        let (snippet, adj_highlights, _) = super::generate_snippet(&content, &highlights, 30);
        assert!(snippet.contains("MATCH"));
        let h = &adj_highlights[0];
        let highlighted: String = snippet.chars()
            .skip(h.start as usize)
            .take((h.end - h.start) as usize)
            .collect();
        assert_eq!(highlighted, "MATCH");
    }

    #[test]
    fn test_recency_weighted_score() {
        let now = 1700000000i64;
        let recent = recency_weighted_score(1000.0, now, now, false);
        let old = recency_weighted_score(1000.0, now - 86400 * 30, now, false);
        assert!(recent > old, "Recent items should score higher with same quality");
        let prefix = recency_weighted_score(1000.0, now, now, true);
        let non_prefix = recency_weighted_score(1000.0, now, now, false);
        assert!(prefix > non_prefix, "Prefix matches should score higher");
    }

    #[test]
    fn test_snippet_utf8_multibyte_chars() {
        let content = "Hello \u{4f60}\u{597d} world \u{1f30d} test";
        let highlights = vec![hr(6, 8)];
        let (snippet, adj_highlights, _) = super::generate_snippet(content, &highlights, 50);
        assert!(snippet.contains("\u{4f60}\u{597d}"));
        assert!(!adj_highlights.is_empty());
        let h = &adj_highlights[0];
        let highlighted: String = snippet.chars()
            .skip(h.start as usize)
            .take((h.end - h.start) as usize)
            .collect();
        assert_eq!(highlighted, "\u{4f60}\u{597d}");
    }

    // ── Word-level highlighting tests (using does_word_match) ────

    #[test]
    fn test_tokenize_words() {
        // Whitespace-separated words
        let words = tokenize_words("hello world");
        assert_eq!(words, vec![(0, 5, "hello".into()), (6, 11, "world".into())]);

        // Punctuation produces separate tokens
        let words = tokenize_words("urlparser.parse(input)");
        assert_eq!(words, vec![
            (0, 9, "urlparser".into()),
            (9, 10, ".".into()),
            (10, 15, "parse".into()),
            (15, 16, "(".into()),
            (16, 21, "input".into()),
            (21, 22, ")".into()),
        ]);

        // Consecutive punctuation forms one token
        let words = tokenize_words("one--two...three");
        assert_eq!(words, vec![
            (0, 3, "one".into()),
            (3, 5, "--".into()),
            (5, 8, "two".into()),
            (8, 11, "...".into()),
            (11, 16, "three".into()),
        ]);

        // URL tokenization preserves :// as a token
        let words = tokenize_words("https://github.com");
        assert_eq!(words, vec![
            (0, 5, "https".into()),
            (5, 8, "://".into()),
            (8, 14, "github".into()),
            (14, 15, ".".into()),
            (15, 18, "com".into()),
        ]);

    }

    /// Helper: call highlight_candidate with automatic lowercasing/tokenization.
    fn hc(id: i64, content: &str, timestamp: i64, tantivy_score: f32, query_words: &[&str], last_word_is_prefix: bool) -> FuzzyMatch {
        let content_lower = content.to_lowercase();
        let doc_words = tokenize_words(&content_lower);
        super::highlight_candidate(id, content, &content_lower, &doc_words, timestamp, tantivy_score, query_words, last_word_is_prefix)
    }

    fn highlighted_words(content: &str, query_words: &[&str]) -> Vec<String> {
        let fm = hc(1, content, 1000, 1.0, query_words, false);
        let chars: Vec<char> = content.chars().collect();
        fm.highlight_ranges.iter().map(|r| {
            chars[r.start as usize..r.end as usize].iter().collect()
        }).collect()
    }

    #[test]
    fn test_highlight_exact_match() {
        let words = highlighted_words("hello world", &["hello"]);
        assert_eq!(words, vec!["hello"]);
    }

    #[test]
    fn test_highlight_typo_match() {
        let words = highlighted_words("Visit Riverside Park today", &["riversde"]);
        assert_eq!(words, vec!["Riverside"]);
    }

    #[test]
    fn test_highlight_prefix_match() {
        let fm = hc(1, "Run testing suite now", 1000, 1.0, &["test"], true);
        let chars: Vec<char> = "Run testing suite now".chars().collect();
        let words: Vec<String> = fm.highlight_ranges.iter().map(|r| {
            chars[r.start as usize..r.end as usize].iter().collect()
        }).collect();
        assert_eq!(words, vec!["testing"]);
    }

    #[test]
    fn test_highlight_subsequence_short_word() {
        // "helo" matches "hello" via subsequence (all chars in order)
        let words = highlighted_words("hello world", &["helo"]);
        assert_eq!(words, vec!["hello"]);
    }

    #[test]
    fn test_highlight_no_match_short_word() {
        // "hx" is too short for subsequence (< 3 chars) and no fuzzy for short words
        let words = highlighted_words("hello world", &["hx"]);
        assert!(words.is_empty());
    }

    #[test]
    fn test_highlight_multi_word() {
        let words = highlighted_words("hello beautiful world", &["hello", "world"]);
        assert_eq!(words, vec!["hello", "world"]);
    }

    #[test]
    fn test_highlight_short_exact_word() {
        let words = highlighted_words("hi there highway", &["hi"]);
        assert_eq!(words, vec!["hi"]);
    }

    #[test]
    fn test_highlight_multiple_occurrences() {
        let words = highlighted_words("hello world hello again", &["hello"]);
        assert_eq!(words, vec!["hello", "hello"]);
    }

    #[test]
    fn test_highlight_no_match() {
        let words = highlighted_words("hello world", &["xyz"]);
        assert!(words.is_empty());
    }

    // ── URL / special-character query tests ─────────────────────

    #[test]
    fn test_highlight_url_query_bridges_punctuation() {
        // "http" and "github" match adjacent words; the "://" gap should be bridged
        let words = highlighted_words("https://github.com/user/repo", &["http", "github"]);
        assert_eq!(words, vec!["https://github"]);
    }

    #[test]
    fn test_highlight_url_query_tokenized_from_raw() {
        // Simulate what search_trigram does: tokenize "http://github" into query words
        let query = "http://github";
        let query_words_owned = tokenize_words(query);
        let query_words: Vec<&str> = query_words_owned.iter().map(|(_, _, w)| w.as_str()).collect();
        // Punctuation tokens are now real tokens in the query
        assert_eq!(query_words, vec!["http", "://", "github"]);

        let fm = hc(1, "https://github.com/user/repo", 1000, 1.0, &query_words, false);
        let chars: Vec<char> = "https://github.com/user/repo".chars().collect();
        let words: Vec<String> = fm.highlight_ranges.iter().map(|r| {
            chars[r.start as usize..r.end as usize].iter().collect()
        }).collect();
        // "://" matched as a real token, producing contiguous highlight
        assert_eq!(words, vec!["https://github"]);
    }

    #[test]
    fn test_highlight_does_not_bridge_whitespace_gaps() {
        // Words separated by whitespace should NOT be bridged
        let words = highlighted_words("hello beautiful world", &["hello", "world"]);
        assert_eq!(words, vec!["hello", "world"]);
    }

    #[test]
    fn test_highlight_bridges_dots_in_domain() {
        // "github.com" → all three words bridged via dots
        let words = highlighted_words("https://github.com", &["github", "com"]);
        assert_eq!(words, vec!["github.com"]);
    }

    // ── Densest highlight cluster tests ──────────────────────────

    #[test]
    fn test_find_densest_highlight_empty() {
        assert_eq!(super::find_densest_highlight(&[], 500), None);
    }

    #[test]
    fn test_find_densest_highlight_single() {
        let highlights = vec![hr(50, 55)];
        assert_eq!(super::find_densest_highlight(&highlights, 500), Some(0));
    }

    #[test]
    fn test_find_densest_highlight_picks_denser_cluster() {
        let highlights = vec![
            hr(0, 5),
            hr(1000, 1005),
            hr(1050, 1055),
            hr(1100, 1105),
        ];
        let idx = super::find_densest_highlight(&highlights, 500).unwrap();
        assert_eq!(highlights[idx].start, 1000);
    }

    #[test]
    fn test_snippet_centers_on_densest_cluster() {
        let mut content = "a".repeat(10);
        content.push_str("LONE");
        content.push_str(&"b".repeat(986));
        content.push_str("DENSE1");
        content.push_str("xx");
        content.push_str("DENSE2");
        content.push_str("yy");
        content.push_str("DENSE3");
        content.push_str(&"c".repeat(100));

        let highlights = vec![
            hr(10, 14),
            hr(1000, 1006),
            hr(1008, 1014),
            hr(1016, 1022),
        ];

        let (snippet, _, _) = super::generate_snippet(&content, &highlights, 100);
        assert!(snippet.contains("DENSE1"), "Snippet should center on densest cluster, got: {}", snippet);
        assert!(snippet.contains("DENSE2"));
    }

    // ── Real-world density regression tests ───────────────────────

    const NIX_BUILD_ERROR: &str = "\
    'path:./hosts/default'
  \u{2192} 'path:/Users/julsh/git/dotfiles/nix/hosts/local?lastModified=1770783424&narHash=sha256-I8uZtr2R0rm1z9UzZNkj/ofk%2B2mSNp7ElUS67Bhj7js%3D' (2026-02-11)
error: Cannot build '/nix/store/dsq2qkgpgq6nysisychilwx9gwpcg1i1-inetutils-2.7.drv'.
       Reason: builder failed with exit code 2.
       Output paths:
         /nix/store/n9yl2hqsljax4gabc7c1qbxbkb0j6l55-inetutils-2.7
         /nix/store/pk6z47v44zjv29y37rxdy8b6nszh8x8f-inetutils-2.7-apparmor
       Last 25 log lines:
       > openat-die.c:31:18: note: expanded from macro '_'
       >    31 | #define _(msgid) dgettext (GNULIB_TEXT_DOMAIN, msgid)
       >       |                  ^
       > ./gettext.h:127:39: note: expanded from macro 'dgettext'
       >   127 | #  define dgettext(Domainname, Msgid) ((void) (Domainname), gettext (Msgid))
       >       |                                       ^
       > ./error.h:506:39: note: expanded from macro 'error'
       >   506 |       __gl_error_call (error, status, __VA_ARGS__)
       >       |                                       ^
       > ./error.h:446:51: note: expanded from macro '__gl_error_call'
       >   446 |          __gl_error_call1 (function, __errstatus, __VA_ARGS__); \\
       >       |                                                   ^
       > ./error.h:431:26: note: expanded from macro '__gl_error_call1'
       >   431 |     ((function) (status, __VA_ARGS__), \\
       >       |                          ^
       > 4 errors generated.
       > make[4]: *** [Makefile:6332: libgnu_a-openat-die.o] Error 1
       > make[4]: Leaving directory '/nix/var/nix/builds/nix-55927-395412078/inetutils-2.7/lib'
       > make[3]: *** [Makefile:8385: all-recursive] Error 1
       > make[3]: Leaving directory '/nix/var/nix/builds/nix-55927-395412078/inetutils-2.7/lib'
       > make[2]: *** [Makefile:3747: all] Error 2
       > make[2]: Leaving directory '/nix/var/nix/builds/nix-55927-395412078/inetutils-2.7/lib'
       > make[1]: *** [Makefile:2630: all-recursive] Error 1
       > make[1]: Leaving directory '/nix/var/nix/builds/nix-55927-395412078/inetutils-2.7'
       > make: *** [Makefile:2567: all] Error 2
       For full logs, run:
         nix-store -l /nix/store/dsq2qkgpgq6nysisychilwx9gwpcg1i1-inetutils-2.7.drv
error: Cannot build '/nix/store/djv08y006z7jk69j2q9fq5f1ch195i4s-home-manager.drv'.
       Reason: 1 dependency failed.
       Output paths:
         /nix/store/67pn4ck72akj3bz7d131wdcz6w4gb5qb-home-manager
error: Build failed due to failed dependency";

    fn build_query_words(query: &str) -> Vec<String> {
        query.to_lowercase().split_whitespace().map(|s| s.to_string()).collect()
    }

    #[test]
    fn test_densest_highlight_prefers_exact_query_match_over_scattered_repeats() {
        let query_words_owned = build_query_words("error: build failed due to dependency");
        let query_words: Vec<&str> = query_words_owned.iter().map(|s| s.as_str()).collect();
        let fm = hc(1, NIX_BUILD_ERROR, 1000, 1.0, &query_words, false);

        let densest_idx = find_densest_highlight(&fm.highlight_ranges, SNIPPET_CONTEXT_CHARS as u64).unwrap();
        let densest_start = fm.highlight_ranges[densest_idx].start as usize;

        let final_block = "error: Cannot build '/nix/store/djv08y006z7jk69j2q9fq5f1ch195i4s-home-manager.drv'.";
        let final_block_byte_pos = NIX_BUILD_ERROR.rfind(final_block).unwrap();
        let final_block_char_pos = NIX_BUILD_ERROR[..final_block_byte_pos].chars().count();

        assert!(
            densest_start >= final_block_char_pos,
            "Densest highlight at char {} should be in final error block (char {}+). \
             Points to: {:?}",
            densest_start,
            final_block_char_pos,
            NIX_BUILD_ERROR.chars().skip(densest_start).take(60).collect::<String>()
        );
    }

    #[test]
    fn test_snippet_centers_on_exact_query_match_not_scattered_repeats() {
        let query_words_owned = build_query_words("error: build failed due to dependency");
        let query_words: Vec<&str> = query_words_owned.iter().map(|s| s.as_str()).collect();
        let fm = hc(1, NIX_BUILD_ERROR, 1000, 1.0, &query_words, false);

        let (snippet, _, _) = generate_snippet(NIX_BUILD_ERROR, &fm.highlight_ranges, SNIPPET_CONTEXT_CHARS * 2);

        assert!(
            snippet.contains("Build failed due to failed dependency"),
            "Snippet should center on the near-exact match line, got: {}",
            snippet
        );
    }

    // ── HighlightKind verification tests ──────────────────────────

    #[test]
    fn test_highlight_match_kind_exact() {
        let fm = hc(1, "hello world", 1000, 1.0, &["hello"], false);
        assert_eq!(fm.highlight_ranges.len(), 1);
        assert_eq!(fm.highlight_ranges[0].kind, HighlightKind::Exact);
    }

    #[test]
    fn test_highlight_match_kind_prefix() {
        let fm = hc(1, "Run testing suite now", 1000, 1.0, &["test"], true);
        assert_eq!(fm.highlight_ranges.len(), 1);
        assert_eq!(fm.highlight_ranges[0].kind, HighlightKind::Prefix);
    }

    #[test]
    fn test_highlight_match_kind_fuzzy() {
        // "riversde" matches "riverside" via fuzzy edit distance
        let fm = hc(1, "Visit Riverside Park today", 1000, 1.0, &["riversde"], false);
        assert_eq!(fm.highlight_ranges.len(), 1);
        assert_eq!(fm.highlight_ranges[0].kind, HighlightKind::Fuzzy);
    }

    #[test]
    fn test_highlight_match_kind_subsequence() {
        // "impt" matches "import" via subsequence (len diff 2 exceeds max_dist 1)
        let fm = hc(1, "import data", 1000, 1.0, &["impt"], false);
        assert_eq!(fm.highlight_ranges.len(), 1);
        assert_eq!(fm.highlight_ranges[0].kind, HighlightKind::Subsequence);
    }
}
