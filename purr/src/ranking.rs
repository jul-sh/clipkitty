//! Milli-style bucket ranking for search results.
//!
//! Implements a lexicographic tuple where higher-priority signals always dominate
//! lower ones. 3/3 words ALWAYS beats 2/3, 0 typos ALWAYS beats 1 typo, etc.
//! Recency tiers sit above proximity/exactness/bm25 to strongly prefer recent items
//! when word-match quality is equal.

use crate::search::{tokenize_words, is_word_token};

/// Bucket score tuple — derived Ord gives lexicographic comparison.
/// All components: higher = better.
///
/// Tuple order (most to least important):
/// 1. words_matched — count of query words found
/// 2. typo_score — 255 - total_edit_distance (fewer typos = higher)
/// 3. recency_tier — 3=<1h, 2=<24h, 1=<7d, 0=older (strong recency bias)
/// 4. proximity_score — u16::MAX - sum_of_pair_distances
/// 5. exactness_score — 0-3 level
/// 6. bm25_quantized — BM25 scaled to integer
/// 7. recency — raw unix timestamp (final tiebreaker)
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct BucketScore {
    pub words_matched: u8,
    pub typo_score: u8,
    pub recency_tier: u8,
    pub proximity_score: u16,
    pub exactness_score: u8,
    pub bm25_quantized: u16,
    pub recency: i64,
}

/// Per-query-word match result
struct WordMatch {
    matched: bool,
    edit_dist: u8,
    doc_word_pos: usize,
    is_exact: bool,
    /// Whether this token counts toward the `words_matched` bucket score.
    /// Punctuation tokens (like "://", ".") don't — they participate in
    /// proximity and highlighting only.
    counts_as_match: bool,
}

/// Compute the bucket score for a candidate document.
pub fn compute_bucket_score(
    content: &str,
    query_words: &[&str],
    last_word_is_prefix: bool,
    timestamp: i64,
    bm25_score: f32,
    now: i64,
) -> BucketScore {
    if query_words.is_empty() {
        return BucketScore {
            words_matched: 0,
            typo_score: 255,
            recency_tier: compute_recency_tier(timestamp, now),
            proximity_score: u16::MAX,
            exactness_score: 0,
            bm25_quantized: quantize_bm25(bm25_score),
            recency: timestamp,
        };
    }

    let content_lower = content.to_lowercase();
    let doc_words = tokenize_words(&content_lower);
    let doc_word_strs: Vec<&str> = doc_words.iter().map(|(_, _, w)| w.as_str()).collect();

    let word_matches = match_query_words(query_words, &doc_word_strs, last_word_is_prefix);

    let words_matched = word_matches.iter()
        .filter(|m| m.matched && m.counts_as_match)
        .count() as u8;
    let total_edit_dist: u8 = word_matches
        .iter()
        .filter(|m| m.matched)
        .map(|m| m.edit_dist)
        .sum();
    let typo_score = 255u8.saturating_sub(total_edit_dist);

    let proximity_score = compute_proximity(&word_matches);
    let exactness_score = compute_exactness(content, query_words, &word_matches);
    let bm25_quantized = quantize_bm25(bm25_score);
    let recency_tier = compute_recency_tier(timestamp, now);

    BucketScore {
        words_matched,
        typo_score,
        recency_tier,
        proximity_score,
        exactness_score,
        bm25_quantized,
        recency: timestamp,
    }
}

/// Compute recency tier from timestamp.
/// 3 = last 1 hour, 2 = last 24 hours, 1 = last 7 days, 0 = older
fn compute_recency_tier(timestamp: i64, now: i64) -> u8 {
    let age_secs = (now - timestamp).max(0);
    if age_secs < 3600 {
        3
    } else if age_secs < 86400 {
        2
    } else if age_secs < 604800 {
        1
    } else {
        0
    }
}

/// Quantize BM25 score to u16 for the tiebreaker bucket.
/// Coarse: floor to integer so minor doc-length differences are treated as ties,
/// letting recency break them (matches old log-bucket sort behavior).
fn quantize_bm25(score: f32) -> u16 {
    (score as f64).max(0.0).min(u16::MAX as f64) as u16
}

