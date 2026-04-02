//! Search Engine (Tantivy with bucket ranking + word-level highlighting)
//!
//! Tantivy handles retrieval via trigram indexing with per-word PhraseQuery boosts.
//! Phase 2 bucket re-ranking (in indexer.rs) provides Milli-style lexicographic
//! ranking. Highlighting uses `does_word_match` from the ranking module to ensure
//! what's highlighted matches what's ranked (exact, prefix, substring, fuzzy edit-distance).
//! Short queries (< 3 chars) use a streaming fallback.

use crate::indexer::Indexer;
use crate::interface::ClipKittyError;
use crate::interface::{
    HighlightKind, ItemMatch, ItemMetadata, ListDecoration, ListPresentationProfile,
    PreviewDecoration, Utf16HighlightRange,
};
use crate::ranking::{
    does_word_match, does_word_match_fast, does_word_match_fast_raw, prefix_match_for_query_word,
    WordMatchKind, LARGE_DOC_THRESHOLD_BYTES,
};
use tokio_util::sync::CancellationToken;

/// Maximum results to return from search.
pub(crate) const MAX_RESULTS: usize = 2000;

pub(crate) const MIN_TRIGRAM_QUERY_LEN: usize = 3;

/// Context chars to include before/after match in snippet
pub(crate) const SNIPPET_CONTEXT_CHARS: usize = 200;

// ─────────────────────────────────────────────────────────────────────────────
// Excerpt policy — profile-driven formatting
// ─────────────────────────────────────────────────────────────────────────────

/// How whitespace is treated during snippet normalization.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum WhitespaceMode {
    /// Collapse all whitespace (newlines, tabs, runs of spaces) into a single space.
    CollapseAll,
    /// Preserve single line breaks; collapse runs of 3+ newlines into 2; collapse
    /// tabs and horizontal whitespace runs into a single space.
    PreserveLineBreaks,
}

/// Controls how excerpts are formatted for a given presentation profile.
#[derive(Debug, Clone, Copy)]
pub(crate) struct ExcerptPolicy {
    pub(crate) whitespace_mode: WhitespaceMode,
    pub(crate) max_chars: usize,
    pub(crate) context_chars: usize,
}

