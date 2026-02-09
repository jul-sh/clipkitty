//! Search Engine (Tantivy with phrase-boost scoring + word-level trigram highlighting)
//!
//! Tantivy handles retrieval and scoring via trigram indexing with per-word PhraseQuery
//! boosts for contiguity-aware ranking. Highlighting uses word-level trigram overlap
//! to identify which document words match each query word, producing clean whole-word
//! highlights that work for both exact and fuzzy/typo matches.
//! Short queries (< 3 chars) use a streaming fallback.

use crate::indexer::{Indexer, IndexerResult};
use crate::interface::{HighlightRange, MatchData, ItemMatch};
use crate::models::StoredItem;
use chrono::Utc;
use tokio_util::sync::CancellationToken;

/// Maximum results to return from search.
/// Returning more than this is not useful to the user.
pub const MAX_RESULTS: usize = 2000;

pub const MIN_TRIGRAM_QUERY_LEN: usize = 3;

/// Maximum recency boost multiplier (e.g., 0.1 = up to 10% boost for brand new items)
pub(crate) const RECENCY_BOOST_MAX: f64 = 0.1;
pub(crate) const RECENCY_HALF_LIFE_SECS: f64 = 7.0 * 24.0 * 60.0 * 60.0;

/// Minimum fraction of query word trigrams that must appear in a document word
/// for it to be highlighted. Uses query recall: intersection / |query_trigrams|.
/// 0.5 means at least half the query word's trigrams must be found in the doc word.
const HIGHLIGHT_MIN_OVERLAP: f64 = 0.5;

/// Boost factor for prefix matches in short query scoring
const PREFIX_MATCH_BOOST: f64 = 2.0;

/// Context chars to include before/after match in snippet
/// Swift handles final truncation and ellipsis positioning
pub const SNIPPET_CONTEXT_CHARS: usize = 200;

#[derive(Debug, Clone)]
pub struct FuzzyMatch {
    pub id: i64,
    pub score: u32,
    pub matched_indices: Vec<u32>,
    pub timestamp: i64,
    pub content: String,
    /// Whether this was a prefix match (for short query scoring)
    pub is_prefix_match: bool,
}

pub struct SearchEngine;

impl SearchEngine {
    pub fn new() -> Self {
        Self
    }

    /// Search using Tantivy with phrase-boost scoring for trigram queries (>= 3 chars).
    /// Results are already ranked by Tantivy (BM25 + recency blend via tweak_score).
    /// Returns (matches, total_count) where total_count is the true number of matching documents.
    pub fn search(&self, indexer: &Indexer, query: &str, token: &CancellationToken) -> IndexerResult<(Vec<FuzzyMatch>, usize)> {
        if query.trim().is_empty() {
            return Ok((Vec::new(), 0));
        }
        let trimmed = query.trim_start();
        // Split query words on the same non-alphanumeric boundaries as document
        // tokenization. This ensures "highlight_results" is matched as
        // ["highlight", "results"] — same as how the document is tokenized —
        // rather than as one 15-trigram word that no single doc word can reach
        // 50% overlap against.
        let query_words: Vec<String> = tokenize_words(&trimmed.trim_end().to_lowercase())
            .into_iter()
            .map(|(_, _, w)| w)
            .collect();
        // Pre-compute query word trigram sets once
        let query_info: Vec<(String, Vec<[char; 3]>)> = query_words.iter()
            .map(|w| {
                let lower = w.to_lowercase();
                let tris = word_trigrams(&lower);
                (lower, tris)
            })
            .collect();

        // Tantivy returns candidates already sorted by blended score (BM25 + recency)
        let (candidates, total_count) = indexer.search(trimmed.trim_end(), MAX_RESULTS)?;

        use rayon::prelude::*;
        let matches: Vec<FuzzyMatch> = candidates
            .into_par_iter()
            .take_any_while(|_| !token.is_cancelled())
            .map(|c| Self::highlight_candidate_pub(c.id, &c.content, c.timestamp, c.tantivy_score, &query_info))
            .filter(|m| !m.matched_indices.is_empty())
            .collect();

        Ok((matches, total_count))
    }