/// For each query word, find the best-matching document word.
fn match_query_words(
    query_words: &[&str],
    doc_words: &[&str],
    last_word_is_prefix: bool,
) -> Vec<WordMatch> {
    query_words
        .iter()
        .enumerate()
        .map(|(qi, qw)| {
            let qw_lower = qw.to_lowercase();
            let is_last = qi == query_words.len() - 1;
            let allow_prefix = is_last && last_word_is_prefix;
            let counts_as_match = is_word_token(qw);

            let mut best: Option<WordMatch> = None;

            for (dpos, dw) in doc_words.iter().enumerate() {
                match does_word_match(&qw_lower, dw, allow_prefix) {
                    WordMatchKind::Exact => {
                        return WordMatch {
                            matched: true,
                            edit_dist: 0,
                            doc_word_pos: dpos,
                            is_exact: true,
                            counts_as_match,
                        };
                    }
                    WordMatchKind::Prefix => {
                        if best.as_ref().map_or(true, |b| b.edit_dist > 0) {
                            best = Some(WordMatch {
                                matched: true,
                                edit_dist: 0,
                                doc_word_pos: dpos,
                                is_exact: false,
                                counts_as_match,
                            });
                        }
                    }
                    WordMatchKind::Fuzzy(dist) => {
                        let is_better = best.as_ref().map_or(true, |b| dist < b.edit_dist);
                        if is_better {
                            best = Some(WordMatch {
                                matched: true,
                                edit_dist: dist,
                                doc_word_pos: dpos,
                                is_exact: false,
                                counts_as_match,
                            });
                        }
                    }
                    WordMatchKind::Subsequence(gaps) => {
                        let dist = gaps.saturating_add(1);
                        let is_better = best.as_ref().map_or(true, |b| dist < b.edit_dist);
                        if is_better {
                            best = Some(WordMatch {
                                matched: true,
                                edit_dist: dist,
                                doc_word_pos: dpos,
                                is_exact: false,
                                counts_as_match,
                            });
                        }
                    }
                    WordMatchKind::None => {}
                }
            }

            best.unwrap_or(WordMatch {
                matched: false,
                edit_dist: 0,
                doc_word_pos: 0,
                is_exact: false,
                counts_as_match,
            })
        })
        .collect()
}

/// Result of matching a query word against a document word.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum WordMatchKind {
    None,
    Exact,
    Prefix,
    Fuzzy(u8),
    Subsequence(u8),
}

/// Check if a query word matches a document word using the same criteria
/// as ranking: exact -> prefix (if allowed, >= 2 chars) -> fuzzy (edit distance)
/// -> subsequence (abbreviation). Both inputs must already be lowercased.
pub(crate) fn does_word_match(qw_lower: &str, dw_lower: &str, allow_prefix: bool) -> WordMatchKind {
    if dw_lower == qw_lower {
        return WordMatchKind::Exact;
    }
    if allow_prefix && qw_lower.len() >= 2 && dw_lower.starts_with(qw_lower) {
        return WordMatchKind::Prefix;
    }
    let max_typo = max_edit_distance(qw_lower.chars().count());
    if max_typo > 0 {
        if let Some(dist) = edit_distance_bounded(qw_lower, dw_lower, max_typo) {
            if dist > 0 {
                return WordMatchKind::Fuzzy(dist);
            }
        }
    }
    if let Some(gaps) = subsequence_match(qw_lower, dw_lower) {
        return WordMatchKind::Subsequence(gaps);
    }
    WordMatchKind::None
}

/// Check if all characters in `query` appear in order in `target`.
/// Returns the number of gaps (non-contiguous segments - 1) if matched, None otherwise.
fn subsequence_match(query: &str, target: &str) -> Option<u8> {
    let q_chars: Vec<char> = query.chars().collect();
    let t_chars: Vec<char> = target.chars().collect();

    // Min 3 chars to avoid spurious matches
    if q_chars.len() < 3 {
        return None;
    }
    // Must be shorter than target (equal/longer is exact territory)
    if q_chars.len() >= t_chars.len() {
        return None;
    }
    // Query must cover at least 50% of target length
    if q_chars.len() * 2 < t_chars.len() {
        return None;
    }
    // First character must match (abbreviations preserve the initial letter)
    if q_chars[0] != t_chars[0] {
        return None;
    }

    let mut qi = 0;
    let mut gaps = 0u8;
    let mut prev_matched = false;

    for &tc in &t_chars {
        if qi < q_chars.len() && tc == q_chars[qi] {
            if !prev_matched && qi > 0 {
                gaps = gaps.saturating_add(1);
            }
            qi += 1;
            prev_matched = true;
        } else {
            prev_matched = false;
        }
    }

    if qi == q_chars.len() {
        Some(gaps)
    } else {
        None
    }
}

