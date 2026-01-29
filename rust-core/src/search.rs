//! Two-Layer Search Engine (L1 Tantivy -> L2 Nucleo)
//!
//! Layer 1 (Retrieval): Filters millions of items down to ~2000 using strict Boolean logic.
//! Layer 2 (Precision): Scores words independently with Nucleo for contiguity bonuses.
//!                      Rejects scattered noise, and natively handles typos.

use crate::indexer::{Indexer, IndexerResult};
use crate::models::HighlightRange;
use chrono::Utc;
use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};

/// Maximum results to return after fuzzy re-ranking
const MAX_RESULTS: usize = 2000;

pub const MIN_TRIGRAM_QUERY_LEN: usize = 3;
const MIN_SCORE_SHORT_QUERY: u32 = 0;
/// Maximum recency boost multiplier (e.g., 0.1 = up to 10% boost for brand new items)
const RECENCY_BOOST_MAX: f64 = 0.1;
const RECENCY_HALF_LIFE_SECS: f64 = 7.0 * 24.0 * 60.0 * 60.0;
/// Minimum ratio of adjacent character pairs for Nucleo matches to be valid.
const MIN_ADJACENCY_RATIO: f64 = 0.25;

#[derive(Debug, Clone)]
pub struct FuzzyMatch {
    pub id: i64,
    pub score: u32,
    pub nucleo_score: Option<u32>,
    pub tantivy_score: Option<f32>,
    pub matched_indices: Vec<u32>,
    pub timestamp: i64,
}

pub struct SearchEngine {
    config: Config,
}

impl SearchEngine {
    pub fn new() -> Self {
        Self { config: Config::DEFAULT }
    }

    pub fn search(&self, indexer: &Indexer, query: &str) -> IndexerResult<Vec<FuzzyMatch>> {
        let trimmed = query.trim_start();
        if trimmed.trim().is_empty() {
            return Ok(Vec::new()); // Let the outer layer fetch default recent items
        }

        let has_trailing_space = query.ends_with(' ');
        let query_words: Vec<&str> = trimmed.trim_end().split_whitespace().collect();

        // L1: Strict Tantivy filtering guarantees all words exist (solves scatter & scale)
        let candidates = indexer.search(trimmed.trim_end())?;
        if candidates.is_empty() {
            return Ok(Vec::new());
        }

        let mut matcher = Matcher::new(self.config.clone());
        let patterns: Vec<Pattern> = query_words
            .iter()
            .map(|w| Pattern::parse(w, CaseMatching::Ignore, Normalization::Smart))
            .collect();

        let mut matches = Vec::with_capacity(candidates.len());
        let now = Utc::now().timestamp();

        // L2: Independent Word Scoring (§8)
        for candidate in candidates {
            if let Some(fuzzy_match) = self.score_candidate(
                candidate.id,
                &candidate.content,
                candidate.timestamp,
                Some(candidate.tantivy_score),
                &query_words,
                &patterns,
                has_trailing_space,
                &mut matcher,
            ) {
                matches.push(fuzzy_match);
            }
        }

        matches.sort_unstable_by(|a, b| {
            let score_a = blended_score(a.score, a.timestamp, now);
            let score_b = blended_score(b.score, b.timestamp, now);
            match score_b.partial_cmp(&score_a) {
                Some(std::cmp::Ordering::Equal) | None => b.timestamp.cmp(&a.timestamp),
                Some(ord) => ord,
            }
        });

        matches.truncate(MAX_RESULTS);
        Ok(matches)
    }

    pub fn filter_batch(
        &self,
        candidates: impl Iterator<Item = (i64, String, i64)>,
        query: &str,
        results: &mut Vec<FuzzyMatch>,
        max_results: usize,
    ) -> usize {
        let trimmed = query.trim_start();
        if trimmed.trim().is_empty() { return 0; }

        let has_trailing_space = query.ends_with(' ');
        let query_words: Vec<&str> = trimmed.trim_end().split_whitespace().collect();
        let mut matcher = Matcher::new(self.config.clone());
        let patterns: Vec<Pattern> = query_words
            .iter()
            .map(|w| Pattern::parse(w, CaseMatching::Ignore, Normalization::Smart))
            .collect();

        let mut found = 0;
        let query_len = trimmed.trim_end().chars().count();

        for (id, content, timestamp) in candidates.take(max_results * 10) {
            if results.len() >= max_results { break; }
            if let Some(fuzzy_match) = self.score_candidate(
                id, &content, timestamp, None, &query_words, &patterns, has_trailing_space, &mut matcher,
            ) {
                if query_len < 3 && fuzzy_match.score < MIN_SCORE_SHORT_QUERY { continue; }
                results.push(fuzzy_match);
                found += 1;
            }
        }
        found
    }