    /// Score candidates for short queries (< 3 chars)
    /// Uses recency as primary metric with prefix match boost
    pub fn score_short_query_batch(
        &self,
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
        let mut results: Vec<FuzzyMatch> = candidates
            .par_bridge()
            .take_any_while(|_| !token.is_cancelled())
            .filter_map(|(id, content, timestamp, is_prefix_match)| {
                // Find match position for highlighting
                let content_lower = content.to_lowercase();
                content_lower.find(&query_lower).map(|pos| {
                    let matched_indices: Vec<u32> = (pos..pos + query.len())
                        .map(|i| i as u32)
                        .collect();

                    // Score based on recency with prefix boost
                    let base_score = 1000u32; // Base score for any match
                    let score = if is_prefix_match {
                        (base_score as f64 * PREFIX_MATCH_BOOST) as u32
                    } else {
                        base_score
                    };

                    FuzzyMatch {
                        id,
                        score,
                        matched_indices,
                        timestamp,
                        content,
                        is_prefix_match,
                    }
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

    /// Highlight a Tantivy-confirmed candidate using word-level trigram overlap.
    /// For each document word, checks if any query word has sufficient trigram
    /// overlap (>= HIGHLIGHT_MIN_OVERLAP). Matched words are highlighted in full,
    /// producing clean whole-word highlights that work for typo matches too.
    pub fn highlight_candidate_pub(
        id: i64,
        content: &str,
        timestamp: i64,
        tantivy_score: f32,
        query_info: &[(String, Vec<[char; 3]>)],
    ) -> FuzzyMatch {
        let content_lower = content.to_lowercase();
        let mut all_indices = Vec::new();

        // Tokenize document into words with char offsets
        let doc_words = tokenize_words(&content_lower);

        for (char_start, char_end, doc_word) in &doc_words {
            let doc_tris = word_trigrams(doc_word);

            for (query_lower, query_tris) in query_info {
                let matched = if query_tris.is_empty() || doc_tris.is_empty() {
                    // Short word (< 3 chars) on either side: exact word match
                    doc_word == query_lower
                } else {
                    trigram_overlap_ratio(query_tris, &doc_tris) >= HIGHLIGHT_MIN_OVERLAP
                };

                if matched {
                    for i in *char_start..*char_end {
                        all_indices.push(i as u32);
                    }
                    break; // Don't double-highlight from multiple query words
                }
            }
        }

        all_indices.sort_unstable();
        all_indices.dedup();

        // Score is already blended (BM25 + recency) by Tantivy's tweak_score
        let score = tantivy_score as u32;

        FuzzyMatch {
            id,
            score,
            matched_indices: all_indices,
            timestamp,
            content: content.to_string(),
            is_prefix_match: false,
        }
    }

    /// Convert matched indices to highlight ranges
    pub fn indices_to_ranges(indices: &[u32]) -> Vec<HighlightRange> {
        if indices.is_empty() { return Vec::new(); }

        let mut sorted = indices.to_vec();
        sorted.sort_unstable();
        sorted.dedup();

        sorted[1..].iter().fold(vec![(sorted[0], sorted[0] + 1)], |mut acc, &idx| {
            let last = acc.last_mut().unwrap();
            if idx == last.1 { last.1 = idx + 1; } else { acc.push((idx, idx + 1)); }
            acc
        }).into_iter().map(|(start, end)| HighlightRange { start: start as u64, end: end as u64 }).collect()
    }

    /// Generate a generous text snippet around the first match with context
    /// Returns normalized snippet (whitespace collapsed) with adjusted highlights
    /// Swift handles final truncation and ellipsis positioning
    pub fn generate_snippet(content: &str, highlights: &[HighlightRange], max_len: usize) -> (String, Vec<HighlightRange>, u64) {
        let content_char_len = content.chars().count();

        if highlights.is_empty() {
            // No highlights, return first max_len chars (normalized)
            let preview = normalize_snippet(content, 0, content_char_len, max_len);
            return (preview, Vec::new(), 0);
        }

        let first_highlight = &highlights[0];
        // These are CHARACTER indices, not byte offsets
        let match_start_char = first_highlight.start as usize;
        let match_end_char = first_highlight.end as usize;

        // Find line number (count newlines before match) - 1-indexed
        // Use chars().take() to safely handle multi-byte UTF-8
        let line_number = content
            .chars()
            .take(match_start_char.min(content_char_len))
            .filter(|&c| c == '\n')
            .count() as u64
            + 1;


        // Start with the match, then expand with context
        let match_char_len = match_end_char.saturating_sub(match_start_char);
        let remaining_space = max_len.saturating_sub(match_char_len);

        // Split remaining space for context before/after (all in CHARACTER units)
        let context_before = (remaining_space / 2).min(SNIPPET_CONTEXT_CHARS).min(match_start_char);
        let context_after = (remaining_space - context_before).min(content_char_len.saturating_sub(match_end_char));

        let mut snippet_start_char = match_start_char - context_before;
        let snippet_end_char = (match_end_char + context_after).min(content_char_len);

        // Try to adjust start to word boundary (work in character space)
        if snippet_start_char > 0 {
            let search_start_char = snippet_start_char.saturating_sub(10);
            // Get the substring in character space to search for whitespace
            let search_range: String = content
                .chars()
                .skip(search_start_char)
                .take(snippet_start_char - search_start_char)
                .collect();
            if let Some(space_pos) = search_range.rfind(char::is_whitespace) {
                // space_pos is a byte offset - verify it's a valid boundary before slicing
                if search_range.is_char_boundary(space_pos) {
                    let char_offset = search_range[..space_pos].chars().count();
                    let new_start = search_start_char + char_offset + 1;
                    if new_start <= match_start_char.saturating_sub(context_before) {
                        snippet_start_char = new_start;
                    }
                }
            }
        }

        // Normalize snippet and track position mappings for highlight adjustment
        // Reserve space for potential ellipsis characters (1 for leading, 1 for trailing)
        let ellipsis_reserve = (if snippet_start_char > 0 { 1 } else { 0 })
            + (if snippet_end_char < content_char_len { 1 } else { 0 });
        let effective_max_len = max_len.saturating_sub(ellipsis_reserve);
        let (normalized_snippet, pos_map) = normalize_snippet_with_mapping(content, snippet_start_char, snippet_end_char, effective_max_len);

        // Check truncation from start and end
        let truncated_from_start = snippet_start_char > 0;
        let truncated_from_end = snippet_end_char < content_char_len;

        // Build final snippet with ellipsis as needed
        let prefix_offset = if truncated_from_start { 1 } else { 0 };
        let mut final_snippet = if truncated_from_start {
            format!("…{}", normalized_snippet)
        } else {
            normalized_snippet.clone()
        };
        if truncated_from_end {
            final_snippet.push('…');
        }

        // Adjust highlight ranges using position mapping, accounting for ellipsis prefix
        // (trailing ellipsis doesn't affect highlight positions)
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
                    })
                } else {
                    None
                }
            })
            .collect();

        (final_snippet, adjusted_highlights, line_number)
    }