/// Maximum allowed edit distance based on word length (Milli's graduation).
pub(crate) fn max_edit_distance(word_len: usize) -> u8 {
    if word_len < 5 {
        0
    } else if word_len <= 8 {
        1
    } else {
        2
    }
}

/// Compute proximity score from matched word positions.
fn compute_proximity(word_matches: &[WordMatch]) -> u16 {
    let matched: Vec<&WordMatch> = word_matches.iter().filter(|m| m.matched).collect();
    if matched.len() < 2 {
        return u16::MAX;
    }

    let mut total_distance: u32 = 0;
    let mut prev_matched: Option<usize> = None;

    for wm in word_matches {
        if wm.matched {
            if let Some(prev_pos) = prev_matched {
                let dist = (wm.doc_word_pos as i64 - prev_pos as i64).unsigned_abs() as u32;
                total_distance += dist;
            }
            prev_matched = Some(wm.doc_word_pos);
        }
    }

    u16::MAX.saturating_sub(total_distance.min(u16::MAX as u32) as u16)
}

/// Compute exactness score.
/// 3: Full query appears as exact substring (case-insensitive)
/// 2: All matched words are exact (0 edit distance each)
/// 1: Mix of exact and fuzzy matches
/// 0: All matches are fuzzy/prefix only
fn compute_exactness(content: &str, query_words: &[&str], word_matches: &[WordMatch]) -> u8 {
    let matched: Vec<&WordMatch> = word_matches.iter().filter(|m| m.matched).collect();
    if matched.is_empty() {
        return 0;
    }

    if !query_words.is_empty() {
        let full_query = query_words.join(" ").to_lowercase();
        let content_lower = content.to_lowercase();
        if content_lower.contains(&full_query) {
            return 3;
        }
    }

    let all_exact = matched.iter().all(|m| m.is_exact);
    if all_exact {
        return 2;
    }

    let any_exact = matched.iter().any(|m| m.is_exact);
    if any_exact {
        return 1;
    }

    0
}

