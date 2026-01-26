//! Two-Layer Search Engine
//!
//! Layer 1 (Retrieval): Tantivy trigram index narrows down to ~5k candidates
//! Layer 2 (Precision): Nucleo re-ranks and generates character indices for highlighting
//!
//! Final ranking blends Nucleo's fuzzy score with recency, trusting Nucleo to naturally
//! boost exact/contiguous matches while giving recent items a slight edge.

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

/// Minimum Nucleo score for trigram-backed matches (looser since pre-filtered)
const MIN_SCORE_TRIGRAM: u32 = 0;

/// Recency weight in blended score (0.0 = pure fuzzy, 1.0 = pure recency)
const RECENCY_WEIGHT: f64 = 0.2;

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
    /// 2. Re-rank with Nucleo matcher and extract character indices
    pub fn search(&self, indexer: &Indexer, query: &str) -> IndexerResult<Vec<FuzzyMatch>> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }

        // Layer 1: Get candidates from Tantivy
        let candidates = indexer.search(query)?;

        if candidates.is_empty() {
            return Ok(Vec::new());
        }

        // Layer 2: Fuzzy re-rank and extract indices
        let mut matches = self.fuzzy_rerank(candidates, trimmed);

        // Sort by blended score: Nucleo fuzzy score + recency boost
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
    fn fuzzy_rerank(&self, candidates: Vec<SearchCandidate>, query: &str) -> Vec<FuzzyMatch> {
        let mut matches = Vec::with_capacity(candidates.len());
        let mut matcher = Matcher::new(self.config.clone());

        // Parse the query pattern (case-insensitive, unicode normalized)
        let pattern = Pattern::parse(query, CaseMatching::Ignore, Normalization::Smart);

        for candidate in candidates {
            // Convert content to Utf32Str for Nucleo
            let mut haystack_buf = Vec::new();
            let haystack = Utf32Str::new(&candidate.content, &mut haystack_buf);

            // Buffer for matched indices
            let mut indices = Vec::new();

            // Run Nucleo matcher
            if let Some(score) = pattern.indices(haystack, &mut matcher, &mut indices) {
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

        // Minimum score threshold (stricter for short queries to filter scattered matches)
        let min_score = if query.chars().count() < MIN_TRIGRAM_QUERY_LEN {
            MIN_SCORE_SHORT_QUERY
        } else {
            MIN_SCORE_TRIGRAM
        };

        for (id, content, timestamp) in candidates {
            if results.len() >= max_results {
                break;
            }

            let mut haystack_buf = Vec::new();
            let haystack = Utf32Str::new(&content, &mut haystack_buf);
            let mut indices = Vec::new();

            if let Some(score) = pattern.indices(haystack, &mut matcher, &mut indices) {
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
/// Nucleo naturally boosts exact/contiguous matches, recency gives recent items an edge
fn blended_score(fuzzy_score: u32, timestamp: i64, now: i64) -> f64 {
    // Normalize fuzzy score (Nucleo scores can be quite high, use log scale)
    let fuzzy_norm = (fuzzy_score as f64).ln_1p() / (u32::MAX as f64).ln_1p();

    // Exponential decay for recency (half-life based)
    let age_secs = (now - timestamp).max(0) as f64;
    let recency = (-age_secs * 2.0_f64.ln() / RECENCY_HALF_LIFE_SECS).exp();

    // Weighted blend: mostly fuzzy score, slight recency boost
    (1.0 - RECENCY_WEIGHT) * fuzzy_norm + RECENCY_WEIGHT * recency
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
        assert!(recent > old, "Recent items should score higher");

        // Higher fuzzy score should generally win even if older
        let high_score_old = blended_score(10000, now - 86400, now); // 1 day old, high score
        let low_score_new = blended_score(100, now, now); // brand new, low score
        assert!(
            high_score_old > low_score_new,
            "High fuzzy score should beat low score even with recency"
        );
    }
}