    /// Core Scoring Logic: Analyzes a document against split query words
    fn score_candidate(
        &self,
        id: i64,
        content: &str,
        timestamp: i64,
        tantivy_score: Option<f32>,
        words: &[&str],
        patterns: &[Pattern],
        has_trailing_space: bool,
        matcher: &mut Matcher,
    ) -> Option<FuzzyMatch> {
        let mut haystack_buf = Vec::new();
        let haystack = Utf32Str::new(content, &mut haystack_buf);

        let mut total_score = 0;
        let mut all_indices = Vec::new();

        for (i, &word) in words.iter().enumerate() {
            let mut word_indices = Vec::new();
            let mut word_matched = false;
            let word_len = word.chars().count() as u32;

            // 1. Try Nucleo (Fast, Contiguous, Word-Boundary Aware)
            if let Some(score) = patterns[i].indices(haystack, matcher, &mut word_indices) {
                // Density-based scatter detection: reject scattered character matches
                // Apply to all words > 3 chars to catch "soup" matches
                let is_valid = if word_len <= 3 {
                    // Very short words (1-3 chars): trust Nucleo implicitly
                    true
                } else {
                    let total_pairs = word_indices.len().saturating_sub(1);
                    if total_pairs == 0 {
                        true
                    } else {
                        let adjacent_pairs = word_indices.windows(2)
                            .filter(|w| w[1] == w[0] + 1)
                            .count();
                        (adjacent_pairs as f64 / total_pairs as f64) > MIN_ADJACENCY_RATIO
                    }
                };

                if is_valid {
                    total_score += score;
                    all_indices.extend_from_slice(&word_indices);
                    word_matched = true;
                }
            }

            // 2. Typo Fallback (If Nucleo failed or scattered due to transposed letters like "rivreside")
            if !word_matched && word_len >= 3 {
                let content_lower = content.to_lowercase();
                let word_chars: Vec<char> = word.to_lowercase().chars().collect();
                let num_trigrams = word_chars.len().saturating_sub(2);

                // Count matching trigrams and collect byte positions
                let mut matching_trigram_count = 0;
                let mut byte_matches = Vec::new();
                for j in 0..num_trigrams {
                    let trigram: String = word_chars[j..j+3].iter().collect();
                    if let Some(_byte_idx) = content_lower.find(&trigram) {
                        matching_trigram_count += 1;
                        // Collect all occurrences for highlighting
                        for (idx, _) in content_lower.match_indices(&trigram) {
                            byte_matches.push(idx);
                        }
                    }
                }

                // Require 2/3 of trigrams to match
                let min_matching = ((num_trigrams + 1) * 2 / 3).max(2);
                if matching_trigram_count < min_matching {
                    // Not enough trigrams matched - reject this word
                    word_matched = false;
                } else {
                    word_matched = true;
                    total_score += word_len * 15; // Synthetic comparable score

                    byte_matches.sort_unstable();
                    byte_matches.dedup();

                    let mut char_idx = 0;
                    let mut byte_idx_iter = byte_matches.iter().peekable();

                    // Zero-allocation byte-to-char index mapping for UI highlighting
                    for (b_idx, _) in content_lower.char_indices() {
                        if char_idx > 10_000 { break; } // Latency protection on 5MB dumps
                        if byte_idx_iter.peek().is_none() { break; }

                        while let Some(&&target_b_idx) = byte_idx_iter.peek() {
                            if b_idx == target_b_idx {
                                all_indices.extend_from_slice(&[char_idx, char_idx + 1, char_idx + 2]);
                                byte_idx_iter.next();
                            } else if target_b_idx < b_idx {
                                byte_idx_iter.next();
                            } else {
                                break;
                            }
                        }
                        char_idx += 1;
                    }
                }
            }

            // Missing Atom Exclusion (§4)
            if !word_matched { return None; }
        }

        all_indices.sort_unstable();
        all_indices.dedup();

        // Trailing Space Boost: boost matches where the word ends at a word boundary
        if has_trailing_space {
            if let Some(&last_idx) = all_indices.last() {
                if last_idx < 10_000 { // Latency limit
                    let next_char = content.chars().nth((last_idx + 1) as usize);
                    // Check for whitespace specifically, not just non-alphanumeric
                    // This distinguishes "hello " from "hello("
                    if next_char.map_or(true, |c| c.is_whitespace()) {
                        total_score = (total_score as f32 * 1.2) as u32;
                    }
                }
            }
        }

        Some(FuzzyMatch {
            id,
            score: total_score,
            nucleo_score: Some(total_score),
            tantivy_score,
            matched_indices: all_indices,
            timestamp,
        })
    }

    pub fn max_results() -> usize { MAX_RESULTS }

    pub fn indices_to_ranges(indices: &[u32]) -> Vec<HighlightRange> {
        if indices.is_empty() { return Vec::new(); }
        let mut ranges = Vec::new();
        let mut sorted = indices.to_vec();
        sorted.sort_unstable();
        sorted.dedup();

        let mut start = sorted[0];
        let mut end = start + 1;

        for &idx in &sorted[1..] {
            if idx == end {
                end = idx + 1;
            } else {
                ranges.push(HighlightRange { start, end });
                start = idx;
                end = idx + 1;
            }
        }
        ranges.push(HighlightRange { start, end });
        ranges
    }
}

impl Default for SearchEngine {
    fn default() -> Self { Self::new() }
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
            let _results = engine.search(&indexer, query).unwrap();
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