    /// Create MatchData from a FuzzyMatch
    pub fn create_match_data(fuzzy_match: &FuzzyMatch) -> MatchData {
        let full_content_highlights = Self::indices_to_ranges(&fuzzy_match.matched_indices);
        // Max length = context before + match + context after (generous for Swift to truncate)
        let max_len = SNIPPET_CONTEXT_CHARS * 2;
        let (text, adjusted_highlights, line_number) = Self::generate_snippet(
            &fuzzy_match.content,
            &full_content_highlights,
            max_len,
        );

        MatchData {
            text,
            highlights: adjusted_highlights,
            line_number,
            full_content_highlights,
        }
    }

    /// Create ItemMatch from StoredItem and FuzzyMatch
    pub fn create_item_match(item: &StoredItem, fuzzy_match: &FuzzyMatch) -> ItemMatch {
        ItemMatch {
            item_metadata: item.to_metadata(),
            match_data: Self::create_match_data(fuzzy_match),
        }
    }
}

impl Default for SearchEngine {
    fn default() -> Self { Self }
}

/// Generate trigrams from a word. Returns empty vec for words < 3 chars.
pub(crate) fn word_trigrams(word: &str) -> Vec<[char; 3]> {
    let chars: Vec<char> = word.chars().collect();
    if chars.len() < 3 {
        return Vec::new();
    }
    chars.windows(3).map(|w| [w[0], w[1], w[2]]).collect()
}

/// Compute query recall: fraction of query trigrams found in the document word.
/// Returns intersection / |query_trigrams|, so 1.0 means all query trigrams are present.
fn trigram_overlap_ratio(query_tris: &[[char; 3]], doc_tris: &[[char; 3]]) -> f64 {
    if query_tris.is_empty() {
        return 0.0;
    }
    let intersection = query_tris.iter().filter(|t| doc_tris.contains(t)).count();
    intersection as f64 / query_tris.len() as f64
}

/// Tokenize text into words with char offsets. Splits on non-alphanumeric characters.
/// Returns (char_start, char_end, word_str) for each word.
fn tokenize_words(content: &str) -> Vec<(usize, usize, String)> {
    let chars: Vec<char> = content.chars().collect();
    let mut words = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if !chars[i].is_alphanumeric() {
            i += 1;
            continue;
        }
        let start = i;
        while i < chars.len() && chars[i].is_alphanumeric() {
            i += 1;
        }
        let word: String = chars[start..i].iter().collect();
        words.push((start, i, word));
    }
    words
}

