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
    pub nucleo_score: Option<u32>,
    pub tantivy_score: Option<f32>,
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
        // Use timestamp as tiebreaker when scores are equal (newest first)
        let now = Utc::now().timestamp();
        matches.sort_by(|a, b| {
            let score_a = blended_score(a.score, a.timestamp, now);
            let score_b = blended_score(b.score, b.timestamp, now);
            match score_b.partial_cmp(&score_a) {
                Some(std::cmp::Ordering::Equal) | None => b.timestamp.cmp(&a.timestamp),
                Some(ord) => ord,
            }
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
                let nucleo_raw = score;
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
                    nucleo_score: Some(nucleo_raw),
                    tantivy_score: Some(candidate.tantivy_score),
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

        let pattern = Pattern::parse(query, CaseMatching::Ignore, Normalization::Smart);
        let query_lower = query.to_lowercase();

        // Pre-compute exact match string for the bonus check
        let exact_match_query = if has_trailing_space {
            format!("{} ", query_lower)
        } else {
            query_lower.clone()
        };

        for candidate in candidates {
            let mut haystack_buf = Vec::new();
            let haystack = Utf32Str::new(&candidate.content, &mut haystack_buf);
            let mut indices = Vec::new();

            // Run Nucleo scoring
            let nucleo_result = pattern.indices(haystack, &mut matcher, &mut indices);

            // --- 1. THE REFINED "DENSITY CHECK" ---
            let is_valid_nucleo = if nucleo_result.is_none() {
                false
            } else if query.len() <= 5 {
                // Short queries: Trust Nucleo implicitly (scattering is rare/harmless here)
                true
            } else {
                // Long queries: Check adjacency density
                let total_pairs = indices.len().saturating_sub(1);
                if total_pairs == 0 {
                    true
                } else {
                    let adjacent_pairs = indices.windows(2)
                        .filter(|w| w[1] == w[0] + 1)
                        .count();

                    // Require > 30% of characters to be touching their neighbor.
                    // "hello world" = 80%. "h...e...l...l...o" = 0%.
                    (adjacent_pairs as f64 / total_pairs as f64) > 0.3
                }
            };

            let (score, nucleo_score) = if is_valid_nucleo {
                // Nucleo matched and passed the density check
                let mut score = nucleo_result.unwrap();

                if has_trailing_space {
                    let content_lower = candidate.content.to_lowercase();
                    if content_lower.contains(&exact_match_query) {
                        score = (score as f64 * 1.5) as u32;
                    }
                }
                (score, Some(nucleo_result.unwrap()))
            } else {
                // Nucleo failed OR was "scattered soup" -> Fallback to Trigrams
                indices.clear();
                let content_lower = candidate.content.to_lowercase();

                // --- 2. FIX "TRIGRAM SOUP" ---
                // Split by whitespace prevents "o h" from matching "hello how"
                let mut valid_trigrams = Vec::new();
                for word in query_lower.split_whitespace() {
                    let chars: Vec<char> = word.chars().collect();
                    if chars.len() >= 3 {
                        for i in 0..chars.len() - 2 {
                            valid_trigrams.push(chars[i..i + 3].iter().collect::<String>());
                        }
                    }
                }

                let total_trigrams = valid_trigrams.len();
                let mut matching_trigrams = 0;

                for trigram in &valid_trigrams {
                    if content_lower.contains(trigram) {
                        matching_trigrams += 1;
                        let mut start = 0;
                        while let Some(inner_pos) = content_lower[start..].find(trigram) {
                            let abs_pos = start + inner_pos;
                            // Highlight all 3 chars of the trigram
                            for offset in 0..3 {
                                let idx = (abs_pos + offset) as u32;
                                if !indices.contains(&idx) {
                                    indices.push(idx);
                                }
                            }
                            start = abs_pos + 1;
                        }
                    }
                }
                indices.sort_unstable();

                if total_trigrams > 0 {
                    // Require 2/3rds of trigrams to match
                    let min_matching = (total_trigrams * 2 / 3).max(2);
                    if matching_trigrams < min_matching {
                        continue; // ❌ Match rejected!
                    }
                } else {
                     // If query has no valid trigrams (e.g. "yo"), rely purely on Tantivy score
                     // or drop it. Here we drop it if Nucleo failed.
                     continue;
                }

                // Arbitrary fallback score based on Tantivy rank
                ((candidate.tantivy_score * 50.0) as u32, None)
            };

            matches.push(FuzzyMatch {
                id: candidate.id,
                score,
                nucleo_score,
                tantivy_score: Some(candidate.tantivy_score),
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
                let nucleo_raw = score;
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
                        nucleo_score: Some(nucleo_raw),
                        tantivy_score: None, // Streaming search doesn't use Tantivy
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

// Ranking behavior tests have been moved to integration tests in
// tests/preview_video_search.rs to ensure they test the actual search
// path through ClipboardStore.search() rather than internal methods.

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

            // Measure with content loading
            let start = Instant::now();
            let candidates = indexer.search(query).unwrap();
            let with_content_time = start.elapsed();

            let start = Instant::now();
            let results = engine.search(&indexer, query).unwrap();
            let total_time = start.elapsed();

            let rerank_time = total_time.saturating_sub(with_content_time);

            println!(
                "{:12} | cand: {:5} | content: {:>6.2}ms | rerank: {:>6.2}ms | total: {:>7.2}ms",
                name,
                candidates.len(),
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