/// Damerau-Levenshtein edit distance (optimal string alignment) with threshold pruning.
/// Counts insertions, deletions, substitutions, and adjacent transpositions each as 1 edit.
/// Returns `Some(distance)` if distance <= max_dist, `None` otherwise.
pub fn edit_distance_bounded(a: &str, b: &str, max_dist: u8) -> Option<u8> {
    let a_chars: Vec<char> = a.chars().collect();
    let b_chars: Vec<char> = b.chars().collect();
    let m = a_chars.len();
    let n = b_chars.len();
    let max_d = max_dist as usize;

    if m.abs_diff(n) > max_d {
        return None;
    }

    let mut prev2 = vec![0usize; n + 1];
    let mut prev: Vec<usize> = (0..=n).collect();
    let mut curr = vec![0usize; n + 1];

    for i in 1..=m {
        curr[0] = i;
        let mut row_min = curr[0];

        for j in 1..=n {
            let cost = if a_chars[i - 1] == b_chars[j - 1] { 0 } else { 1 };
            curr[j] = (prev[j] + 1)
                .min(curr[j - 1] + 1)
                .min(prev[j - 1] + cost);

            if i >= 2
                && j >= 2
                && a_chars[i - 1] == b_chars[j - 2]
                && a_chars[i - 2] == b_chars[j - 1]
            {
                curr[j] = curr[j].min(prev2[j - 2] + 1);
            }

            row_min = row_min.min(curr[j]);
        }

        if row_min > max_d {
            return None;
        }

        std::mem::swap(&mut prev2, &mut prev);
        std::mem::swap(&mut prev, &mut curr);
    }

    let result = prev[n];
    if result <= max_d {
        Some(result as u8)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── edit_distance_bounded tests ──────────────────────────────

    #[test]
    fn test_edit_distance_exact() {
        assert_eq!(edit_distance_bounded("hello", "hello", 2), Some(0));
    }

    #[test]
    fn test_edit_distance_one_deletion() {
        assert_eq!(edit_distance_bounded("riversde", "riverside", 1), Some(1));
    }

    #[test]
    fn test_edit_distance_one_substitution() {
        assert_eq!(edit_distance_bounded("hello", "hallo", 1), Some(1));
    }

    #[test]
    fn test_edit_distance_exceeds_threshold() {
        assert_eq!(edit_distance_bounded("hello", "world", 2), None);
    }

    #[test]
    fn test_edit_distance_length_prune() {
        assert_eq!(edit_distance_bounded("hi", "hello!", 2), None);
    }

    #[test]
    fn test_edit_distance_empty_strings() {
        assert_eq!(edit_distance_bounded("", "", 0), Some(0));
        assert_eq!(edit_distance_bounded("ab", "", 2), Some(2));
        assert_eq!(edit_distance_bounded("abc", "", 2), None);
    }

    #[test]
    fn test_edit_distance_two_edits() {
        assert_eq!(edit_distance_bounded("rivrsid", "riverside", 2), Some(2));
    }

    #[test]
    fn test_edit_distance_transposition() {
        // Adjacent swap counts as 1 edit with Damerau-Levenshtein
        assert_eq!(edit_distance_bounded("improt", "import", 1), Some(1));
        assert_eq!(edit_distance_bounded("teh", "the", 1), Some(1));
        assert_eq!(edit_distance_bounded("recieve", "receive", 1), Some(1));
    }

    // ── subsequence_match tests ───────────────────────────────────

    #[test]
    fn test_subsequence_one_skip() {
        // "helo" in "hello": h-e-l match, then extra 'l' breaks contiguity, then o
        assert_eq!(subsequence_match("helo", "hello"), Some(1));
    }

    #[test]
    fn test_subsequence_contiguous() {
        // "hell" in "hello": h-e-l-l all contiguous
        assert_eq!(subsequence_match("hell", "hello"), Some(0));
    }

    #[test]
    fn test_subsequence_with_gaps() {
        // "impt" in "import": i-m-p contiguous, then gap (o,r), then t
        assert_eq!(subsequence_match("impt", "import"), Some(1));
    }

    #[test]
    fn test_subsequence_too_short() {
        assert_eq!(subsequence_match("ab", "abc"), None);
    }

    #[test]
    fn test_subsequence_low_coverage() {
        // 3 chars vs 7 = 43% < 50%
        assert_eq!(subsequence_match("abc", "abcdefg"), None);
    }

    #[test]
    fn test_subsequence_not_found() {
        assert_eq!(subsequence_match("xyz", "hello"), None);
    }

    #[test]
    fn test_subsequence_equal_length() {
        // Same length → should be exact match territory, not subsequence
        assert_eq!(subsequence_match("abc", "abc"), None);
    }

    #[test]
    fn test_subsequence_first_char_must_match() {
        // "url" in "curl" — first chars differ, rejected
        assert_eq!(subsequence_match("url", "curl"), None);
        // "port" in "import" — first chars differ, rejected
        assert_eq!(subsequence_match("port", "import"), None);
    }

    // ── max_edit_distance tests ──────────────────────────────────

    #[test]
    fn test_max_edit_distance_graduation() {
        assert_eq!(max_edit_distance(1), 0);
        assert_eq!(max_edit_distance(4), 0);
        assert_eq!(max_edit_distance(5), 1);
        assert_eq!(max_edit_distance(8), 1);
        assert_eq!(max_edit_distance(9), 2);
        assert_eq!(max_edit_distance(15), 2);
    }

    // ── does_word_match tests ────────────────────────────────────

    #[test]
    fn test_does_word_match_exact() {
        assert_eq!(does_word_match("hello", "hello", false), WordMatchKind::Exact);
    }

    #[test]
    fn test_does_word_match_prefix() {
        assert_eq!(does_word_match("cl", "clipkitty", true), WordMatchKind::Prefix);
        // Not allowed when allow_prefix=false
        assert_eq!(does_word_match("cl", "clipkitty", false), WordMatchKind::None);
        // Single char prefix not allowed (< 2 chars)
        assert_eq!(does_word_match("c", "clipkitty", true), WordMatchKind::None);
    }

    #[test]
    fn test_does_word_match_fuzzy() {
        // "riversde" (8 chars) -> max_dist 1
        assert_eq!(does_word_match("riversde", "riverside", false), WordMatchKind::Fuzzy(1));
        // "improt" (6 chars) -> max_dist 1, transposition counts as 1
        assert_eq!(does_word_match("improt", "import", false), WordMatchKind::Fuzzy(1));
    }

    #[test]
    fn test_does_word_match_subsequence() {
        // "helo" (4 chars) -> fuzzy disabled (max_dist 0), subsequence with 1 gap
        assert_eq!(does_word_match("helo", "hello", false), WordMatchKind::Subsequence(1));
        // "impt" (4 chars) -> abbreviation of "import", 1 gap (imp|t)
        assert_eq!(does_word_match("impt", "import", false), WordMatchKind::Subsequence(1));
        // "cls" (3 chars) -> abbreviation of "class"
        assert_eq!(does_word_match("cls", "class", false), WordMatchKind::Subsequence(1));
        // Too short for subsequence (< 3 chars)
        assert_eq!(does_word_match("ab", "abc", false), WordMatchKind::None);
        // Coverage too low: 3 chars vs 7 char target (43% < 50%)
        assert_eq!(does_word_match("abc", "abcdefg", false), WordMatchKind::None);
        // Fuzzy takes priority over subsequence when both could match
        // "imprt" (5 chars) has edit_distance 1 to "import", so fuzzy wins
        assert_eq!(does_word_match("imprt", "import", false), WordMatchKind::Fuzzy(1));
    }

    // ── match_query_words tests ──────────────────────────────────

    #[test]
    fn test_match_exact() {
        let doc_words = vec!["hello", "world"];
        let matches = match_query_words(&["hello"], &doc_words, false);
        assert_eq!(matches.len(), 1);
        assert!(matches[0].matched);
        assert_eq!(matches[0].edit_dist, 0);
        assert!(matches[0].is_exact);
    }

    #[test]
    fn test_match_prefix_last_word() {
        let doc_words = vec!["clipkitty"];
        let matches = match_query_words(&["cl"], &doc_words, true);
        assert_eq!(matches.len(), 1);
        assert!(matches[0].matched);
        assert_eq!(matches[0].edit_dist, 0);
    }

    #[test]
    fn test_match_prefix_not_allowed_non_last() {
        let doc_words = vec!["clipkitty"];
        let matches = match_query_words(&["cl", "hello"], &doc_words, true);
        assert!(!matches[0].matched);
    }

    #[test]
    fn test_match_fuzzy() {
        let doc_words = vec!["riverside", "park"];
        let matches = match_query_words(&["riversde"], &doc_words, false);
        assert!(matches[0].matched);
        assert_eq!(matches[0].edit_dist, 1);
    }

    #[test]
    fn test_match_subsequence_short_word() {
        // "helo" (4 chars) matches "hello" via subsequence (1 gap), not fuzzy
        let doc_words = vec!["hello"];
        let matches = match_query_words(&["helo"], &doc_words, false);
        assert!(matches[0].matched);
        assert_eq!(matches[0].edit_dist, 2); // gaps(1) + 1
    }

    #[test]
    fn test_match_multi_word() {
        let doc_words = vec!["hello", "beautiful", "world"];
        let matches = match_query_words(&["hello", "world"], &doc_words, false);
        assert!(matches[0].matched);
        assert!(matches[1].matched);
        assert_eq!(matches[0].doc_word_pos, 0);
        assert_eq!(matches[1].doc_word_pos, 2);
    }

    // ── compute_proximity tests ──────────────────────────────────

    #[test]
    fn test_proximity_adjacent() {
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, counts_as_match: true },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 1, is_exact: true, counts_as_match: true },
        ];
        assert_eq!(compute_proximity(&matches), u16::MAX - 1);
    }

    #[test]
    fn test_proximity_gap() {
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, counts_as_match: true },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 5, is_exact: true, counts_as_match: true },
        ];
        assert_eq!(compute_proximity(&matches), u16::MAX - 5);
    }

    #[test]
    fn test_proximity_single_word() {
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 3, is_exact: true, counts_as_match: true },
        ];
        assert_eq!(compute_proximity(&matches), u16::MAX);
    }

    #[test]
    fn test_proximity_unmatched_words_skipped() {
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, counts_as_match: true },
            WordMatch { matched: false, edit_dist: 0, doc_word_pos: 0, is_exact: false, counts_as_match: true },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 3, is_exact: true, counts_as_match: true },
        ];
        assert_eq!(compute_proximity(&matches), u16::MAX - 3);
    }

    // ── compute_exactness tests ──────────────────────────────────

    #[test]
    fn test_exactness_full_substring() {
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, counts_as_match: true },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 1, is_exact: true, counts_as_match: true },
        ];
        assert_eq!(compute_exactness("hello world", &["hello", "world"], &matches), 3);
    }

    #[test]
    fn test_exactness_all_exact_but_not_substring() {
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, counts_as_match: true },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 2, is_exact: true, counts_as_match: true },
        ];
        assert_eq!(compute_exactness("hello beautiful world", &["hello", "world"], &matches), 2);
    }

    #[test]
    fn test_exactness_mix_exact_fuzzy() {
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, counts_as_match: true },
            WordMatch { matched: true, edit_dist: 1, doc_word_pos: 1, is_exact: false, counts_as_match: true },
        ];
        assert_eq!(compute_exactness("hello wrld", &["hello", "world"], &matches), 1);
    }

    #[test]
    fn test_exactness_all_fuzzy() {
        let matches = vec![
            WordMatch { matched: true, edit_dist: 1, doc_word_pos: 0, is_exact: false, counts_as_match: true },
        ];
        assert_eq!(compute_exactness("hallo", &["hello"], &matches), 0);
    }

    // ── recency_tier tests ───────────────────────────────────────

    #[test]
    fn test_recency_tier_last_hour() {
        let now = 1700000000i64;
        assert_eq!(compute_recency_tier(now - 1800, now), 3); // 30 min ago
    }

    #[test]
    fn test_recency_tier_last_day() {
        let now = 1700000000i64;
        assert_eq!(compute_recency_tier(now - 7200, now), 2); // 2 hours ago
    }

    #[test]
    fn test_recency_tier_last_week() {
        let now = 1700000000i64;
        assert_eq!(compute_recency_tier(now - 259200, now), 1); // 3 days ago
    }

    #[test]
    fn test_recency_tier_older() {
        let now = 1700000000i64;
        assert_eq!(compute_recency_tier(now - 864000, now), 0); // 10 days ago
    }

    // ── bucket score ordering tests ──────────────────────────────

    #[test]
    fn test_words_matched_dominates() {
        let now = 1700000000i64;
        let score_3w = compute_bucket_score(
            "hello beautiful world", &["hello", "beautiful", "world"], false, now - 86400, 1.0, now,
        );
        let score_2w = compute_bucket_score(
            "hello world xyz", &["hello", "beautiful", "world"], false, now, 10.0, now,
        );
        assert!(score_3w > score_2w, "3 words matched should beat 2 words");
    }

    #[test]
    fn test_typo_dominates_recency_tier() {
        let now = 1700000000i64;
        // Exact match from 10 days ago vs typo match from now
        let exact_old = compute_bucket_score(
            "riverside park", &["riverside"], false, now - 864000, 1.0, now,
        );
        let typo_new = compute_bucket_score(
            "riversde park", &["riverside"], false, now, 1.0, now,
        );
        assert!(exact_old > typo_new, "Exact match should beat fuzzy even when older");
    }

    #[test]
    fn test_recency_tier_dominates_proximity() {
        let now = 1700000000i64;
        // Same words, same typo, but different recency tiers
        let recent = compute_bucket_score(
            "hello world and other things between", &["hello", "world"], false, now - 1800, 1.0, now,
        );
        let old = compute_bucket_score(
            "hello world", &["hello", "world"], false, now - 864000, 1.0, now,
        );
        // recent is tier 3 (30min ago), old is tier 0 (10 days)
        assert!(recent > old, "Recent tier should dominate proximity when words/typo equal");
    }

    #[test]
    fn test_full_bucket_score_integration() {
        let now = 1700000000i64;
        let score = compute_bucket_score(
            "hello world", &["hello", "world"], false, now, 5.0, now,
        );
        assert_eq!(score.words_matched, 2);
        assert_eq!(score.typo_score, 255);
        assert_eq!(score.recency_tier, 3);
        assert_eq!(score.proximity_score, u16::MAX - 1);
        assert_eq!(score.exactness_score, 3); // "hello world" contains "hello world"
        assert_eq!(score.bm25_quantized, 5);
    }
}
