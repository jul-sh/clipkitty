//! Search Engine (Tantivy with phrase-boost scoring + substring highlighting)
//!
//! Tantivy handles retrieval and scoring via trigram indexing with per-word PhraseQuery
//! boosts for contiguity-aware ranking. Highlighting uses simple case-insensitive
//! substring search. Short queries (< 3 chars) use a streaming fallback.

use crate::indexer::{Indexer, IndexerResult};
use crate::interface::{HighlightRange, MatchData, ItemMatch};
use crate::models::StoredItem;
use chrono::Utc;

/// Maximum results to return from search.
/// Returning more than this is not useful to the user.
pub const MAX_RESULTS: usize = 5000;

pub const MIN_TRIGRAM_QUERY_LEN: usize = 3;

/// Maximum recency boost multiplier (e.g., 0.1 = up to 10% boost for brand new items)
const RECENCY_BOOST_MAX: f64 = 0.1;
const RECENCY_HALF_LIFE_SECS: f64 = 7.0 * 24.0 * 60.0 * 60.0;

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

    /// Search using Tantivy with phrase-boost scoring for trigram queries (>= 3 chars)
    pub fn search(&self, indexer: &Indexer, query: &str) -> IndexerResult<Vec<FuzzyMatch>> {
        if query.trim().is_empty() {
            return Ok(Vec::new());
        }
        let trimmed = query.trim_start();

        let has_trailing_space = query.ends_with(' ');
        let query_words: Vec<&str> = trimmed.trim_end().split_whitespace().collect();

        // Tantivy retrieval with phrase-boost scoring
        let candidates = indexer.search(trimmed.trim_end())?;

        let mut matches = Vec::with_capacity(candidates.len().min(MAX_RESULTS * 2));
        let now = Utc::now().timestamp();

        for candidate in candidates {
            let fm = Self::highlight_candidate(
                candidate.id,
                &candidate.content,
                candidate.timestamp,
                candidate.tantivy_score,
                &query_words,
                has_trailing_space,
            );
            matches.push(fm);
        }

        matches.sort_unstable_by(|a, b| {
            let score_a = blended_score(a.score, a.timestamp, now, false);
            let score_b = blended_score(b.score, b.timestamp, now, false);
            score_b.total_cmp(&score_a).then_with(|| b.timestamp.cmp(&a.timestamp))
        });

        matches.truncate(MAX_RESULTS);
        Ok(matches)
    }

    /// Score candidates for short queries (< 3 chars)
    /// Uses recency as primary metric with prefix match boost
    pub fn score_short_query_batch(
        &self,
        candidates: impl Iterator<Item = (i64, String, i64, bool)>, // (id, content, timestamp, is_prefix)
        query: &str,
    ) -> Vec<FuzzyMatch> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Vec::new();
        }

        let query_lower = trimmed.to_lowercase();
        let mut results = Vec::new();
        let now = Utc::now().timestamp();

        for (id, content, timestamp, is_prefix_match) in candidates {
            // Find match position for highlighting
            let content_lower = content.to_lowercase();
            if let Some(pos) = content_lower.find(&query_lower) {
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

                results.push(FuzzyMatch {
                    id,
                    score,
                    matched_indices,
                    timestamp,
                    content,
                    is_prefix_match,
                });
            }
        }

        // Sort by blended score (recency primary, prefix boost)
        results.sort_unstable_by(|a, b| {
            let score_a = blended_score(a.score, a.timestamp, now, a.is_prefix_match);
            let score_b = blended_score(b.score, b.timestamp, now, b.is_prefix_match);
            score_b.total_cmp(&score_a).then_with(|| b.timestamp.cmp(&a.timestamp))
        });

        results.truncate(MAX_RESULTS);
        results
    }

    /// Highlight a Tantivy-confirmed candidate using case-insensitive substring search.
    /// Tantivy has already confirmed relevance — this finds highlight positions
    /// and converts the tantivy_score to a u32 for blended_score compatibility.
    fn highlight_candidate(
        id: i64,
        content: &str,
        timestamp: i64,
        tantivy_score: f32,
        words: &[&str],
        has_trailing_space: bool,
    ) -> FuzzyMatch {
        let content_lower = content.to_lowercase();
        let mut all_indices = Vec::new();

        for &word in words {
            let word_lower = word.to_lowercase();
            if let Some(byte_pos) = content_lower.find(&word_lower) {
                // Convert byte offset to char offset (downstream expects char indices)
                let char_start = content[..byte_pos].chars().count();
                let char_len = word_lower.chars().count();
                for i in 0..char_len {
                    all_indices.push((char_start + i) as u32);
                }
            }
        }

        all_indices.sort_unstable();
        all_indices.dedup();

        // Scale tantivy_score to u32 for blended_score compatibility.
        // Quantize coarsely so that small BM25 differences (e.g. from
        // minor document length variation) are treated as ties, letting
        // the recency tiebreaker determine ordering.
        let mut score = ((tantivy_score as u32).max(1)) * 1000;

        // Trailing Space Boost: boost matches where the word ends at a word boundary
        if has_trailing_space {
            if let Some(&last_idx) = all_indices.last().filter(|&&i| i < 10_000) {
                let ends_at_boundary = content.chars().nth((last_idx + 1) as usize)
                    .map_or(true, |c| c.is_whitespace());
                if ends_at_boundary {
                    score = (score as f32 * 1.2) as u32;
                }
            }
        }

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

/// Calculate blended score combining Tantivy score with recency
/// For short queries, recency is the primary factor with prefix boost
fn blended_score(fuzzy_score: u32, timestamp: i64, now: i64, is_prefix_match: bool) -> f64 {
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
    fn test_blended_score() {
        let now = 1700000000i64;

        // Same fuzzy score, different timestamps - recent should win
        let recent = blended_score(1000, now, now, false);
        let old = blended_score(1000, now - 86400 * 30, now, false); // 30 days old
        assert!(recent > old, "Recent items should score higher with same quality");

        // Prefix match should boost score
        let prefix = blended_score(1000, now, now, true);
        let non_prefix = blended_score(1000, now, now, false);
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
}
