//! Tantivy-Only Search Engine
//!
//! Single-layer search using Tantivy trigram index with custom scoring.
//! Replaces the previous two-layer Tantivy+Nucleo approach with a simpler,
//! purely trigram-based implementation.
//!
//! Scoring considers:
//! - Trigram overlap (how many query trigrams appear in content)
//! - Contiguity bonus (consecutive trigram matches score higher)
//! - Word boundary bonus (matches at word starts score higher)
//! - Exact substring bonus (trailing space indicates word boundary preference)
//!
//! Final ranking blends trigram score with recency, giving recent items a slight edge.

use crate::indexer::{Indexer, IndexerResult, SearchCandidate};
use crate::models::HighlightRange;
use chrono::Utc;

/// Maximum results to return after scoring
const MAX_RESULTS: usize = 2000;

/// Minimum query length for trigram search (shorter queries use streaming fallback)
pub const MIN_TRIGRAM_QUERY_LEN: usize = 3;

/// Maximum recency boost multiplier (e.g., 0.1 = up to 10% boost for brand new items)
const RECENCY_BOOST_MAX: f64 = 0.1;

/// Half-life for recency decay in seconds (7 days)
const RECENCY_HALF_LIFE_SECS: f64 = 7.0 * 24.0 * 60.0 * 60.0;

/// A match result with score and highlight indices
#[derive(Debug, Clone)]
pub struct FuzzyMatch {
    pub id: i64,
    pub score: u32,
    pub matched_indices: Vec<u32>,
    pub timestamp: i64,
}

/// Tantivy-only search engine using trigram-based scoring
pub struct SearchEngine {
    // No internal state needed - all scoring is stateless
}

impl SearchEngine {
    pub fn new() -> Self {
        Self {}
    }

