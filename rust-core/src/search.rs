//! Two-Layer Search Engine (L1 Tantivy -> L2 Nucleo)
//!
//! Layer 1 (Retrieval): Filters millions of items down to candidates using trigram indexing.
//! Layer 2 (Precision): Scores words independently with Nucleo for contiguity bonuses.
//!                      Rejects scattered noise, and natively handles typos.

use crate::indexer::{Indexer, IndexerResult};
use crate::models::{HighlightRange, MatchData, ItemMatch, StoredItem};
use chrono::Utc;
use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};
use regex::RegexBuilder;

/// Maximum results to return for trigram queries (after fuzzy re-ranking)
pub const MAX_RESULTS_TRIGRAM: usize = 5000;

/// Maximum results to return for short queries
pub const MAX_RESULTS_SHORT: usize = 2000;

pub const MIN_TRIGRAM_QUERY_LEN: usize = 3;

/// Maximum recency boost multiplier (e.g., 0.1 = up to 10% boost for brand new items)
const RECENCY_BOOST_MAX: f64 = 0.1;
const RECENCY_HALF_LIFE_SECS: f64 = 7.0 * 24.0 * 60.0 * 60.0;

/// Minimum ratio of adjacent character pairs for Nucleo matches to be valid.
const MIN_ADJACENCY_RATIO: f64 = 0.25;

/// Boost factor for prefix matches in short query scoring
const PREFIX_MATCH_BOOST: f64 = 2.0;

/// Context chars to include before/after match in snippet
const SNIPPET_CONTEXT_CHARS: usize = 30;

/// Max snippet length
const MAX_SNIPPET_LEN: usize = 200;

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

pub struct SearchEngine {
    config: Config,
}

impl SearchEngine {
    pub fn new() -> Self {
        Self { config: Config::DEFAULT }
    }

    /// Search using Tantivy + Nucleo for trigram queries (>= 3 chars)
    pub fn search(&self, indexer: &Indexer, query: &str) -> IndexerResult<Vec<FuzzyMatch>> {
        if query.trim().is_empty() {
            return Ok(Vec::new());
        }
        let trimmed = query.trim_start();

        let has_trailing_space = query.ends_with(' ');
        let query_words: Vec<&str> = trimmed.trim_end().split_whitespace().collect();

        // L1: Strict Tantivy filtering - don't cap early, let Nucleo filter
        let candidates = indexer.search(trimmed.trim_end())?;

        let mut matcher = Matcher::new(self.config.clone());
        let patterns: Vec<Pattern> = query_words
            .iter()
            .map(|w| Pattern::parse(w, CaseMatching::Ignore, Normalization::Smart))
            .collect();

        let mut matches = Vec::with_capacity(candidates.len().min(MAX_RESULTS_TRIGRAM * 2));
        let now = Utc::now().timestamp();

        // L2: Independent Word Scoring
        for candidate in candidates {
            if let Some(fuzzy_match) = self.score_candidate(
                candidate.id,
                &candidate.content,
                candidate.timestamp,
                &query_words,
                &patterns,
                has_trailing_space,
                &mut matcher,
                false, // not checking prefix for trigram queries
            ) {
                matches.push(fuzzy_match);
            }
        }

        matches.sort_unstable_by(|a, b| {
            let score_a = blended_score(a.score, a.timestamp, now, false);
            let score_b = blended_score(b.score, b.timestamp, now, false);
            score_b.total_cmp(&score_a).then_with(|| b.timestamp.cmp(&a.timestamp))
        });

        matches.truncate(MAX_RESULTS_TRIGRAM);
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

        results.truncate(MAX_RESULTS_SHORT);
        results
    }