/// Combine a base relevance score with exponential recency decay and prefix boost.
/// Used by the short query path (< 3 chars) where Tantivy isn't involved.
fn recency_weighted_score(fuzzy_score: u32, timestamp: i64, now: i64, is_prefix_match: bool) -> f64 {
    let base_score = fuzzy_score as f64;

    // Exponential decay for recency (half-life based)
    let age_secs = (now - timestamp).max(0) as f64;
    let recency_factor = (-age_secs * 2.0_f64.ln() / RECENCY_HALF_LIFE_SECS).exp();

    // Apply prefix match boost if applicable
    let prefix_boost = if is_prefix_match { PREFIX_MATCH_BOOST } else { 1.0 };

    // Multiplicative boost: score * prefix_boost * (1 + recency_boost * recency)
    base_score * prefix_boost * (1.0 + RECENCY_BOOST_MAX * recency_factor)
}

/// Normalize a snippet and return position mapping (original_idx -> normalized_idx)
/// Converts newlines/tabs to spaces, collapses consecutive spaces
fn normalize_snippet_with_mapping(content: &str, start: usize, end: usize, max_chars: usize) -> (String, Vec<usize>) {
    // Defensive check: if end < start, return empty result
    if end <= start {
        return (String::new(), vec![0]);
    }

    let mut result = String::with_capacity(max_chars);
    let mut pos_map = Vec::with_capacity(end - start + 1);
    let mut last_was_space = false;
    let mut norm_idx = 0;

    for ch in content.chars().skip(start).take(end - start) {
        // Record mapping for this original position
        pos_map.push(norm_idx);

        if norm_idx >= max_chars {
            continue; // Still track positions but don't add to result
        }

        let ch = match ch {
            '\n' | '\t' | '\r' => ' ',
            c => c,
        };

        if ch == ' ' {
            if last_was_space {
                continue; // Skip but don't increment norm_idx
            }
            last_was_space = true;
        } else {
            last_was_space = false;
        }

        result.push(ch);
        norm_idx += 1;
    }

    // Add final position (for end-of-range lookups)
    pos_map.push(norm_idx);

    // Trim trailing space
    if result.ends_with(' ') {
        result.pop();
    }

    (result, pos_map)
}

/// Map an original position through the normalization mapping
fn map_position(orig_pos: usize, pos_map: &[usize]) -> Option<usize> {
    pos_map.get(orig_pos).copied()
}

/// Normalize a snippet for no-highlight case
fn normalize_snippet(content: &str, start: usize, end: usize, max_chars: usize) -> String {
    normalize_snippet_with_mapping(content, start, end, max_chars).0
}

