//! Two-Layer Search Engine
//!
//! Layer 1 (Retrieval): Tantivy trigram index narrows down to ~5k candidates
//! Layer 2 (Precision): For 3+ char queries, uses trigram overlap scoring (typo-tolerant).
//!                      For <3 char queries, uses Nucleo subsequence matching.
//!
//! Final ranking blends fuzzy score with recency, giving recent items a slight edge.

use crate::indexer::{Indexer, IndexerResult, SearchCandidate};
use crate::models::HighlightRange;
use chrono::Utc;
use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};

/// Maximum results to return after fuzzy re-ranking
const MAX_RESULTS: usize = 2000;

/// Minimum query length for trigram search (shorter queries use streaming fallback)
pub const MIN_TRIGRAM_QUERY_LEN: usize = 3;

/// Minimum Nucleo score for short query matches (stricter to filter poor matches)
const MIN_SCORE_SHORT_QUERY: u32 = 0;

/// Maximum recency boost multiplier (e.g., 0.1 = up to 10% boost for brand new items)
const RECENCY_BOOST_MAX: f64 = 0.1;

/// Half-life for recency decay in seconds (7 days)
const RECENCY_HALF_LIFE_SECS: f64 = 7.0 * 24.0 * 60.0 * 60.0;

/// A match result with fuzzy score and highlight indices
#[derive(Debug, Clone)]
pub struct FuzzyMatch {
    pub id: i64,
    pub score: u32,
    pub matched_indices: Vec<u32>,
    pub timestamp: i64,
}

/// Two-layer search engine using Nucleo for fast fuzzy matching
pub struct SearchEngine {
    config: Config,
}

impl SearchEngine {
    pub fn new() -> Self {
        Self {
            config: Config::DEFAULT,
        }
    }