    /// Core Scoring Logic: Analyzes a document against split query words
    fn score_candidate(
        &self,
        id: i64,
        content: &str,
        timestamp: i64,
        words: &[&str],
        patterns: &[Pattern],
        has_trailing_space: bool,
        matcher: &mut Matcher,
        check_prefix: bool,
    ) -> Option<FuzzyMatch> {
        let mut haystack_buf = Vec::new();
        let haystack = Utf32Str::new(content, &mut haystack_buf);

        let mut total_score = 0;
        let mut all_indices = Vec::new();

        for (i, &word) in words.iter().enumerate() {
            let mut word_indices = Vec::new();
            let word_len = word.chars().count() as u32;

            let score = patterns[i].indices(haystack, matcher, &mut word_indices)
                .filter(|_| passes_density_check(word_len, &word_indices))?;

            total_score += score;
            all_indices.extend_from_slice(&word_indices);
        }

        all_indices.sort_unstable();
        all_indices.dedup();

        // Trailing Space Boost: boost matches where the word ends at a word boundary
        if has_trailing_space {
            if let Some(&last_idx) = all_indices.last().filter(|&&i| i < 10_000) {
                let ends_at_boundary = content.chars().nth((last_idx + 1) as usize)
                    .map_or(true, |c| c.is_whitespace());
                if ends_at_boundary {
                    total_score = (total_score as f32 * 1.2) as u32;
                }
            }
        }

        // Check if this is a prefix match (for short query scoring)
        let is_prefix_match = if check_prefix && !words.is_empty() {
            let first_word = words[0].to_lowercase();
            content.to_lowercase().starts_with(&first_word)
        } else {
            false
        };

        Some(FuzzyMatch {
            id,
            score: total_score,
            matched_indices: all_indices,
            timestamp,
            content: content.to_string(),
            is_prefix_match,
        })
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

    /// Generate a text snippet around the first match with context
    /// - Adds leading ellipsis "…" if snippet doesn't start at beginning
    /// - Adds trailing ellipsis "…" if snippet doesn't reach the end
    /// - Normalizes whitespace (newlines/tabs -> spaces, collapse consecutive)
    /// - Adjusts highlight ranges to account for ellipsis offset
    pub fn generate_snippet(content: &str, highlights: &[HighlightRange], max_len: usize) -> (String, Vec<HighlightRange>, u64) {
        let content_len = content.len();

        if highlights.is_empty() {
            // No highlights, return first max_len chars (normalized)
            let content_chars: usize = content.chars().count();
            let needs_trailing = content_chars > max_len;
            let effective_len = if needs_trailing { max_len - 1 } else { max_len };
            let preview = normalize_snippet(content, 0, content_len, effective_len);
            let result = if needs_trailing {
                format!("{}…", preview)
            } else {
                preview
            };
            return (result, Vec::new(), 0);
        }

        let first_highlight = &highlights[0];
        let match_start = first_highlight.start as usize;
        let match_end = first_highlight.end as usize;

        // Find line number (count newlines before match)
        let line_number = content[..match_start.min(content_len)]
            .chars()
            .filter(|&c| c == '\n')
            .count() as u64;

        // Determine if we'll need ellipses
        let will_need_leading = match_start > SNIPPET_CONTEXT_CHARS;
        let will_need_trailing = match_end + SNIPPET_CONTEXT_CHARS < content_len;

        // Reserve space for ellipses
        let leading_reserve = if will_need_leading { 1 } else { 0 };
        let trailing_reserve = if will_need_trailing { 1 } else { 0 };
        let effective_max = max_len.saturating_sub(leading_reserve + trailing_reserve);

        // Start with the match, then expand with context
        // The match must always be fully included
        let match_char_len = match_end - match_start;
        let remaining_space = effective_max.saturating_sub(match_char_len);

        // Split remaining space: prefer context before (up to SNIPPET_CONTEXT_CHARS)
        let context_before = (remaining_space / 2).min(SNIPPET_CONTEXT_CHARS).min(match_start);
        let context_after = (remaining_space - context_before).min(content_len - match_end);

        let mut snippet_start = match_start - context_before;
        let snippet_end = (match_end + context_after).min(content_len);

        // Try to adjust start to word boundary (but don't go past what we need for the match)
        if snippet_start > 0 {
            // Look for whitespace in a small window before snippet_start
            let search_start = snippet_start.saturating_sub(10);
            if let Some(space_pos) = content[search_start..snippet_start].rfind(char::is_whitespace) {
                // Only adjust if it doesn't push us past our space budget
                let new_start = search_start + space_pos + 1;
                if new_start <= match_start.saturating_sub(context_before) {
                    snippet_start = new_start;
                }
            }
        }

        // Extract the raw snippet (no normalization - would break highlight alignment)
        let raw_snippet: String = content.chars()
            .skip(snippet_start)
            .take(snippet_end - snippet_start)
            .collect();

        // Determine actual ellipsis needs based on final bounds
        let needs_leading = snippet_start > 0;
        let needs_trailing = snippet_end < content_len;

        // Build final snippet with ellipses
        let mut final_snippet = String::with_capacity(raw_snippet.len() + 2);
        if needs_leading {
            final_snippet.push('…');
        }
        final_snippet.push_str(&raw_snippet);
        if needs_trailing {
            final_snippet.push('…');
        }

        // Adjust highlight ranges relative to snippet
        // Account for: original offset + leading ellipsis
        let ellipsis_offset = if needs_leading { 1 } else { 0 };

        let adjusted_highlights: Vec<HighlightRange> = highlights
            .iter()
            .filter_map(|h| {
                let start = (h.start as usize).checked_sub(snippet_start)?;
                let end = (h.end as usize).saturating_sub(snippet_start);
                if start < raw_snippet.len() {
                    Some(HighlightRange {
                        start: (start + ellipsis_offset) as u64,
                        end: (end.min(raw_snippet.len()) + ellipsis_offset) as u64,
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
        let highlights = Self::indices_to_ranges(&fuzzy_match.matched_indices);
        let (text, adjusted_highlights, line_number) = Self::generate_snippet(
            &fuzzy_match.content,
            &highlights,
            MAX_SNIPPET_LEN,
        );

        MatchData {
            text,
            highlights: adjusted_highlights,
            line_number,
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
    fn default() -> Self { Self::new() }
}

/// Density check: reject scattered character matches ("soup" detection).
fn passes_density_check(word_len: u32, indices: &[u32]) -> bool {
    if word_len <= 3 { return true; }
    let total_pairs = indices.len().saturating_sub(1);
    if total_pairs == 0 { return true; }

    let adjacent = indices.windows(2).filter(|w| w[1] == w[0] + 1).count();
    (adjacent as f64 / total_pairs as f64) > MIN_ADJACENCY_RATIO
}

/// Calculate blended score combining Nucleo fuzzy score with recency
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

/// Normalize a snippet: convert newlines/tabs to spaces, collapse consecutive spaces
fn normalize_snippet(content: &str, start: usize, end: usize, max_chars: usize) -> String {
    let mut result = String::with_capacity(max_chars);
    let mut last_was_space = false;
    let mut count = 0;

    for ch in content.chars().skip(start).take(end - start) {
        if count >= max_chars {
            break;
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
        count += 1;
    }

    // Trim trailing space
    if result.ends_with(' ') {
        result.pop();
    }

    result
}

/// Use regex for performant highlighting
pub fn highlight_with_regex(text: &str, query: &str) -> Vec<HighlightRange> {
    if query.is_empty() {
        return Vec::new();
    }

    let mut ranges = Vec::new();

    // Escape regex special characters and build pattern
    let escaped_query = regex::escape(query);
    if let Ok(regex) = RegexBuilder::new(&escaped_query)
        .case_insensitive(true)
        .build()
    {
        for mat in regex.find_iter(text).take(100) {
            ranges.push(HighlightRange {
                start: mat.start() as u64,
                end: mat.end() as u64,
            });
        }
    }

    // If no exact matches and query is long enough, try trigram matching
    if ranges.is_empty() && query.len() >= 3 {
        let query_lower = query.to_lowercase();
        let text_lower = text.to_lowercase();
        let chars: Vec<char> = query_lower.chars().collect();

        for i in 0..chars.len().saturating_sub(2) {
            let trigram: String = chars[i..i + 3].iter().collect();
            let mut start = 0;
            while let Some(pos) = text_lower[start..].find(&trigram) {
                let abs_pos = start + pos;
                // Check for overlaps
                let overlaps = ranges.iter().any(|r| {
                    abs_pos < r.end as usize && abs_pos + 3 > r.start as usize
                });
                if !overlaps {
                    ranges.push(HighlightRange {
                        start: abs_pos as u64,
                        end: (abs_pos + 3) as u64,
                    });
                }
                start = abs_pos + 1;
                if ranges.len() >= 100 {
                    break;
                }
            }
            if ranges.len() >= 100 {
                break;
            }
        }
    }

    // Sort by position
    ranges.sort_by_key(|r| r.start);
    ranges
}

/// Compute highlights for preview pane (full content)
pub fn compute_preview_highlights(content: &str, query: &str) -> Vec<HighlightRange> {
    if query.trim().is_empty() {
        return Vec::new();
    }
    highlight_with_regex(content, query.trim())
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
    fn test_highlight_with_regex() {
        let text = "Hello world, hello again";
        let highlights = highlight_with_regex(text, "hello");
        assert_eq!(highlights.len(), 2);
        assert_eq!(highlights[0], HighlightRange { start: 0, end: 5 });
        assert_eq!(highlights[1], HighlightRange { start: 13, end: 18 });
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
    fn test_snippet_leading_ellipsis_when_not_at_start() {
        // Match is in the middle of content - should have leading ellipsis
        let content = "The quick brown fox jumps over the lazy dog and runs away fast";
        let highlights = vec![HighlightRange { start: 35, end: 39 }]; // "lazy"
        let (snippet, adj_highlights, _) = SearchEngine::generate_snippet(content, &highlights, 30);

        assert!(snippet.starts_with('…'), "Snippet should start with ellipsis when not at beginning, got: {}", snippet);
        assert!(snippet.contains("lazy"), "Snippet should contain the match");
        // Highlight should be offset by 1 for the leading ellipsis
        assert!(!adj_highlights.is_empty());
        let first_highlight = &adj_highlights[0];
        let highlighted_text: String = snippet.chars()
            .skip(first_highlight.start as usize)
            .take((first_highlight.end - first_highlight.start) as usize)
            .collect();
        assert_eq!(highlighted_text, "lazy", "Highlight should mark 'lazy', got: {}", highlighted_text);
    }

    #[test]
    fn test_snippet_no_leading_ellipsis_at_start() {
        // Match is at the start - no leading ellipsis
        let content = "Hello world";
        let highlights = vec![HighlightRange { start: 0, end: 5 }]; // "Hello"
        let (snippet, adj_highlights, _) = SearchEngine::generate_snippet(content, &highlights, 50);

        assert!(!snippet.starts_with('…'), "Snippet should not start with ellipsis at beginning");
        assert_eq!(adj_highlights[0].start, 0, "Highlight should start at 0");
    }

    #[test]
    fn test_snippet_trailing_ellipsis_when_truncated() {
        // Long content that gets truncated - should have trailing ellipsis
        let content = "Start of text with match here and then lots more content that goes on and on";
        let highlights = vec![HighlightRange { start: 20, end: 25 }]; // "match"
        let (snippet, _, _) = SearchEngine::generate_snippet(content, &highlights, 40);

        assert!(snippet.ends_with('…'), "Snippet should end with ellipsis when truncated, got: {}", snippet);
    }

    #[test]
    fn test_snippet_no_trailing_ellipsis_at_end() {
        // Short content that fits entirely - no trailing ellipsis
        let content = "Short text";
        let highlights = vec![HighlightRange { start: 0, end: 5 }]; // "Short"
        let (snippet, _, _) = SearchEngine::generate_snippet(content, &highlights, 50);

        assert!(!snippet.ends_with('…'), "Snippet should not end with ellipsis when not truncated");
        assert_eq!(snippet, "Short text");
    }

    #[test]
    fn test_snippet_preserves_whitespace() {
        // Snippets preserve original whitespace (normalization would break highlight alignment)
        let content = "Line one\n\nLine two";
        let highlights = vec![HighlightRange { start: 0, end: 4 }]; // "Line"
        let (snippet, adj_highlights, _) = SearchEngine::generate_snippet(content, &highlights, 50);

        // Whitespace is preserved
        assert!(snippet.contains('\n'), "Snippet should preserve newlines");
        // But highlights still work correctly
        let h = &adj_highlights[0];
        let highlighted: String = snippet.chars()
            .skip(h.start as usize)
            .take((h.end - h.start) as usize)
            .collect();
        assert_eq!(highlighted, "Line");
    }

    #[test]
    fn test_snippet_highlight_adjustment_with_ellipsis() {
        // When ellipsis is added at start, highlight positions must shift by 1
        let content = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaTARGET text here";
        let highlights = vec![HighlightRange { start: 46, end: 52 }]; // "TARGET"
        let (snippet, adj_highlights, _) = SearchEngine::generate_snippet(content, &highlights, 30);

        assert!(snippet.starts_with('…'));
        assert!(snippet.contains("TARGET"));

        // Verify the adjusted highlight correctly marks TARGET in the snippet
        let h = &adj_highlights[0];
        let highlighted: String = snippet.chars()
            .skip(h.start as usize)
            .take((h.end - h.start) as usize)
            .collect();
        assert_eq!(highlighted, "TARGET", "Adjusted highlight should mark TARGET, got: '{}'", highlighted);
    }

    #[test]
    fn test_snippet_both_ellipses() {
        // Match in middle of very long content - both ellipses needed
        let long_prefix = "a".repeat(100);
        let long_suffix = "z".repeat(100);
        let content = format!("{}MATCH{}", long_prefix, long_suffix);
        let highlights = vec![HighlightRange { start: 100, end: 105 }]; // "MATCH"
        let (snippet, adj_highlights, _) = SearchEngine::generate_snippet(&content, &highlights, 30);

        assert!(snippet.starts_with('…'), "Should have leading ellipsis");
        assert!(snippet.ends_with('…'), "Should have trailing ellipsis");
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
}