impl ExcerptPolicy {
    pub(crate) fn for_profile(profile: ListPresentationProfile) -> Self {
        match profile {
            ListPresentationProfile::CompactRow => Self {
                whitespace_mode: WhitespaceMode::CollapseAll,
                max_chars: SNIPPET_CONTEXT_CHARS * 2, // 400
                context_chars: SNIPPET_CONTEXT_CHARS,  // 200
            },
            ListPresentationProfile::Card => Self {
                whitespace_mode: WhitespaceMode::PreserveLineBreaks,
                max_chars: SNIPPET_CONTEXT_CHARS * 4, // 800
                context_chars: SNIPPET_CONTEXT_CHARS * 2, // 400
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SearchQuery {
    Plain {
        text: String,
    },
    PreferPrefix {
        raw_text: String,
        stripped_text: String,
    },
}

impl SearchQuery {
    pub(crate) fn parse(query: &str) -> Self {
        let trimmed = query.trim();
        if let Some(rest) = trimmed.strip_prefix('^') {
            let stripped = rest.trim_start();
            if !stripped.is_empty() {
                return Self::PreferPrefix {
                    raw_text: trimmed.to_string(),
                    stripped_text: stripped.to_string(),
                };
            }
        }

        Self::Plain {
            text: trimmed.to_string(),
        }
    }

    pub(crate) fn raw_text(&self) -> &str {
        match self {
            Self::Plain { text } => text,
            Self::PreferPrefix { raw_text, .. } => raw_text,
        }
    }

    pub(crate) fn recall_text(&self) -> &str {
        match self {
            Self::Plain { text } => text,
            Self::PreferPrefix { stripped_text, .. } => stripped_text,
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) struct FuzzyMatch {
    pub(crate) highlight_ranges: Vec<HighlightRange>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct HighlightRange {
    pub(crate) start: u64,
    pub(crate) end: u64,
    pub(crate) kind: HighlightKind,
}

#[derive(Debug, Clone)]
pub(crate) struct HighlightAnalysis {
    pub(crate) highlights: Vec<HighlightRange>,
    pub(crate) initial_scroll_highlight_index: Option<u64>,
}

#[derive(Debug, Clone, Copy)]
enum PreviewHighlightLimit {
    FocusedWindow {
        max_highlights: usize,
        context_chars: u64,
    },
}

const PREVIEW_MAX_HIGHLIGHTS: usize = 64;
const PREVIEW_HIGHLIGHT_CONTEXT_CHARS: u64 = 2048;

fn utf16_offset_table(text: &str) -> Vec<u64> {
    let mut offsets = Vec::with_capacity(text.chars().count() + 1);
    let mut utf16_pos = 0u64;
    for ch in text.chars() {
        offsets.push(utf16_pos);
        utf16_pos += ch.len_utf16() as u64;
    }
    offsets.push(utf16_pos);
    offsets
}

fn scalar_highlights_to_utf16(
    text: &str,
    highlights: &[HighlightRange],
) -> Vec<Utf16HighlightRange> {
    let offsets = utf16_offset_table(text);
    highlights
        .iter()
        .filter_map(|highlight| {
            let start = usize::try_from(highlight.start).ok()?;
            let end = usize::try_from(highlight.end).ok()?;
            let utf16_start = *offsets.get(start)?;
            let utf16_end = *offsets.get(end)?;
            Some(Utf16HighlightRange {
                utf16_start,
                utf16_end,
                kind: highlight.kind,
            })
        })
        .collect()
}

fn limit_preview_highlights(
    analysis: &HighlightAnalysis,
    limit: PreviewHighlightLimit,
) -> (Vec<HighlightRange>, Option<u64>) {
    match limit {
        PreviewHighlightLimit::FocusedWindow {
            max_highlights,
            context_chars,
        } => {
            if analysis.highlights.is_empty() || max_highlights == 0 {
                return (Vec::new(), None);
            }

            if analysis.highlights.len() <= max_highlights {
                return (
                    analysis.highlights.clone(),
                    analysis.initial_scroll_highlight_index,
                );
            }

            let anchor_index = analysis
                .initial_scroll_highlight_index
                .and_then(|index| usize::try_from(index).ok())
                .filter(|index| *index < analysis.highlights.len())
                .unwrap_or(0);
            let anchor = &analysis.highlights[anchor_index];
            let window_start = anchor.start.saturating_sub(context_chars);
            let window_end = anchor.end.saturating_add(context_chars);

            let visible_indices: Vec<usize> = analysis
                .highlights
                .iter()
                .enumerate()
                .filter_map(|(index, highlight)| {
                    (highlight.end >= window_start && highlight.start <= window_end)
                        .then_some(index)
                })
                .collect();

            let (mut slice_start, mut slice_end) = if let (Some(first), Some(last)) =
                (visible_indices.first(), visible_indices.last())
            {
                (*first, last + 1)
            } else {
                (anchor_index, anchor_index + 1)
            };

            if slice_end - slice_start > max_highlights {
                let preferred_start = anchor_index.saturating_sub(max_highlights / 2);
                let max_start = slice_end.saturating_sub(max_highlights);
                slice_start = preferred_start.clamp(slice_start, max_start);
                slice_end = slice_start + max_highlights;
            }

            let limited = analysis.highlights[slice_start..slice_end].to_vec();
            let limited_anchor = anchor_index
                .checked_sub(slice_start)
                .map(|index| index as u64)
                .filter(|index| (*index as usize) < limited.len());

            (limited, limited_anchor)
        }
    }
}

/// Search using Tantivy with bucket re-ranking for trigram queries (>= 3 chars).
/// Phase 1 (trigram recall) and Phase 2 (bucket re-ranking) happen inside indexer.search().
/// Returns item-level search candidates with their best match context.
pub(crate) fn search_trigram_lazy(
    indexer: &Indexer,
    query: &SearchQuery,
    token: &CancellationToken,
) -> Result<Vec<crate::candidate::SearchCandidate>, ClipKittyError> {
    if query.raw_text().is_empty() {
        return Ok(Vec::new());
    }

    // Bucket-ranked candidates from two-phase search
    #[cfg(feature = "perf-log")]
    let t0 = std::time::Instant::now();
    let candidates = match indexer.search_parsed(query, MAX_RESULTS, token) {
        Ok(candidates) => candidates,
        Err(_) if token.is_cancelled() => return Err(ClipKittyError::Cancelled),
        Err(error) => return Err(error.into()),
    };
    #[cfg(feature = "perf-log")]
    eprintln!(
        "[perf] indexer_total={:.1}ms candidates={}",
        (std::time::Instant::now() - t0).as_secs_f64() * 1000.0,
        candidates.len()
    );

    if token.is_cancelled() {
        return Err(ClipKittyError::Cancelled);
    }

    Ok(candidates)
}

/// Map a `WordMatchKind` from ranking to a `HighlightKind` for the UI.
fn word_match_to_highlight_kind(wmk: WordMatchKind) -> HighlightKind {
    match wmk {
        WordMatchKind::Exact => HighlightKind::Exact,
        WordMatchKind::Prefix => HighlightKind::Prefix,
        WordMatchKind::SubwordPrefix => HighlightKind::SubwordPrefix,
        WordMatchKind::InfixSubstring => HighlightKind::Substring,
        WordMatchKind::Fuzzy(_) => HighlightKind::Fuzzy,
        WordMatchKind::Subsequence(_) => HighlightKind::Subsequence,
        WordMatchKind::None => HighlightKind::Exact, // unreachable in practice
    }
}

fn highlight_end_for_match(
    char_start: usize,
    char_end: usize,
    query_word: &str,
    word_match_kind: WordMatchKind,
) -> usize {
    match word_match_kind {
        WordMatchKind::Prefix => {
            let prefix_len = query_word.chars().count();
            (char_start + prefix_len).min(char_end)
        }
        _ => char_end,
    }
}

fn append_word_highlight(
    highlights: &mut Vec<(usize, usize, HighlightKind)>,
    char_start: usize,
    char_end: usize,
    query_word: &str,
    word_match_kind: WordMatchKind,
) {
    let highlight_end = highlight_end_for_match(char_start, char_end, query_word, word_match_kind);
    highlights.push((
        char_start,
        highlight_end,
        word_match_to_highlight_kind(word_match_kind),
    ));

    if matches!(word_match_kind, WordMatchKind::Prefix) && highlight_end < char_end {
        highlights.push((highlight_end, char_end, HighlightKind::PrefixTail));
    }
}

fn should_bridge_highlights(
    previous_kind: HighlightKind,
    next_kind: HighlightKind,
    gap_chars: &[char],
) -> bool {
    if matches!(previous_kind, HighlightKind::PrefixTail)
        || matches!(next_kind, HighlightKind::PrefixTail)
    {
        return false;
    }

    gap_chars.is_empty()
        || gap_chars
            .iter()
            .all(|c| !c.is_alphanumeric() && !c.is_whitespace())
}

/// Context for highlighting a candidate document.
pub(crate) struct HighlightContext<'a> {
    pub content: &'a str,
    pub doc_words: &'a [(usize, usize, String)],
    pub query_words: &'a [&'a str],
    pub last_word_is_prefix: bool,
}

/// Highlight a candidate using the same word-matching criteria as ranking
/// (exact, prefix, substring, fuzzy edit-distance) via `does_word_match`. This ensures
/// what's highlighted matches what was ranked in Phase 2 bucket scoring.
///
/// `content_lower` and `doc_words` are pre-computed in Phase 2 to avoid
/// redundant lowercasing and tokenization (~4000 allocations per search).
///
/// For large documents (>32KB), uses fast matching (exact + prefix only)
/// to avoid expensive fuzzy/subsequence matching.
pub(crate) fn highlight_candidate(ctx: &HighlightContext<'_>) -> FuzzyMatch {
    let mut word_highlights: Vec<(usize, usize, HighlightKind)> = Vec::new();
    let mut matched_query_words = vec![false; ctx.query_words.len()];

    let query_lower: Vec<String> = ctx.query_words.iter().map(|w| w.to_lowercase()).collect();
    // Use fast matching for large documents
    let is_large_doc = ctx.content.len() > LARGE_DOC_THRESHOLD_BYTES;

    for (char_start, char_end, doc_word) in ctx.doc_words {
        let doc_word_lower = doc_word.to_lowercase();
        for (qi, qw) in query_lower.iter().enumerate() {
            let prefix_match =
                prefix_match_for_query_word(query_lower.len(), qi, ctx.last_word_is_prefix);
            let wmk = if is_large_doc {
                does_word_match_fast(qw, &doc_word_lower, prefix_match)
            } else {
                does_word_match(qw, &doc_word_lower, doc_word, prefix_match)
            };
            if wmk != WordMatchKind::None {
                matched_query_words[qi] = true;
                // Only highlight word tokens directly. Punctuation tokens (match_weight=0)
                // are included via the bridging pass when they fall between word highlights,
                // preventing random punctuation elsewhere from being highlighted.
                if is_word_token(qw) {
                    append_word_highlight(&mut word_highlights, *char_start, *char_end, qw, wmk);
                }
                break; // Don't double-highlight from multiple query words
            }
        }
    }

    // Sort by start position
    word_highlights.sort_unstable_by_key(|&(s, _, _)| s);

    // Bridge gaps between adjacent highlighted ranges where intervening chars are all
    // non-whitespace punctuation or ranges are directly adjacent (e.g. "://" in URLs,
    // "." in domains, "/" in paths). Inherit the first range's kind.
    let content_chars: Vec<char> = ctx.content.chars().collect();
    let mut bridged: Vec<(usize, usize, HighlightKind)> = Vec::with_capacity(word_highlights.len());
    for wh in &word_highlights {
        if let Some(last) = bridged.last_mut() {
            let gap_start = last.1;
            let gap_end = wh.0;
            if gap_start <= gap_end
                && gap_end <= content_chars.len()
                && should_bridge_highlights(last.2, wh.2, &content_chars[gap_start..gap_end])
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
        .map(|&(s, e, k)| HighlightRange {
            start: s as u64,
            end: e as u64,
            kind: k,
        })
        .collect();

    FuzzyMatch { highlight_ranges }
}

/// Convert matched indices to highlight ranges with a specified kind
#[cfg(test)]
fn indices_to_ranges_with_kind(indices: &[u32], kind: HighlightKind) -> Vec<HighlightRange> {
    if indices.is_empty() {
        return Vec::new();
    }

    let mut sorted = indices.to_vec();
    sorted.sort_unstable();
    sorted.dedup();

    sorted[1..]
        .iter()
        .fold(vec![(sorted[0], sorted[0] + 1)], |mut acc, &idx| {
            let last = acc.last_mut().unwrap();
            if idx == last.1 {
                last.1 = idx + 1;
            } else {
                acc.push((idx, idx + 1));
            }
            acc
        })
        .into_iter()
        .map(|(start, end)| HighlightRange {
            start: start as u64,
            end: end as u64,
            kind,
        })
        .collect()
}

/// Convert matched indices to highlight ranges (defaults to Exact kind)
#[cfg(test)]
fn indices_to_ranges(indices: &[u32]) -> Vec<HighlightRange> {
    indices_to_ranges_with_kind(indices, HighlightKind::Exact)
}

/// Find the highlight in the densest cluster of highlights using a sliding window.
const EARLIER_CLUSTER_COVERAGE_TOLERANCE: u64 = 2;
const EARLIER_CLUSTER_MATCH_SCORE_TOLERANCE: u64 = 1;

pub(crate) fn find_densest_highlight(
    highlights: &[HighlightRange],
    window_size: u64,
) -> Option<usize> {
    if highlights.is_empty() {
        return None;
    }

    let mut indexed: Vec<(usize, &HighlightRange)> = highlights
        .iter()
        .enumerate()
        .filter(|(_, h)| !matches!(h.kind, HighlightKind::PrefixTail))
        .collect();

    if indexed.is_empty() {
        return Some(0);
    }
    if indexed.len() == 1 {
        return Some(indexed[0].0);
    }
    indexed.sort_by_key(|(_, h)| h.start);

    let mut left = 0;
    let mut best_left = 0;
    let mut best_coverage = 0u64;
    let mut best_anchor_score = 0u64;
    let mut current_coverage = 0u64;

    for right in 0..indexed.len() {
        while indexed[left].1.start + window_size <= indexed[right].1.start {
            current_coverage -= indexed[left].1.end - indexed[left].1.start;
            left += 1;
        }
        current_coverage += indexed[right].1.end - indexed[right].1.start;

        let current_start = indexed[left].1.start;
        let current_anchor_score = highlight_match_score(indexed[left].1.kind);
        let best_start = indexed[best_left].1.start;

        if cluster_beats_best(
            current_coverage,
            current_anchor_score,
            current_start,
            best_coverage,
            best_anchor_score,
            best_start,
        ) {
            best_coverage = current_coverage;
            best_anchor_score = current_anchor_score;
            best_left = left;
        }
    }

    Some(indexed[best_left].0)
}

fn highlight_match_score(kind: HighlightKind) -> u64 {
    match kind {
        HighlightKind::Exact => 6,
        HighlightKind::Prefix => 5,
        HighlightKind::PrefixTail => 0,
        HighlightKind::SubwordPrefix => 4,
        HighlightKind::Substring => 3,
        HighlightKind::Fuzzy => 2,
        HighlightKind::Subsequence => 1,
    }
}

fn cluster_beats_best(
    current_coverage: u64,
    current_anchor_score: u64,
    current_start: u64,
    best_coverage: u64,
    best_anchor_score: u64,
    best_start: u64,
) -> bool {
    if current_coverage > best_coverage + EARLIER_CLUSTER_COVERAGE_TOLERANCE {
        return true;
    }
    if current_coverage + EARLIER_CLUSTER_COVERAGE_TOLERANCE < best_coverage {
        return false;
    }

    if current_anchor_score > best_anchor_score + EARLIER_CLUSTER_MATCH_SCORE_TOLERANCE {
        return true;
    }
    if current_anchor_score + EARLIER_CLUSTER_MATCH_SCORE_TOLERANCE < best_anchor_score {
        return false;
    }

    current_start < best_start
}

/// Generate a generous text snippet around the densest cluster of highlights.
pub(crate) fn generate_snippet(
    content: &str,
    highlights: &[HighlightRange],
    max_len: usize,
) -> (String, Vec<HighlightRange>, u64) {
    let policy = ExcerptPolicy {
        whitespace_mode: WhitespaceMode::CollapseAll,
        max_chars: max_len,
        context_chars: SNIPPET_CONTEXT_CHARS,
    };
    generate_snippet_with_policy(content, highlights, &policy)
}

/// Generate a text snippet using a presentation-profile-driven policy.
pub(crate) fn generate_snippet_with_policy(
    content: &str,
    highlights: &[HighlightRange],
    policy: &ExcerptPolicy,
) -> (String, Vec<HighlightRange>, u64) {
    let max_len = policy.max_chars;
    let content_char_len = content.chars().count();

    if highlights.is_empty() {
        let (preview, _) = normalize_snippet_with_mapping_ws(
            content,
            0,
            content_char_len,
            max_len,
            policy.whitespace_mode,
        );
        return (preview, Vec::new(), 0);
    }

    let density_window = policy.context_chars as u64;
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

    let context_before = (remaining_space / 2)
        .min(policy.context_chars)
        .min(match_start_char);
    let context_after =
        (remaining_space - context_before).min(content_char_len.saturating_sub(match_end_char));

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
        + (if snippet_end_char < content_char_len {
            1
        } else {
            0
        });
    let effective_max_len = max_len.saturating_sub(ellipsis_reserve);
    let (normalized_snippet, pos_map) = normalize_snippet_with_mapping_ws(
        content,
        snippet_start_char,
        snippet_end_char,
        effective_max_len,
        policy.whitespace_mode,
    );

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

/// Create list decoration from full-content scalar highlights, using a presentation profile.
pub(crate) fn create_list_decoration(
    content: &str,
    highlights: &[HighlightRange],
    profile: ListPresentationProfile,
) -> ListDecoration {
    let policy = ExcerptPolicy::for_profile(profile);
    let (text, adjusted_highlights, line_number) =
        generate_snippet_with_policy(content, highlights, &policy);
    let highlights = scalar_highlights_to_utf16(&text, &adjusted_highlights);

    ListDecoration {
        text,
        highlights,
        line_number,
    }
}

/// Create preview decoration from scalar full-content highlights.
pub(crate) fn create_preview_decoration(
    content: &str,
    analysis: &HighlightAnalysis,
) -> PreviewDecoration {
    let (highlights, initial_scroll_highlight_index) = limit_preview_highlights(
        analysis,
        PreviewHighlightLimit::FocusedWindow {
            max_highlights: PREVIEW_MAX_HIGHLIGHTS,
            context_chars: PREVIEW_HIGHLIGHT_CONTEXT_CHARS,
        },
    );
    PreviewDecoration {
        highlights: scalar_highlights_to_utf16(content, &highlights),
        initial_scroll_highlight_index,
    }
}

pub(crate) fn create_preview_decoration_with_char_offset(
    content: &str,
    analysis: &HighlightAnalysis,
    char_offset: usize,
) -> PreviewDecoration {
    let (focused_highlights, initial_scroll_highlight_index) = limit_preview_highlights(
        analysis,
        PreviewHighlightLimit::FocusedWindow {
            max_highlights: PREVIEW_MAX_HIGHLIGHTS,
            context_chars: PREVIEW_HIGHLIGHT_CONTEXT_CHARS,
        },
    );
    let shifted_highlights: Vec<HighlightRange> = focused_highlights
        .iter()
        .map(|highlight| HighlightRange {
            start: highlight.start + char_offset as u64,
            end: highlight.end + char_offset as u64,
            kind: highlight.kind,
        })
        .collect();

    PreviewDecoration {
        highlights: scalar_highlights_to_utf16(content, &shifted_highlights),
        initial_scroll_highlight_index,
    }
}

pub(crate) fn create_lazy_item_match_with_metadata(item_metadata: ItemMetadata) -> ItemMatch {
    ItemMatch {
        item_metadata,
        list_decoration: None,
    }
}

fn short_query_highlights(content: &str, query: &str, prefer_prefix: bool) -> Vec<HighlightRange> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }

    let content_lower = content.to_lowercase();
    let query_lower = trimmed.to_lowercase();
    let query_char_len = trimmed.chars().count();

    let start = if prefer_prefix && content_lower.starts_with(&query_lower) {
        Some(0)
    } else {
        content_lower
            .find(&query_lower)
            .map(|byte_idx| content_lower[..byte_idx].chars().count())
    };

    start
        .map(|start| HighlightRange {
            start: start as u64,
            end: (start + query_char_len) as u64,
            kind: if start == 0 && prefer_prefix {
                HighlightKind::Prefix
            } else {
                HighlightKind::Exact
            },
        })
        .into_iter()
        .collect()
}

fn compute_scalar_highlights(content: &str, query: &str) -> Vec<HighlightRange> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }

    if trimmed.chars().count() < MIN_TRIGRAM_QUERY_LEN {
        return short_query_highlights(content, trimmed, true);
    }

    let query_words_owned = tokenize_words(trimmed);
    let query_words: Vec<&str> = query_words_owned
        .iter()
        .map(|(_, _, w)| w.as_str())
        .collect();
    let last_word_is_prefix = trimmed.ends_with(|c: char| c.is_alphanumeric());

    let doc_words = tokenize_words(content);

    // Create a temporary FuzzyMatch to reuse highlight_candidate
    let fm = highlight_candidate(&HighlightContext {
        content,
        doc_words: &doc_words,
        query_words: &query_words,
        last_word_is_prefix,
    });

    fm.highlight_ranges
}

pub(crate) fn analyze_content_for_query(content: &str, query: &str) -> Option<HighlightAnalysis> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return None;
    }

    let highlights = compute_scalar_highlights(content, trimmed);
    let initial_scroll_highlight_index =
        find_densest_highlight(&highlights, SNIPPET_CONTEXT_CHARS as u64).map(|idx| idx as u64);

    Some(HighlightAnalysis {
        highlights,
        initial_scroll_highlight_index,
    })
}

/// Lightweight word-match-only analysis for Phase 1-only (tail) items.
///
/// Uses exact + prefix matching only (via `does_word_match_fast_raw`),
/// skipping fuzzy, subsequence, and subword matching for performance.
pub(crate) fn analyze_content_word_match(content: &str, query: &str) -> Option<HighlightAnalysis> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return None;
    }