    /// Perform two-layer search:
    /// 1. Get candidates from Tantivy (trigram retrieval)
    /// 2. For 3+ char queries: score by trigram overlap (typo-tolerant)
    ///    For <3 char queries: use Nucleo subsequence matching
    pub fn search(&self, indexer: &Indexer, query: &str) -> IndexerResult<Vec<FuzzyMatch>> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }

        // Preserve trailing space for exact match boost
        let has_trailing_space = query.ends_with(' ');

        // Layer 1: Get candidates from Tantivy
        let candidates = indexer.search(query)?;

        if candidates.is_empty() {
            return Ok(Vec::new());
        }

        // Layer 2: Score and extract indices
        // For 3+ char queries, use trigram overlap scoring (typo-tolerant)
        // For shorter queries, use Nucleo subsequence matching
        let mut matches = if trimmed.chars().count() >= MIN_TRIGRAM_QUERY_LEN {
            self.trigram_rerank(candidates, trimmed, has_trailing_space)
        } else {
            self.fuzzy_rerank(candidates, trimmed, has_trailing_space)
        };

        // Sort by blended score: fuzzy score + recency boost
        let now = Utc::now().timestamp();
        matches.sort_by(|a, b| {
            let score_a = blended_score(a.score, a.timestamp, now);
            let score_b = blended_score(b.score, b.timestamp, now);
            score_b
                .partial_cmp(&score_a)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        // Limit results
        matches.truncate(MAX_RESULTS);

        Ok(matches)
    }

    /// Re-rank candidates using Nucleo fuzzy matching and extract character indices
    /// Used for short queries (<3 chars) where trigram matching isn't available
    fn fuzzy_rerank(
        &self,
        candidates: Vec<SearchCandidate>,
        query: &str,
        has_trailing_space: bool,
    ) -> Vec<FuzzyMatch> {
        let mut matches = Vec::with_capacity(candidates.len());
        let mut matcher = Matcher::new(self.config.clone());

        // Parse the query pattern (case-insensitive, unicode normalized)
        let pattern = Pattern::parse(query, CaseMatching::Ignore, Normalization::Smart);

        // For exact substring boost: check if original query had trailing space
        // (Pattern::parse ignores trailing spaces, so we boost exact matches manually)
        let trailing_space_query = if has_trailing_space {
            Some(format!("{} ", query.to_lowercase()))
        } else {
            None
        };

        for candidate in candidates {
            // Convert content to Utf32Str for Nucleo
            let mut haystack_buf = Vec::new();
            let haystack = Utf32Str::new(&candidate.content, &mut haystack_buf);

            // Buffer for matched indices
            let mut indices = Vec::new();

            // Run Nucleo matcher
            if let Some(mut score) = pattern.indices(haystack, &mut matcher, &mut indices) {
                // Boost score if query (with trailing space) appears as exact substring
                // e.g., "hello " should rank "Hello and..." higher than "def hello(..."
                if let Some(ref query_lower) = trailing_space_query {
                    if candidate.content.to_lowercase().contains(query_lower) {
                        score = (score as f64 * 1.2) as u32;
                    }
                }

                matches.push(FuzzyMatch {
                    id: candidate.id,
                    score,
                    matched_indices: indices,
                    timestamp: candidate.timestamp,
                });
            }
        }

        matches
    }

    /// Hybrid scoring: Tantivy for retrieval (typo tolerant) + Nucleo for scoring (contiguity bonuses)
    /// Falls back to Tantivy score when Nucleo doesn't match (typo cases)
    fn trigram_rerank(
        &self,
        candidates: Vec<SearchCandidate>,
        query: &str,
        has_trailing_space: bool,
    ) -> Vec<FuzzyMatch> {
        let mut matches = Vec::with_capacity(candidates.len());
        let mut matcher = Matcher::new(self.config.clone());

        // Parse query for Nucleo matching
        let pattern = Pattern::parse(query, CaseMatching::Ignore, Normalization::Smart);

        // For exact match check with trailing space
        let exact_match_query = if has_trailing_space {
            format!("{} ", query.to_lowercase())
        } else {
            query.to_lowercase()
        };

        for candidate in candidates {
            let mut haystack_buf = Vec::new();
            let haystack = Utf32Str::new(&candidate.content, &mut haystack_buf);
            let mut indices = Vec::new();

            // Try Nucleo scoring first - gives us contiguity/order bonuses for free
            let score = if let Some(nucleo_score) = pattern.indices(haystack, &mut matcher, &mut indices) {
                // Nucleo matched: use its score (includes contiguity bonuses)
                let mut score = nucleo_score;

                // Apply exact substring bonus for trailing space queries
                if has_trailing_space {
                    let content_lower = candidate.content.to_lowercase();
                    if content_lower.contains(&exact_match_query) {
                        score = (score as f64 * 1.5) as u32;
                    }
                }

                score
            } else {
                // Nucleo didn't match (typo case) - fall back to Tantivy score
                // Use trigram-based highlighting instead
                indices.clear();
                let content_lower = candidate.content.to_lowercase();
                let query_lower = query.to_lowercase();
                let query_chars: Vec<char> = query_lower.chars().collect();

                // Generate trigrams and find positions
                for i in 0..query_chars.len().saturating_sub(2) {
                    let trigram: String = query_chars[i..i + 3].iter().collect();
                    let mut start = 0;
                    while let Some(pos) = content_lower[start..].find(&trigram) {
                        let abs_pos = start + pos;
                        for offset in 0..3 {
                            let idx = (abs_pos + offset) as u32;
                            if !indices.contains(&idx) {
                                indices.push(idx);
                            }
                        }
                        start = abs_pos + 1;
                    }
                }
                indices.sort();

                // Scale Tantivy score to be comparable with Nucleo scores
                // Nucleo scores are typically in the hundreds, Tantivy in 0-10 range
                (candidate.tantivy_score * 50.0) as u32
            };

            matches.push(FuzzyMatch {
                id: candidate.id,
                score,
                matched_indices: indices,
                timestamp: candidate.timestamp,
            });
        }

        matches
    }

    /// Filter a batch of candidates directly with Nucleo (for streaming search)
    /// Adds matches to the provided results vector, returns number of matches found
    /// For short queries, requires minimum score to filter out poor matches
    /// Candidates are (id, content, timestamp_unix) tuples
    pub fn filter_batch(
        &self,
        candidates: impl Iterator<Item = (i64, String, i64)>,
        query: &str,
        results: &mut Vec<FuzzyMatch>,
        max_results: usize,
    ) -> usize {
        let mut matcher = Matcher::new(self.config.clone());
        let pattern = Pattern::parse(query, CaseMatching::Ignore, Normalization::Smart);
        let mut found = 0;

        // For exact substring boost (only if query has trailing space)
        let trailing_space_query = if query.ends_with(' ') {
            Some(query.to_lowercase())
        } else {
            None
        };

        // Minimum score threshold for short queries
        let min_score = MIN_SCORE_SHORT_QUERY;

        for (id, content, timestamp) in candidates {
            if results.len() >= max_results {
                break;
            }

            let mut haystack_buf = Vec::new();
            let haystack = Utf32Str::new(&content, &mut haystack_buf);
            let mut indices = Vec::new();

            if let Some(mut score) = pattern.indices(haystack, &mut matcher, &mut indices) {
                // Boost score if query (with trailing space) appears as exact substring
                if let Some(ref query_lower) = trailing_space_query {
                    if content.to_lowercase().contains(query_lower) {
                        score = (score as f64 * 1.2) as u32;
                    }
                }

                if score >= min_score {
                    results.push(FuzzyMatch {
                        id,
                        score,
                        matched_indices: indices,
                        timestamp,
                    });
                    found += 1;
                }
            }
        }

        found
    }

    /// Get max results limit
    pub fn max_results() -> usize {
        MAX_RESULTS
    }

    /// Convert matched character indices to highlight ranges
    /// Groups consecutive indices into ranges for efficient UI rendering
    pub fn indices_to_ranges(indices: &[u32]) -> Vec<HighlightRange> {
        if indices.is_empty() {
            return Vec::new();
        }

        let mut ranges = Vec::new();
        let mut sorted = indices.to_vec();
        sorted.sort();

        let mut start = sorted[0];
        let mut end = sorted[0] + 1;

        for &idx in &sorted[1..] {
            if idx == end {
                // Consecutive - extend range
                end = idx + 1;
            } else {
                // Gap - close current range and start new
                ranges.push(HighlightRange { start, end });
                start = idx;
                end = idx + 1;
            }
        }

        // Close final range
        ranges.push(HighlightRange { start, end });

        ranges
    }
}

