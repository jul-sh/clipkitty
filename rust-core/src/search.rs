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

                // Count matching trigrams to filter spurious matches
                let total_trigrams = query_chars.len().saturating_sub(2);
                let mut matching_trigrams = 0;

                // Generate trigrams and find positions
                for i in 0..total_trigrams {
                    let trigram: String = query_chars[i..i + 3].iter().collect();
                    if content_lower.contains(&trigram) {
                        matching_trigrams += 1;
                        // Add highlight indices for this trigram
                        let mut start = 0;
                        while let Some(inner_pos) = content_lower[start..].find(&trigram) {
                            let abs_pos = start + inner_pos;
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
                indices.sort();

                // Require at least 2/3 of trigrams to match for typo tolerance
                // This filters spurious matches like "Follow" matching "hello" (only "llo" overlaps)
                let min_matching = (total_trigrams * 2 / 3).max(2);
                if matching_trigrams < min_matching {
                    continue; // Skip this candidate - not enough overlap
                }

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