    let highlights = compute_word_match_highlights(content, trimmed);
    let initial_scroll_highlight_index =
        find_densest_highlight(&highlights, SNIPPET_CONTEXT_CHARS as u64).map(|idx| idx as u64);

    Some(HighlightAnalysis {
        highlights,
        initial_scroll_highlight_index,
    })
}

/// Compute highlights using exact + prefix word matching only.
///
/// For each query word, finds all matching document words and emits highlight
/// ranges. Only `Exact` and `Prefix` match kinds are produced — no fuzzy,
/// subsequence, or subword matching.
fn compute_word_match_highlights(content: &str, query: &str) -> Vec<HighlightRange> {
    let query_words_owned = tokenize_words(query);
    let query_words: Vec<&str> = query_words_owned
        .iter()
        .map(|(_, _, w)| w.as_str())
        .collect();
    let last_word_is_prefix = query.ends_with(|c: char| c.is_alphanumeric());

    let doc_words = tokenize_words(content);
    let query_lower: Vec<String> = query_words.iter().map(|w| w.to_lowercase()).collect();

    let mut highlights: Vec<(usize, usize, HighlightKind)> = Vec::new();

    for (char_start, char_end, doc_word) in &doc_words {
        if !is_word_token(doc_word) {
            continue;
        }
        for (qi, qw_lower) in query_lower.iter().enumerate() {
            if !is_word_token(&query_words[qi]) {
                continue;
            }
            let prefix_match =
                prefix_match_for_query_word(query_lower.len(), qi, last_word_is_prefix);
            let wmk = does_word_match_fast_raw(qw_lower, doc_word, prefix_match);
            if wmk != WordMatchKind::None {
                append_word_highlight(
                    &mut highlights,
                    *char_start,
                    *char_end,
                    &query_words[qi],
                    wmk,
                );
                break;
            }
        }
    }

    highlights.sort_unstable_by_key(|&(s, _, _)| s);

    highlights
        .into_iter()
        .map(|(s, e, k)| HighlightRange {
            start: s as u64,
            end: e as u64,
            kind: k,
        })
        .collect()
}