impl Default for SearchEngine {
    fn default() -> Self {
        Self::new()
    }
}

/// Calculate blended score combining Nucleo fuzzy score with recency
/// Uses multiplicative boost to preserve quality ordering while favoring recent items
fn blended_score(fuzzy_score: u32, timestamp: i64, now: i64) -> f64 {
    // Use raw fuzzy score (Nucleo's scoring is already well-calibrated)
    let base_score = fuzzy_score as f64;

    // Exponential decay for recency (half-life based)
    let age_secs = (now - timestamp).max(0) as f64;
    let recency_factor = (-age_secs * 2.0_f64.ln() / RECENCY_HALF_LIFE_SECS).exp();

    // Multiplicative boost: score * (1 + boost * recency)
    // This preserves quality ordering - a higher score always beats a lower score
    // but recent items get a small boost within similar quality ranges
    base_score * (1.0 + RECENCY_BOOST_MAX * recency_factor)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_indices_to_ranges() {
        // ... (existing code)
    }

    #[test]
    fn test_short_query_scores() {
        let engine = SearchEngine::new();
        let mut results = Vec::new();
        let now = 1700000000i64;
        let candidates_with_ids = vec![
            (1, "the".to_string(), now),
            (2, "apple".to_string(), now - 100),
            (3, "test".to_string(), now - 200),
            (4, "application".to_string(), now - 300),
            (5, "cat".to_string(), now - 400),
        ];

        engine.filter_batch(candidates_with_ids.into_iter(), "t", &mut results, 10);

        let matched_ids: Vec<i64> = results.iter().map(|m| m.id).collect();
        assert!(matched_ids.contains(&1), "Should match 'the'");
        assert!(matched_ids.contains(&3), "Should match 'test'");
        assert!(matched_ids.contains(&4), "Should match 'application'");
        assert!(matched_ids.contains(&5), "Should match 'cat'");
        assert!(!matched_ids.contains(&2), "Should NOT match 'apple'");
    }

    #[test]
    fn test_blended_score() {
        let now = 1700000000i64;

        // Same fuzzy score, different timestamps - recent should win
        let recent = blended_score(1000, now, now);
        let old = blended_score(1000, now - 86400 * 30, now); // 30 days old
        assert!(recent > old, "Recent items should score higher with same quality");

        // Higher fuzzy score should always win regardless of recency
        // This is the key property of multiplicative boost
        let high_score_old = blended_score(10000, now - 86400 * 365, now); // 1 year old, high score
        let low_score_new = blended_score(100, now, now); // brand new, low score
        assert!(
            high_score_old > low_score_new,
            "High fuzzy score should beat low score even with huge recency difference"
        );

        // Verify boost is bounded (max 10% for brand new items)
        let base = blended_score(1000, now - 86400 * 365, now); // very old, no boost
        let boosted = blended_score(1000, now, now); // brand new, max boost
        let ratio = boosted / base;
        assert!(
            ratio <= 1.11 && ratio >= 1.0,
            "Recency boost should be at most ~10%"
        );
    }
}