    /// Perform search using Tantivy trigram retrieval and custom scoring
    pub fn search(&self, indexer: &Indexer, query: &str) -> IndexerResult<Vec<FuzzyMatch>> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }

        // Preserve trailing space for exact match boost
        let has_trailing_space = query.ends_with(' ');

        // Get candidates from Tantivy
        let candidates = indexer.search(query)?;

        if candidates.is_empty() {
            return Ok(Vec::new());
        }

        // Score candidates using trigram-based analysis
        let mut matches = if trimmed.chars().count() >= MIN_TRIGRAM_QUERY_LEN {
            self.trigram_score(candidates, trimmed, has_trailing_space)
        } else {
            self.short_query_score(candidates, trimmed, has_trailing_space)
        };

        // Sort by blended score: trigram score + recency boost
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

    /// Score candidates for queries with 3+ characters using trigram analysis
    fn trigram_score(
        &self,
        candidates: Vec<SearchCandidate>,
        query: &str,
        has_trailing_space: bool,
    ) -> Vec<FuzzyMatch> {
        let mut matches = Vec::with_capacity(candidates.len());

        let query_lower = query.to_lowercase();
        let query_chars: Vec<char> = query_lower.chars().collect();
        let total_trigrams = query_chars.len().saturating_sub(2);

        // For exact match check with trailing space
        let exact_match_query = if has_trailing_space {
            format!("{} ", query_lower)
        } else {
            query_lower.clone()
        };

        for candidate in candidates {
            let content_lower = candidate.content.to_lowercase();
            let mut indices = Vec::new();
            let mut matching_trigrams = 0;
            let mut contiguous_runs = 0;
            let mut last_match_end: Option<usize> = None;

            // Generate trigrams and find positions
            for i in 0..total_trigrams {
                let trigram: String = query_chars[i..i + 3].iter().collect();
                if let Some(pos) = content_lower.find(&trigram) {
                    matching_trigrams += 1;

                    // Track contiguity - consecutive trigrams that are adjacent in content
                    if let Some(last_end) = last_match_end {
                        if pos == last_end || pos == last_end + 1 {
                            contiguous_runs += 1;
                        }
                    }
                    last_match_end = Some(pos + 3);

                    // Add highlight indices (first occurrence only)
                    for offset in 0..3 {
                        let idx = (pos + offset) as u32;
                        if !indices.contains(&idx) {
                            indices.push(idx);
                        }
                    }
                }
            }
            indices.sort();

            // Require at least 2/3 of trigrams to match (or at least 1 for very short queries)
            // For queries with 1-3 trigrams, require at least 1 match
            // For longer queries, require 2/3 with minimum of 2
            let min_matching = if total_trigrams <= 3 {
                1
            } else {
                (total_trigrams * 2 / 3).max(2)
            };
            if matching_trigrams < min_matching {
                continue;
            }

            // Calculate score based on:
            // 1. Base: matching trigram ratio × 100
            // 2. Contiguity bonus: +20 per contiguous run
            // 3. Word boundary bonus: +50 if match at word start
            // 4. Exact substring bonus: ×1.5 if exact match with trailing space

            let base_score = (matching_trigrams as f64 / total_trigrams as f64 * 100.0) as u32;
            let contiguity_bonus = contiguous_runs * 20;

            // Word boundary detection
            let word_boundary_bonus = if let Some(first_idx) = indices.first() {
                let idx = *first_idx as usize;
                if idx == 0 {
                    50 // Match at content start
                } else {
                    let prev_char = content_lower.chars().nth(idx - 1);
                    if prev_char.map(|c| !c.is_alphanumeric()).unwrap_or(true) {
                        30 // Match at word start
                    } else {
                        0
                    }
                }
            } else {
                0
            };

            let mut score = base_score + contiguity_bonus + word_boundary_bonus;

            // Exact substring bonus for trailing space queries
            if has_trailing_space && content_lower.contains(&exact_match_query) {
                score = (score as f64 * 1.5) as u32;
            }

            matches.push(FuzzyMatch {
                id: candidate.id,
                score,
                matched_indices: indices,
                timestamp: candidate.timestamp,
            });
        }

        matches
    }

    /// Score candidates for short queries (1-2 characters) using substring matching
    fn short_query_score(
        &self,
        candidates: Vec<SearchCandidate>,
        query: &str,
        has_trailing_space: bool,
    ) -> Vec<FuzzyMatch> {
        let mut matches = Vec::with_capacity(candidates.len());

        let query_lower = query.to_lowercase();

        // For exact match check with trailing space
        let exact_match_query = if has_trailing_space {
            format!("{} ", query_lower)
        } else {
            query_lower.clone()
        };

        for candidate in candidates {
            let content_lower = candidate.content.to_lowercase();

            // Find all occurrences of the query
            let mut indices = Vec::new();
            let mut pos = 0;
            while let Some(found) = content_lower[pos..].find(&query_lower) {
                let abs_pos = pos + found;
                for i in 0..query_lower.len() {
                    indices.push((abs_pos + i) as u32);
                }
                pos = abs_pos + 1;
                if pos >= content_lower.len() {
                    break;
                }
            }

            if indices.is_empty() {
                continue;
            }

            // Score based on:
            // 1. Base: 100 for any match
            // 2. Word boundary bonus: +50 if match at word start
            // 3. Exact substring bonus: ×1.5 if exact match with trailing space

            let first_idx = indices[0] as usize;
            let word_boundary_bonus = if first_idx == 0 {
                50
            } else {
                let prev_char = content_lower.chars().nth(first_idx - 1);
                if prev_char.map(|c| !c.is_alphanumeric()).unwrap_or(true) {
                    30
                } else {
                    0
                }
            };

            let mut score = 100 + word_boundary_bonus;

            // Exact substring bonus for trailing space queries
            if has_trailing_space && content_lower.contains(&exact_match_query) {
                score = (score as f64 * 1.5) as u32;
            }

            matches.push(FuzzyMatch {
                id: candidate.id,
                score,
                matched_indices: indices,
                timestamp: candidate.timestamp,
            });
        }

        matches
    }

    /// Filter a batch of candidates directly (for streaming search)
    /// Used for short queries where trigram index isn't effective
    pub fn filter_batch(
        &self,
        candidates: impl Iterator<Item = (i64, String, i64)>,
        query: &str,
        results: &mut Vec<FuzzyMatch>,
        max_results: usize,
    ) -> usize {
        let query_lower = query.to_lowercase().trim().to_string();
        let has_trailing_space = query.ends_with(' ');
        let exact_match_query = if has_trailing_space {
            format!("{} ", query_lower)
        } else {
            query_lower.clone()
        };

        let mut found = 0;

        for (id, content, timestamp) in candidates {
            if results.len() >= max_results {
                break;
            }

            let content_lower = content.to_lowercase();

            // Find occurrences
            let mut indices = Vec::new();
            let mut pos = 0;
            while let Some(found_pos) = content_lower[pos..].find(&query_lower) {
                let abs_pos = pos + found_pos;
                for i in 0..query_lower.len() {
                    indices.push((abs_pos + i) as u32);
                }
                pos = abs_pos + 1;
                if pos >= content_lower.len() {
                    break;
                }
            }

            if indices.is_empty() {
                continue;
            }

            // Score with word boundary detection
            let first_idx = indices[0] as usize;
            let word_boundary_bonus = if first_idx == 0 {
                50
            } else {
                let prev_char = content_lower.chars().nth(first_idx - 1);
                if prev_char.map(|c| !c.is_alphanumeric()).unwrap_or(true) {
                    30
                } else {
                    0
                }
            };

            let mut score = 100 + word_boundary_bonus;

            if has_trailing_space && content_lower.contains(&exact_match_query) {
                score = (score as f64 * 1.5) as u32;
            }

            results.push(FuzzyMatch {
                id,
                score,
                matched_indices: indices,
                timestamp,
            });
            found += 1;
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

/// Calculate blended score combining trigram score with recency
/// Uses multiplicative boost to preserve quality ordering while favoring recent items
fn blended_score(trigram_score: u32, timestamp: i64, now: i64) -> f64 {
    let base_score = trigram_score as f64;

    // Calculate recency factor (exponential decay, half-life of 7 days)
    let age_seconds = (now - timestamp).max(0) as f64;
    let decay_factor = (-age_seconds * 2.0_f64.ln() / RECENCY_HALF_LIFE_SECS).exp();

    // Apply recency as multiplicative boost (up to RECENCY_BOOST_MAX)
    base_score * (1.0 + RECENCY_BOOST_MAX * decay_factor)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_indices_to_ranges() {
        // Empty
        assert!(SearchEngine::indices_to_ranges(&[]).is_empty());

        // Single
        let ranges = SearchEngine::indices_to_ranges(&[5]);
        assert_eq!(ranges.len(), 1);
        assert_eq!(ranges[0].start, 5);
        assert_eq!(ranges[0].end, 6);

        // Consecutive
        let ranges = SearchEngine::indices_to_ranges(&[1, 2, 3]);
        assert_eq!(ranges.len(), 1);
        assert_eq!(ranges[0].start, 1);
        assert_eq!(ranges[0].end, 4);

        // Non-consecutive
        let ranges = SearchEngine::indices_to_ranges(&[1, 3, 5]);
        assert_eq!(ranges.len(), 3);

        // Mixed
        let ranges = SearchEngine::indices_to_ranges(&[1, 2, 5, 6, 7, 10]);
        assert_eq!(ranges.len(), 3);
        assert_eq!((ranges[0].start, ranges[0].end), (1, 3));
        assert_eq!((ranges[1].start, ranges[1].end), (5, 8));
        assert_eq!((ranges[2].start, ranges[2].end), (10, 11));
    }

    #[test]
    fn test_blended_score() {
        let now = 1000000;

        // Brand new item gets max boost
        let score_new = blended_score(100, now, now);
        assert!(score_new > 100.0);
        assert!(score_new <= 110.1, "Expected max ~10% boost, got {}", score_new); // Max 10% boost

        // 7-day old item gets ~half boost
        let week_ago = now - (7 * 24 * 60 * 60);
        let score_week = blended_score(100, week_ago, now);
        assert!(score_week > 100.0);
        assert!(score_week < score_new);

        // Very old item gets minimal boost
        let month_ago = now - (30 * 24 * 60 * 60);
        let score_old = blended_score(100, month_ago, now);
        assert!(score_old >= 100.0);
        assert!(score_old < 101.0);
    }

    #[test]
    fn test_short_query_scores() {
        let engine = SearchEngine::new();

        // Test that short query matching works correctly
        let candidates = vec![
            (1, "Hello world".to_string(), 100),
            (2, "xhello".to_string(), 100),
            (3, "Hellooo".to_string(), 100),
        ];

        let mut results = Vec::new();
        engine.filter_batch(candidates.into_iter(), "he", &mut results, 100);

        assert_eq!(results.len(), 3);
        // All should have base score of at least 100
        for r in &results {
            assert!(r.score >= 100);
        }
    }
}

#[cfg(test)]
mod perf_tests {
    use super::*;

    fn run_benchmark(num_items: usize) {
        let engine = SearchEngine::new();

        // Generate synthetic candidates
        let candidates: Vec<(i64, String, i64)> = (0..num_items)
            .map(|i| {
                let content = format!(
                    "Item {} with some text content for testing search performance {}",
                    i,
                    i % 100
                );
                (i as i64, content, 1000 + i as i64)
            })
            .collect();

        // Benchmark short query filtering
        let start = std::time::Instant::now();
        let mut results = Vec::new();
        engine.filter_batch(candidates.into_iter(), "te", &mut results, 2000);
        let elapsed = start.elapsed();

        println!(
            "\n[Tantivy-only] filter_batch {} items: {:?} ({:.2} items/ms)",
            num_items,
            elapsed,
            num_items as f64 / elapsed.as_millis() as f64
        );
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