/// Generate a preview from content (no highlights, starts from beginning)
/// Skips leading whitespace, normalizes, truncates at max_chars
pub fn generate_preview(content: &str, max_chars: usize) -> String {
    // Skip leading whitespace
    let trimmed = content.trim_start();
    let (preview, _, _) = SearchEngine::generate_snippet(trimmed, &[], max_chars);
    preview
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_indices_to_ranges() {
        let indices = vec![0, 1, 2, 5, 6, 10];
        let ranges = SearchEngine::indices_to_ranges(&indices);
        assert_eq!(ranges.len(), 3);
        assert_eq!(ranges[0], HighlightRange { start: 0, end: 3 });
        assert_eq!(ranges[1], HighlightRange { start: 5, end: 7 });
        assert_eq!(ranges[2], HighlightRange { start: 10, end: 11 });
    }

    #[test]
    fn test_generate_snippet_basic() {
        let content = "This is a long text with some interesting content that we want to highlight";
        let highlights = vec![HighlightRange { start: 28, end: 39 }]; // "interesting"
        let (snippet, adj_highlights, _line) = SearchEngine::generate_snippet(content, &highlights, 50);

        assert!(snippet.contains("interesting"));
        assert!(!adj_highlights.is_empty());
    }

    #[test]
    fn test_snippet_contains_match_mid_content() {
        // Match is in the middle of content
        let content = "The quick brown fox jumps over the lazy dog and runs away fast";
        let highlights = vec![HighlightRange { start: 35, end: 39 }]; // "lazy"
        let (snippet, adj_highlights, _) = SearchEngine::generate_snippet(content, &highlights, 30);

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
        let highlights = vec![HighlightRange { start: 0, end: 5 }]; // "Hello"
        let (snippet, adj_highlights, _) = SearchEngine::generate_snippet(content, &highlights, 50);

        assert_eq!(adj_highlights[0].start, 0, "Highlight should start at 0");
        assert_eq!(snippet, "Hello world");
    }

    #[test]
    fn test_snippet_normalizes_whitespace() {
        // Snippets normalize whitespace (newlines/tabs to spaces, collapse consecutive)
        let content = "Line one\n\nLine two";
        let highlights = vec![HighlightRange { start: 0, end: 4 }]; // "Line"
        let (snippet, adj_highlights, _) = SearchEngine::generate_snippet(content, &highlights, 50);

        assert!(!snippet.contains('\n'), "Snippet should not contain newlines");
        assert!(!snippet.contains("  "), "Snippet should not contain consecutive spaces");
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
        let highlights = vec![HighlightRange { start: 46, end: 52 }]; // "TARGET"
        let (snippet, adj_highlights, _) = SearchEngine::generate_snippet(content, &highlights, 30);

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
        let highlights = vec![HighlightRange { start: 100, end: 105 }]; // "MATCH"
        let (snippet, adj_highlights, _) = SearchEngine::generate_snippet(&content, &highlights, 30);

        assert!(snippet.contains("MATCH"));

        // Verify highlight is correct
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

        // Same fuzzy score, different timestamps - recent should win
        let recent = recency_weighted_score(1000, now, now, false);
        let old = recency_weighted_score(1000, now - 86400 * 30, now, false); // 30 days old
        assert!(recent > old, "Recent items should score higher with same quality");

        // Prefix match should boost score
        let prefix = recency_weighted_score(1000, now, now, true);
        let non_prefix = recency_weighted_score(1000, now, now, false);
        assert!(prefix > non_prefix, "Prefix matches should score higher");
    }

    #[test]
    fn test_snippet_utf8_multibyte_chars() {
        // This test ensures we handle multi-byte UTF-8 characters correctly
        // The bug was treating character indices as byte offsets
        let content = "Hello 你好 world 🌍 test"; // Contains Chinese and emoji
        // "Hello " = 6 chars, "你" = char index 6, "好" = char index 7
        // Match "你好" at character indices 6-8
        let highlights = vec![HighlightRange { start: 6, end: 8 }];

        // This should NOT panic (previously would panic with slice_error_fail)
        let (snippet, adj_highlights, _) = SearchEngine::generate_snippet(content, &highlights, 50);

        assert!(snippet.contains("你好"), "Snippet should contain the match");
        assert!(!adj_highlights.is_empty(), "Should have adjusted highlights");

        let h = &adj_highlights[0];
        let highlighted: String = snippet.chars()
            .skip(h.start as usize)
            .take((h.end - h.start) as usize)
            .collect();
        assert_eq!(highlighted, "你好", "Highlighted text should match");
    }

    // ── Word-level trigram highlighting tests ─────────────────────────

    #[test]
    fn test_word_trigrams() {
        assert_eq!(word_trigrams("hi"), Vec::<[char; 3]>::new()); // too short
        assert_eq!(word_trigrams("hello"), vec![['h','e','l'], ['e','l','l'], ['l','l','o']]);
        assert_eq!(word_trigrams("abc"), vec![['a','b','c']]); // exactly 3 chars = 1 trigram
    }

    #[test]
    fn test_trigram_overlap_ratio() {
        let hello = word_trigrams("hello"); // hel, ell, llo
        let shell = word_trigrams("shell"); // she, hel, ell
        // "hello" query vs "shell" doc: intersection={hel,ell}=2, query has 3 → 2/3=0.67
        assert!((trigram_overlap_ratio(&hello, &shell) - 0.667).abs() < 0.01);

        // Exact match: 1.0
        assert_eq!(trigram_overlap_ratio(&hello, &hello), 1.0);

        // No overlap: 0.0
        let xyz = word_trigrams("xyz");
        assert_eq!(trigram_overlap_ratio(&hello, &xyz), 0.0);

        // Typo: "riversde" vs "riverside"
        let riversde = word_trigrams("riversde"); // riv,ive,ver,ers,rsd,sde
        let riverside = word_trigrams("riverside"); // riv,ive,ver,ers,rsi,sid,ide
        let ratio = trigram_overlap_ratio(&riversde, &riverside);
        // intersection={riv,ive,ver,ers}=4, query has 6 → 4/6=0.67
        assert!((ratio - 0.667).abs() < 0.01);
        assert!(ratio >= HIGHLIGHT_MIN_OVERLAP);

        // "theme" query vs "the" doc word — should NOT pass threshold
        let theme = word_trigrams("theme"); // the, hem, eme
        let the = word_trigrams("the"); // the
        // intersection={the}=1, query("theme") has 3 → 1/3=0.33
        assert!(trigram_overlap_ratio(&theme, &the) < HIGHLIGHT_MIN_OVERLAP);

        // "the" query vs "theme" doc word — SHOULD pass (contains "the")
        // intersection={the}=1, query("the") has 1 → 1/1=1.0
        assert!(trigram_overlap_ratio(&the, &theme) >= HIGHLIGHT_MIN_OVERLAP);

        // "test" query vs "testing" doc — prefix match
        let test_q = word_trigrams("test"); // tes, est
        let testing = word_trigrams("testing"); // tes, est, sti, tin, ing
        // intersection={tes,est}=2, query has 2 → 2/2=1.0
        assert_eq!(trigram_overlap_ratio(&test_q, &testing), 1.0);
    }

    #[test]
    fn test_tokenize_words() {
        let words = tokenize_words("hello world");
        assert_eq!(words, vec![(0, 5, "hello".into()), (6, 11, "world".into())]);

        // tokenize_words operates on already-lowercased content
        let words = tokenize_words("urlparser.parse(input)");
        assert_eq!(words, vec![
            (0, 9, "urlparser".into()),
            (10, 15, "parse".into()),
            (16, 21, "input".into()),
        ]);

        // Punctuation and multiple separators
        let words = tokenize_words("one--two...three");
        assert_eq!(words, vec![
            (0, 3, "one".into()),
            (5, 8, "two".into()),
            (11, 16, "three".into()),
        ]);
    }

    /// Helper: run highlight_candidate and return the highlighted substrings
    fn highlighted_words(content: &str, query_words: &[&str]) -> Vec<String> {
        let query_info: Vec<(String, Vec<[char; 3]>)> = query_words.iter()
            .map(|w| {
                let lower = w.to_lowercase();
                let tris = word_trigrams(&lower);
                (lower, tris)
            })
            .collect();
        let fm = SearchEngine::highlight_candidate_pub(
            1, content, 1000, 1.0, &query_info,
        );
        let ranges = SearchEngine::indices_to_ranges(&fm.matched_indices);
        let chars: Vec<char> = content.chars().collect();
        ranges.iter().map(|r| {
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
        // "riversde" (typo) should highlight "Riverside" via trigram overlap
        let words = highlighted_words("Visit Riverside Park today", &["riversde"]);
        assert_eq!(words, vec!["Riverside"]); // indices point into original content
    }

    #[test]
    fn test_highlight_prefix_match() {
        // "test" should highlight "testing" (all query trigrams present)
        let words = highlighted_words("Run testing suite now", &["test"]);
        assert_eq!(words, vec!["testing"]);
    }

    #[test]
    fn test_highlight_no_theme_the_noise() {
        // "theme" query should NOT highlight standalone "the"
        let words = highlighted_words("the main theme is clear", &["theme"]);
        assert_eq!(words, vec!["theme"]);
        assert!(!words.contains(&"the".to_string()));
    }

    #[test]
    fn test_highlight_multi_word() {
        let words = highlighted_words("hello beautiful world", &["hello", "world"]);
        assert_eq!(words, vec!["hello", "world"]);
    }

    #[test]
    fn test_highlight_short_query_word() {
        // "hi" is < 3 chars — uses exact word match
        let words = highlighted_words("hi there highway", &["hi"]);
        assert_eq!(words, vec!["hi"]); // "highway" should NOT match
    }

    #[test]
    fn test_highlight_multiple_occurrences() {
        // Both "hello" instances should be highlighted
        let words = highlighted_words("hello world hello again", &["hello"]);
        assert_eq!(words, vec!["hello", "hello"]);
    }

    #[test]
    fn test_highlight_no_match() {
        // Completely unrelated query
        let words = highlighted_words("hello world", &["xyz"]);
        assert!(words.is_empty());
    }

    #[test]
    fn test_highlight_url_in_camelcase() {
        // "url" query (1 trigram) vs "urlParser" doc word — all query trigrams present
        let words = highlighted_words("the urlParser module", &["url"]);
        assert_eq!(words, vec!["urlParser"]); // indices point into original content
    }
}