/// Ranking behavior tests
/// These tests validate search result ordering for common sense scenarios.
/// Use these to measure algorithm quality and iterate on scoring parameters.
#[cfg(test)]
mod ranking_tests {
    use super::*;

    // =========================================================================
    // Test Utilities
    // =========================================================================

    const DAY: i64 = 86400;

    /// Helper to create a SearchCandidate
    fn candidate(id: i64, content: &str, days_ago: i64) -> SearchCandidate {
        let now = 1700000000i64;
        SearchCandidate {
            id,
            content: content.to_string(),
            timestamp: now - (days_ago * DAY),
            tantivy_score: 1.0, // Default score for tests
        }
    }

    /// Run search and return ordered IDs
    fn search_order(candidates: Vec<SearchCandidate>, query: &str) -> Vec<i64> {
        let engine = SearchEngine::new();
        let has_trailing_space = query.ends_with(' ');
        let mut matches = engine.fuzzy_rerank(candidates, query.trim(), has_trailing_space);

        let now = 1700000000i64;
        matches.sort_by(|a, b| {
            let score_a = blended_score(a.score, a.timestamp, now);
            let score_b = blended_score(b.score, b.timestamp, now);
            score_b
                .partial_cmp(&score_a)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        matches.into_iter().map(|m| m.id).collect()
    }

    /// Assert that id_a comes before id_b in results
    fn assert_before(results: &[i64], id_a: i64, id_b: i64, context: &str) {
        let pos_a = results.iter().position(|&id| id == id_a);
        let pos_b = results.iter().position(|&id| id == id_b);
        match (pos_a, pos_b) {
            (Some(a), Some(b)) => {
                assert!(
                    a < b,
                    "{}: Expected {} before {}, got order {:?}",
                    context, id_a, id_b, results
                );
            }
            (None, _) => panic!("{}: {} not found in results {:?}", context, id_a, results),
            (_, None) => panic!("{}: {} not found in results {:?}", context, id_b, results),
        }
    }

    /// Get Nucleo scores for analysis
    fn get_scores(candidates: Vec<SearchCandidate>, query: &str) -> Vec<(i64, u32, String)> {
        let engine = SearchEngine::new();
        let has_trailing_space = query.ends_with(' ');
        let matches = engine.fuzzy_rerank(candidates, query.trim(), has_trailing_space);
        matches
            .into_iter()
            .map(|m| (m.id, m.score, format!("{:?}", m.matched_indices)))
            .collect()
    }

    // =========================================================================
    // EXACT vs FUZZY MATCH TESTS
    // =========================================================================

    #[test]
    fn exact_match_beats_fuzzy_same_age() {
        // Query "hello" - exact substring should beat fuzzy
        let candidates = vec![
            candidate(1, "hello world", 0),          // exact match
            candidate(2, "hellooo there", 0),        // extra chars
            candidate(3, "h e l l o spaced", 0),     // scattered
        ];
        let order = search_order(candidates, "hello");
        assert_before(&order, 1, 3, "Exact should beat scattered");
    }

    #[test]
    fn exact_match_beats_fuzzy_even_when_older() {
        // Core requirement: exact match from 30 days ago beats fuzzy from today
        let candidates = vec![
            candidate(1, "hello world", 30),             // exact, 30 days old
            candidate(2, "h_e_l_l_o scattered", 0),      // fuzzy (scattered), brand new
        ];
        let order = search_order(candidates, "hello");

        // Get scores for debugging
        let scores = get_scores(
            vec![
                candidate(1, "hello world", 30),
                candidate(2, "h_e_l_l_o scattered", 0),
            ],
            "hello",
        );
        println!("Scores for exact_match_beats_fuzzy_even_when_older: {:?}", scores);

        assert_before(
            &order,
            1,
            2,
            "Exact match (30 days old) should beat scattered fuzzy (today)",
        );
    }

    #[test]
    fn case_insensitive_exact_match() {
        let candidates = vec![
            candidate(1, "HELLO WORLD", 0),
            candidate(2, "Hello World", 0),
            candidate(3, "hello world", 0),
        ];
        let order = search_order(candidates, "hello");
        // All should match and be present
        assert!(order.contains(&1));
        assert!(order.contains(&2));
        assert!(order.contains(&3));
    }

    // =========================================================================
    // RECENCY WITHIN SAME QUALITY
    // =========================================================================

    #[test]
    fn recency_breaks_ties_for_exact_matches() {
        // Same content, different ages - recent should win
        let candidates = vec![
            candidate(1, "hello world", 0),   // today
            candidate(2, "hello world", 7),   // 1 week ago
            candidate(3, "hello world", 30),  // 1 month ago
        ];
        let order = search_order(candidates, "hello");
        assert_before(&order, 1, 2, "Today should beat 1 week ago");
        assert_before(&order, 2, 3, "1 week ago should beat 1 month ago");
    }

    #[test]
    fn recency_breaks_ties_for_fuzzy_matches() {
        // Same fuzzy quality, different ages
        let candidates = vec![
            candidate(1, "hellooo extra", 0),   // today
            candidate(2, "hellooo extra", 14),  // 2 weeks ago
        ];
        let order = search_order(candidates, "hello");
        assert_before(&order, 1, 2, "Recent fuzzy should beat old fuzzy");
    }

    // =========================================================================
    // WORD BOUNDARY PREFERENCES
    // =========================================================================

    #[test]
    fn word_start_match_preferred() {
        // "url" at word start vs mid-word
        let candidates = vec![
            candidate(1, "urlParser function", 0),   // word start
            candidate(2, "the curl command", 0),     // mid-word
        ];
        let order = search_order(candidates, "url");

        let scores = get_scores(
            vec![
                candidate(1, "urlParser function", 0),
                candidate(2, "the curl command", 0),
            ],
            "url",
        );
        println!("Scores for word_start_match_preferred: {:?}", scores);

        assert_before(&order, 1, 2, "Word-start 'url' should beat mid-word 'curl'");
    }

    #[test]
    fn camel_case_word_boundaries() {
        // Nucleo should recognize camelCase boundaries
        let candidates = vec![
            candidate(1, "parseUrl", 0),      // 'url' at camelCase boundary
            candidate(2, "curly hair", 0),    // 'url' scattered across 'curly'
        ];
        let order = search_order(candidates, "url");

        let scores = get_scores(
            vec![candidate(1, "parseUrl", 0), candidate(2, "curly hair", 0)],
            "url",
        );
        println!("Scores for camel_case_word_boundaries: {:?}", scores);

        assert_before(&order, 1, 2, "CamelCase boundary match should rank higher");
    }

    // =========================================================================
    // CONTIGUOUS vs SCATTERED MATCHES
    // =========================================================================

    #[test]
    fn contiguous_beats_scattered() {
        let candidates = vec![
            candidate(1, "testing", 0),           // contiguous 'test'
            candidate(2, "t_e_s_t separated", 0), // scattered
        ];
        let order = search_order(candidates, "test");
        assert_before(&order, 1, 2, "Contiguous should beat scattered");
    }

    #[test]
    fn shorter_match_span_preferred() {
        // "abc" matching 3 chars vs matching across longer span
        let candidates = vec![
            candidate(1, "abc", 0),              // tight match
            candidate(2, "a---b---c", 0),        // spread out
        ];
        let order = search_order(candidates, "abc");
        assert_before(&order, 1, 2, "Tight match should beat spread out");
    }

    // =========================================================================
    // SUBSTRING POSITION
    // =========================================================================

    #[test]
    fn prefix_match_slightly_preferred() {
        // Match at start vs end - Nucleo may slightly prefer prefix
        let candidates = vec![
            candidate(1, "hello there friend", 0),  // prefix
            candidate(2, "my friend says hello", 0), // suffix
        ];
        let order = search_order(candidates, "hello");

        let scores = get_scores(
            vec![
                candidate(1, "hello there friend", 0),
                candidate(2, "my friend says hello", 0),
            ],
            "hello",
        );
        println!("Scores for prefix_match_slightly_preferred: {:?}", scores);

        // Both are exact matches, scores might be equal or prefix slightly higher
        assert!(order.contains(&1) && order.contains(&2));
    }

    // =========================================================================
    // EDGE CASES
    // =========================================================================

    #[test]
    fn very_old_exact_vs_very_new_poor_fuzzy() {
        // Extreme case: 1 year old exact vs brand new poor fuzzy
        let candidates = vec![
            candidate(1, "configuration", 365),  // exact, 1 year old
            candidate(2, "c_o_n_f", 0),           // poor fuzzy, today
        ];
        let order = search_order(candidates, "conf");

        let scores = get_scores(
            vec![
                candidate(1, "configuration", 365),
                candidate(2, "c_o_n_f", 0),
            ],
            "conf",
        );
        println!("Scores for very_old_exact_vs_very_new_poor_fuzzy: {:?}", scores);

        assert_before(
            &order,
            1,
            2,
            "Year-old exact should still beat today's poor fuzzy",
        );
    }

    #[test]
    fn empty_content_handled() {
        let candidates = vec![
            candidate(1, "", 0),
            candidate(2, "hello", 0),
        ];
        let order = search_order(candidates, "hello");
        assert!(!order.contains(&1), "Empty content should not match");
        assert!(order.contains(&2));
    }

    #[test]
    fn special_characters_in_query() {
        let candidates = vec![
            candidate(1, "user@example.com", 0),
            candidate(2, "user_at_example", 0),  // has 'user' and '@' equivalent but not exact
        ];
        let order = search_order(candidates, "user@");

        let scores = get_scores(
            vec![
                candidate(1, "user@example.com", 0),
                candidate(2, "user_at_example", 0),
            ],
            "user@",
        );
        println!("Scores for special_characters_in_query: {:?}", scores);

        // Both should match (user@ matches 'user' + something)
        assert!(order.contains(&1), "Should match user@example.com");
    }

    #[test]
    fn unicode_content() {
        let candidates = vec![
            candidate(1, "héllo wörld", 0),
            candidate(2, "hello world", 0),
        ];
        let order = search_order(candidates, "hello");
        // Both should be searchable
        assert!(order.len() >= 1);
    }

    // =========================================================================
    // SCORE DISTRIBUTION ANALYSIS
    // =========================================================================

    #[test]
    fn analyze_score_distribution() {
        // This test prints score analysis for tuning - not a pass/fail test
        let candidates = vec![
            candidate(1, "hello world", 0),
            candidate(2, "hello world", 7),
            candidate(3, "hello world", 30),
            candidate(4, "hellooo", 0),
            candidate(5, "h e l l o", 0),
            candidate(6, "help low", 0),  // scattered hel-lo
        ];

        let scores = get_scores(candidates.clone(), "hello");
        println!("\n=== Score Distribution for 'hello' ===");
        for (id, score, indices) in &scores {
            let ts = match id {
                1 => 0,
                2 => 7,
                3 => 30,
                _ => 0,
            };
            let now = 1700000000i64;
            let blended = blended_score(*score, now - ts * DAY, now);
            println!(
                "ID {}: nucleo={:6}, blended={:.4}, indices={}",
                id, score, blended, indices
            );
        }
        println!("=====================================\n");
    }

    // =========================================================================
    // RECENCY ORDERING FOR EQUAL MATCHES
    // =========================================================================

    #[test]
    fn recency_preserved_in_equal_quality_matches() {
        // Real-world scenario: history has blaze4, blaze3, blaze2, blaze1
        // Search "blaze" should return them in recency order (most recent first)
        let candidates = vec![
            candidate(1, "blaze4 run test", 1),      // exact match, 1 day old
            candidate(2, "blaze3 run test", 2),      // exact match, 2 days old
            candidate(3, "blaze2 run test", 3),      // exact match, 3 days old
            candidate(4, "blaze1 run test", 4),      // exact match, 4 days old
        ];

        let scores = get_scores(candidates.clone(), "blaze");
        println!("Scores for recency_preserved_in_equal_quality_matches: {:?}", scores);

        let order = search_order(candidates, "blaze");

        // Within exact matches, recency should determine order
        assert_before(&order, 1, 2, "blaze4 (newer) should beat blaze3");
        assert_before(&order, 2, 3, "blaze3 (newer) should beat blaze2");
        assert_before(&order, 3, 4, "blaze2 (newer) should beat blaze1");
    }

    #[test]
    fn exact_match_beats_fuzzy_regardless_of_recency() {
        // Exact "blaze" should beat fuzzy "b_l_a_z_e" even if fuzzy is newer
        let candidates = vec![
            candidate(1, "b_l_a_z_e scattered", 0),  // fuzzy, brand new
            candidate(2, "blaze run test", 7),       // exact, week old
        ];

        let scores = get_scores(candidates.clone(), "blaze");
        println!("Scores for exact_match_beats_fuzzy_regardless_of_recency: {:?}", scores);

        let order = search_order(candidates, "blaze");
        assert_before(&order, 2, 1, "Exact 'blaze' should beat scattered fuzzy");
    }

    #[test]
    fn recency_preserved_identical_content() {
        // Same exact content at different times - pure recency test
        let candidates = vec![
            candidate(1, "SELECT * FROM users", 0),   // today
            candidate(2, "SELECT * FROM users", 1),   // yesterday
            candidate(3, "SELECT * FROM users", 7),   // week ago
            candidate(4, "SELECT * FROM users", 30),  // month ago
        ];
        let order = search_order(candidates, "SELECT");

        assert_eq!(
            order,
            vec![1, 2, 3, 4],
            "Identical content should be ordered by recency"
        );
    }

    // =========================================================================
    // TYPO TOLERANCE (SUBSEQUENCE) TESTS
    // =========================================================================

    #[test]
    fn nucleo_matches_typo_as_subsequence() {
        // Note: Nucleo CAN match "helo" to "hello" because h-e-l-o is a subsequence
        // This test documents this behavior
        let candidates = vec![candidate(1, "hello world", 0)];

        let order = search_order(candidates, "helo");

        // "helo" matches "hello" as subsequence (h-e-l-o skipping one 'l')
        assert_eq!(order.len(), 1, "Nucleo should match 'helo' to 'hello'");
        assert_eq!(order[0], 1);
    }

    // =========================================================================
    // REGRESSION TESTS (add specific cases that broke in the past)
    // =========================================================================

    #[test]
    fn regression_url_in_curl_vs_urlparser() {
        // Reported: "url" was ranking "curl" above "urlParser"
        let candidates = vec![
            candidate(1, "urlParser.parse(input)", 0),
            candidate(2, "curl -X POST https://api.com", 0),
        ];
        let order = search_order(candidates, "url");
        assert_before(&order, 1, 2, "urlParser should beat curl for 'url' query");
    }

    #[test]
    fn regression_hello_space_recent_short_beats_old_long() {
        // Reported: searching "hello " ranks old code snippet above recent simple match
        // Recent "Hello and welcome..." should beat old code snippet
        let candidates = vec![
            candidate(1, "def hello(name: str) -> str: return f'Hello, {name}!'", 90), // 3 months old
            candidate(2, "Hello and welcome to the onboarding flow for new team members...", 2), // 2 days old
        ];

        let scores = get_scores(candidates.clone(), "hello ");
        println!("Scores for regression_hello_space_recent_short_beats_old_long: {:?}", scores);

        let order = search_order(candidates, "hello ");
        assert_before(
            &order,
            2,
            1,
            "Recent 'Hello and welcome...' should beat old code snippet for 'hello ' query",
        );
    }

    #[test]
    fn trailing_space_boosts_exact_substring_match() {
        // When query has trailing space, content with matching space should score higher
        // "hello " should boost "Hello and..." (has "Hello ") over "def hello(" (has "hello(")
        let candidates = vec![
            candidate(1, "def hello(name: str)", 0),           // "hello(" - no space after
            candidate(2, "Hello and welcome to the team", 0),  // "Hello " - has space after
        ];

        // Same age, so only fuzzy score + trailing space boost matters
        let scores = get_scores(candidates.clone(), "hello ");
        println!("Trailing space boost test scores: {:?}", scores);

        // With trailing space boost, id=2 should have higher score
        let score_1 = scores.iter().find(|(id, _, _)| *id == 1).map(|(_, s, _)| *s).unwrap();
        let score_2 = scores.iter().find(|(id, _, _)| *id == 2).map(|(_, s, _)| *s).unwrap();

        assert!(
            score_2 > score_1,
            "Content with 'Hello ' should score higher than 'hello(' for query 'hello ': {} vs {}",
            score_2, score_1
        );

        // Verify the boost is ~20% (1.2x)
        let ratio = score_2 as f64 / score_1 as f64;
        assert!(
            ratio >= 1.15 && ratio <= 1.25,
            "Boost should be ~20%: ratio was {}",
            ratio
        );
    }
}

#[cfg(test)]
mod perf_tests {
    use super::*;
    use crate::indexer::Indexer;
    use std::time::Instant;

    fn run_benchmark(doc_count: usize) {
        let indexer = Indexer::new_in_memory().unwrap();
        let engine = SearchEngine::new();

        let contents = vec![
            "Hello world this is a test document",
            "The quick brown fox jumps over the lazy dog",
            "Rust programming language is fast and safe",
            "ClipKitty clipboard manager for macOS",
            "SELECT * FROM users WHERE id = 123",
            "https://github.com/example/repository",
            "Error: Connection refused at localhost:8080",
            "def hello(name): return f'Hello {name}'",
            "The riverside apartment has a great view",
            "Configuration file settings and options",
        ];

        let now = chrono::Utc::now().timestamp();
        for i in 0..doc_count {
            let content = format!("{} - item number {}", contents[i % contents.len()], i);
            indexer.add_document(i as i64, &content, now - i as i64).unwrap();
        }
        indexer.commit().unwrap();

        println!("\n=== Benchmark: {} documents ===", doc_count);

        let queries = vec![
            ("hello", "hello"),
            ("riverside", "riverside"),
            ("typo", "rivreside"),
            ("phrase", "hello world"),
        ];

        for (name, query) in queries {
            let _ = engine.search(&indexer, query); // warm up

            // Measure just ID lookup (no content loading)
            let start = Instant::now();
            let id_count = indexer.search_ids_only(query).unwrap_or(0);
            let ids_only_time = start.elapsed();

            // Measure with content loading
            let start = Instant::now();
            let candidates = indexer.search(query).unwrap();
            let with_content_time = start.elapsed();

            let start = Instant::now();
            let results = engine.search(&indexer, query).unwrap();
            let total_time = start.elapsed();

            let rerank_time = total_time.saturating_sub(with_content_time);

            println!(
                "{:12} | cand: {:5} | ids: {:>6.2}ms | +content: {:>6.2}ms | rerank: {:>6.2}ms | total: {:>7.2}ms",
                name,
                candidates.len(),
                ids_only_time.as_secs_f64() * 1000.0,
                with_content_time.as_secs_f64() * 1000.0,
                rerank_time.as_secs_f64() * 1000.0,
                total_time.as_secs_f64() * 1000.0,
            );
        }
    }

    #[test]
    fn benchmark_5k() {
        run_benchmark(5_000);
    }

    #[test]
    fn benchmark_50k() {
        run_benchmark(50_000);
    }

    #[test]
    fn benchmark_500k() {
        run_benchmark(500_000);
    }

    #[test]
    #[ignore] // Run with: cargo test benchmark_5m --release -- --ignored --nocapture
    fn benchmark_5m() {
        run_benchmark(5_000_000);
    }
}