/// Compute list decoration for an item given a query and presentation profile.
pub(crate) fn compute_list_decoration(
    content: &str,
    query: &str,
    profile: ListPresentationProfile,
) -> ListDecoration {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        let policy = ExcerptPolicy::for_profile(profile);
        let (text, _, _) = generate_snippet_with_policy(content, &[], &policy);
        return ListDecoration {
            text,
            highlights: Vec::new(),
            line_number: 0,
        };
    }

    let analysis =
        analyze_content_for_query(content, trimmed).expect("non-empty query should analyze");
    create_list_decoration(content, &analysis.highlights, profile)
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

fn normalize_snippet_with_mapping_ws(
    content: &str,
    start: usize,
    end: usize,
    max_chars: usize,
    ws_mode: WhitespaceMode,
) -> (String, Vec<usize>) {
    if end <= start {
        return (String::new(), vec![0]);
    }

    let mut result = String::with_capacity(max_chars);
    let mut pos_map = Vec::with_capacity(end - start + 1);
    let mut last_was_space = false;
    let mut consecutive_newlines: usize = 0;
    let mut norm_idx = 0;

    for ch in content.chars().skip(start).take(end - start) {
        pos_map.push(norm_idx);

        if norm_idx >= max_chars {
            continue;
        }

        match ws_mode {
            WhitespaceMode::CollapseAll => {
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
            WhitespaceMode::PreserveLineBreaks => {
                if ch == '\n' {
                    consecutive_newlines += 1;
                    last_was_space = false;
                    // Collapse 3+ newlines into 2 (one blank line)
                    if consecutive_newlines <= 2 {
                        result.push('\n');
                        norm_idx += 1;
                    }
                    continue;
                }
                if ch == '\r' {
                    // Skip carriage returns entirely
                    continue;
                }
                consecutive_newlines = 0;
                let ch = match ch {
                    '\t' => ' ',
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
        }
    }

    pos_map.push(norm_idx);

    // Trim trailing whitespace
    while result.ends_with(' ') || result.ends_with('\n') {
        result.pop();
    }

    (result, pos_map)
}

fn map_position(orig_pos: usize, pos_map: &[usize]) -> Option<usize> {
    pos_map.get(orig_pos).copied()
}

/// Generate a preview from content (no highlights, starts from beginning).
/// Uses CollapseAll whitespace mode (compact row behavior).
pub fn generate_preview(content: &str, max_chars: usize) -> String {
    let trimmed = content.trim_start();
    let (preview, _, _) = generate_snippet(trimmed, &[], max_chars);
    preview
}

/// Generate a preview using a presentation profile's excerpt policy.
pub fn generate_preview_for_profile(
    content: &str,
    profile: ListPresentationProfile,
) -> String {
    let trimmed = content.trim_start();
    let policy = ExcerptPolicy::for_profile(profile);
    let (preview, _, _) = generate_snippet_with_policy(trimmed, &[], &policy);
    preview
}

/// Format a snippet for optimistic updates (e.g. after an edit).
/// Exposed via UniFFI so Swift doesn't need to invent its own truncation.
pub fn format_excerpt(content: &str, profile: ListPresentationProfile) -> String {
    generate_preview_for_profile(content, profile)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_indices_to_ranges() {
        let indices = vec![0, 1, 2, 5, 6, 10];
        let ranges = super::indices_to_ranges(&indices);
        assert_eq!(ranges.len(), 3);
        assert_eq!(
            ranges[0],
            HighlightRange {
                start: 0,
                end: 3,
                kind: HighlightKind::Exact
            }
        );
        assert_eq!(
            ranges[1],
            HighlightRange {
                start: 5,
                end: 7,
                kind: HighlightKind::Exact
            }
        );
        assert_eq!(
            ranges[2],
            HighlightRange {
                start: 10,
                end: 11,
                kind: HighlightKind::Exact
            }
        );
    }

    /// Helper: create a HighlightRange with Exact kind (for tests that don't care about kind)
    fn hr(start: u64, end: u64) -> HighlightRange {
        HighlightRange {
            start,
            end,
            kind: HighlightKind::Exact,
        }
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
        let highlighted: String = snippet
            .chars()
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
        let highlighted: String = snippet
            .chars()
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
        let highlighted: String = snippet
            .chars()
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
        let highlighted: String = snippet
            .chars()
            .skip(h.start as usize)
            .take((h.end - h.start) as usize)
            .collect();
        assert_eq!(highlighted, "MATCH");
    }

    #[test]
    fn test_snippet_utf8_multibyte_chars() {
        let content = "Hello \u{4f60}\u{597d} world \u{1f30d} test";
        let highlights = vec![hr(6, 8)];
        let (snippet, adj_highlights, _) = super::generate_snippet(content, &highlights, 50);
        assert!(snippet.contains("\u{4f60}\u{597d}"));
        assert!(!adj_highlights.is_empty());
        let h = &adj_highlights[0];
        let highlighted: String = snippet
            .chars()
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
        assert_eq!(
            words,
            vec![
                (0, 9, "urlparser".into()),
                (9, 10, ".".into()),
                (10, 15, "parse".into()),
                (15, 16, "(".into()),
                (16, 21, "input".into()),
                (21, 22, ")".into()),
            ]
        );

        // Consecutive punctuation forms one token
        let words = tokenize_words("one--two...three");
        assert_eq!(
            words,
            vec![
                (0, 3, "one".into()),
                (3, 5, "--".into()),
                (5, 8, "two".into()),
                (8, 11, "...".into()),
                (11, 16, "three".into()),
            ]
        );

        // URL tokenization preserves :// as a token
        let words = tokenize_words("https://github.com");
        assert_eq!(
            words,
            vec![
                (0, 5, "https".into()),
                (5, 8, "://".into()),
                (8, 14, "github".into()),
                (14, 15, ".".into()),
                (15, 18, "com".into()),
            ]
        );
    }

    /// Helper: call highlight_candidate with automatic lowercasing/tokenization.
    fn hc(
        _id: i64,
        content: &str,
        _timestamp: i64,
        _tantivy_score: f32,
        query_words: &[&str],
        last_word_is_prefix: bool,
    ) -> FuzzyMatch {
        let doc_words = tokenize_words(content);
        super::highlight_candidate(&super::HighlightContext {
            content,
            doc_words: &doc_words,
            query_words,
            last_word_is_prefix,
        })
    }

    fn highlighted_words(content: &str, query_words: &[&str]) -> Vec<String> {
        let fm = hc(1, content, 1000, 1.0, query_words, false);
        let chars: Vec<char> = content.chars().collect();
        fm.highlight_ranges
            .iter()
            .map(|r| chars[r.start as usize..r.end as usize].iter().collect())
            .collect()
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
        let words: Vec<String> = fm
            .highlight_ranges
            .iter()
            .map(|r| chars[r.start as usize..r.end as usize].iter().collect())
            .collect();
        assert_eq!(words, vec!["test", "ing"]);
        assert_eq!(fm.highlight_ranges[0].kind, HighlightKind::Prefix);
        assert_eq!(fm.highlight_ranges[1].kind, HighlightKind::PrefixTail);
    }

    #[test]
    fn test_highlight_single_char_prefix_match_for_multi_word_query() {
        let fm = hc(
            1,
            "recent changes to highlighting landed",
            1000,
            1.0,
            &["recent", "changes", "to", "h"],
            true,
        );

        assert!(fm.highlight_ranges.iter().any(|range| {
            range.kind == HighlightKind::Prefix && range.start == 18 && range.end == 19
        }));
        assert!(fm
            .highlight_ranges
            .iter()
            .any(|range| range.kind == HighlightKind::PrefixTail));
    }

    #[test]
    fn test_short_query_match_data_prefers_prefix() {
        let highlights = compute_scalar_highlights("Alpha beta", "al");
        assert_eq!(highlights.len(), 1);
        assert_eq!(highlights[0].start, 0);
        assert_eq!(highlights[0].end, 2);
        assert_eq!(highlights[0].kind, HighlightKind::Prefix);
    }

    #[test]
    fn test_short_query_match_data_finds_anywhere_substring() {
        let highlights = compute_scalar_highlights("zz Alpha beta", "ph");
        assert_eq!(highlights.len(), 1);
        assert_eq!(highlights[0].start, 5);
        assert_eq!(highlights[0].end, 7);
        assert_eq!(highlights[0].kind, HighlightKind::Exact);
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
        let query_words: Vec<&str> = query_words_owned
            .iter()
            .map(|(_, _, w)| w.as_str())
            .collect();
        // Punctuation tokens are now real tokens in the query
        assert_eq!(query_words, vec!["http", "://", "github"]);

        let fm = hc(
            1,
            "https://github.com/user/repo",
            1000,
            1.0,
            &query_words,
            false,
        );
        let chars: Vec<char> = "https://github.com/user/repo".chars().collect();
        let words: Vec<String> = fm
            .highlight_ranges
            .iter()
            .map(|r| chars[r.start as usize..r.end as usize].iter().collect())
            .collect();
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
        let highlights = vec![hr(0, 5), hr(1000, 1005), hr(1050, 1055), hr(1100, 1105)];
        let idx = super::find_densest_highlight(&highlights, 500).unwrap();
        assert_eq!(highlights[idx].start, 1000);
    }

    #[test]
    fn test_find_densest_highlight_biases_earlier_when_clusters_are_close() {
        let highlights = vec![hr(0, 4), hr(1000, 1003), hr(1004, 1007)];
        let idx = super::find_densest_highlight(&highlights, 50).unwrap();
        assert_eq!(highlights[idx].start, 0);
    }

    #[test]
    fn test_find_densest_highlight_ignores_prefix_tail() {
        let highlights = vec![
            HighlightRange {
                start: 0,
                end: 4,
                kind: HighlightKind::Prefix,
            },
            HighlightRange {
                start: 4,
                end: 8,
                kind: HighlightKind::PrefixTail,
            },
            HighlightRange {
                start: 100,
                end: 105,
                kind: HighlightKind::Exact,
            },
        ];
        let idx = super::find_densest_highlight(&highlights, 50).unwrap();
        assert_eq!(idx, 0);
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

        let highlights = vec![hr(10, 14), hr(1000, 1006), hr(1008, 1014), hr(1016, 1022)];

        let (snippet, _, _) = super::generate_snippet(&content, &highlights, 100);
        assert!(
            snippet.contains("DENSE1"),
            "Snippet should center on densest cluster, got: {}",
            snippet
        );
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
        query
            .to_lowercase()
            .split_whitespace()
            .map(|s| s.to_string())
            .collect()
    }

    #[test]
    fn test_densest_highlight_prefers_exact_query_match_over_scattered_repeats() {
        let query_words_owned = build_query_words("error: build failed due to dependency");
        let query_words: Vec<&str> = query_words_owned.iter().map(|s| s.as_str()).collect();
        let fm = hc(1, NIX_BUILD_ERROR, 1000, 1.0, &query_words, false);

        let densest_idx =
            find_densest_highlight(&fm.highlight_ranges, SNIPPET_CONTEXT_CHARS as u64).unwrap();
        let densest_start = fm.highlight_ranges[densest_idx].start as usize;

        let final_block =
            "error: Cannot build '/nix/store/djv08y006z7jk69j2q9fq5f1ch195i4s-home-manager.drv'.";
        let final_block_byte_pos = NIX_BUILD_ERROR.rfind(final_block).unwrap();
        let final_block_char_pos = NIX_BUILD_ERROR[..final_block_byte_pos].chars().count();

        assert!(
            densest_start >= final_block_char_pos,
            "Densest highlight at char {} should be in final error block (char {}+). \
             Points to: {:?}",
            densest_start,
            final_block_char_pos,
            NIX_BUILD_ERROR
                .chars()
                .skip(densest_start)
                .take(60)
                .collect::<String>()
        );
    }

    #[test]
    fn test_snippet_centers_on_exact_query_match_not_scattered_repeats() {
        let query_words_owned = build_query_words("error: build failed due to dependency");
        let query_words: Vec<&str> = query_words_owned.iter().map(|s| s.as_str()).collect();
        let fm = hc(1, NIX_BUILD_ERROR, 1000, 1.0, &query_words, false);

        let (snippet, _, _) = generate_snippet(
            NIX_BUILD_ERROR,
            &fm.highlight_ranges,
            SNIPPET_CONTEXT_CHARS * 2,
        );

        assert!(
            snippet.contains("Build failed due to failed dependency"),
            "Snippet should center on the near-exact match line, got: {}",
            snippet
        );
    }

    #[test]
    fn test_prefix_highlight_does_not_outrank_earlier_exact_match() {
        let content = "func top level\n\nlet x = 1;\n\nfunction later match";
        let highlights = compute_scalar_highlights(content, "func");

        assert!(highlights.len() >= 3);

        let first = &highlights[0];
        let second = &highlights[1];

        assert_eq!(first.start, 0);
        assert_eq!(first.end, 4);
        assert_eq!(first.kind, HighlightKind::Exact);

        let second_highlighted: String = content
            .chars()
            .skip(second.start as usize)
            .take((second.end - second.start) as usize)
            .collect();
        assert_eq!(second.kind, HighlightKind::Prefix);
        assert_eq!(second_highlighted, "func");

        let third = &highlights[2];
        let third_highlighted: String = content
            .chars()
            .skip(third.start as usize)
            .take((third.end - third.start) as usize)
            .collect();
        assert_eq!(third.kind, HighlightKind::PrefixTail);
        assert_eq!(third_highlighted, "tion");

        let preview = create_preview_decoration(
            content,
            &HighlightAnalysis {
                initial_scroll_highlight_index: Some(0),
                highlights: highlights.clone(),
            },
        );
        assert_eq!(preview.initial_scroll_highlight_index, Some(0));

        let row = compute_list_decoration(content, "func", ListPresentationProfile::CompactRow);
        assert!(row.text.contains("func top level"));
    }

    #[test]
    fn test_preview_decoration_limits_highlights_around_anchor() {
        let content = "x".repeat(3000);
        let highlights: Vec<HighlightRange> = (0..200)
            .map(|index| HighlightRange {
                start: (index * 10) as u64,
                end: (index * 10 + 1) as u64,
                kind: HighlightKind::Exact,
            })
            .collect();
        let analysis = HighlightAnalysis {
            highlights,
            initial_scroll_highlight_index: Some(100),
        };

        let preview = create_preview_decoration(&content, &analysis);

        assert!(preview.highlights.len() <= PREVIEW_MAX_HIGHLIGHTS);
        let anchor_index = preview.initial_scroll_highlight_index.unwrap() as usize;
        assert!(anchor_index < preview.highlights.len());
        assert_eq!(preview.highlights[anchor_index].utf16_start, 1000);
    }

    #[test]
    fn test_preview_decoration_with_char_offset_limits_and_shifts_anchor() {
        let content = "x".repeat(4000);
        let highlights: Vec<HighlightRange> = (0..150)
            .map(|index| HighlightRange {
                start: (index * 8) as u64,
                end: (index * 8 + 2) as u64,
                kind: HighlightKind::Exact,
            })
            .collect();
        let analysis = HighlightAnalysis {
            highlights,
            initial_scroll_highlight_index: Some(75),
        };

        let preview = create_preview_decoration_with_char_offset(&content, &analysis, 500);

        assert!(preview.highlights.len() <= PREVIEW_MAX_HIGHLIGHTS);
        let anchor_index = preview.initial_scroll_highlight_index.unwrap() as usize;
        assert!(anchor_index < preview.highlights.len());
        assert_eq!(preview.highlights[anchor_index].utf16_start, 1100);
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
        assert_eq!(fm.highlight_ranges.len(), 2);
        assert_eq!(fm.highlight_ranges[0].kind, HighlightKind::Prefix);
        assert_eq!(fm.highlight_ranges[1].kind, HighlightKind::PrefixTail);
    }

    #[test]
    fn test_highlight_match_kind_subword_prefix() {
        let fm = hc(1, "responseCode", 1000, 1.0, &["code"], false);
        assert_eq!(fm.highlight_ranges.len(), 1);
        assert_eq!(fm.highlight_ranges[0].kind, HighlightKind::SubwordPrefix);
    }

    #[test]
    fn test_highlight_match_kind_substring() {
        let fm = hc(1, "import data", 1000, 1.0, &["port"], false);
        assert_eq!(fm.highlight_ranges.len(), 1);
        assert_eq!(fm.highlight_ranges[0].kind, HighlightKind::Substring);
    }

    #[test]
    fn test_highlight_match_kind_fuzzy() {
        // "riversde" matches "riverside" via fuzzy edit distance
        let fm = hc(
            1,
            "Visit Riverside Park today",
            1000,
            1.0,
            &["riversde"],
            false,
        );
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
