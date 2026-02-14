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
/// 1. words_matched_weight — sum of len² for each matched query word (IDF proxy)
/// 2. recency_score — smooth exponential decay (255=now, 0=old), no cliff edges
/// 3. typo_score — 255 - total_edit_distance (fewer typos = higher)
/// 4. proximity_score — u16::MAX - sum_of_pair_distances
/// 5. exactness_score — 0-3 level
/// 6. bm25_quantized — BM25 scaled to integer
/// 7. recency — raw unix timestamp (final tiebreaker)
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct BucketScore {
    pub words_matched_weight: u16,
    pub recency_score: u8,
    pub typo_score: u8,
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
    /// Weight toward the `words_matched_weight` bucket score.
    /// Punctuation tokens (like "://", ".") get 0 — they participate in
    /// proximity and highlighting only. Word tokens get len² (IDF proxy).
    match_weight: u16,
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
            words_matched_weight: 0,
            recency_score: compute_recency_score(timestamp, now),
            typo_score: 255,
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

    let words_matched_weight: u16 = word_matches.iter()
        .filter(|m| m.matched)
        .map(|m| m.match_weight)
        .sum();
    let total_edit_dist: u8 = word_matches
        .iter()
        .filter(|m| m.matched)
        .map(|m| m.edit_dist)
        .sum();
    let typo_score = 255u8.saturating_sub(total_edit_dist);

    let proximity_score = compute_proximity(&word_matches);
    let exactness_score = compute_exactness(content, query_words, &word_matches);
    let bm25_quantized = quantize_bm25(bm25_score);
    let recency_score = compute_recency_score(timestamp, now);

    BucketScore {
        words_matched_weight,
        recency_score,
        typo_score,
        proximity_score,
        exactness_score,
        bm25_quantized,
        recency: timestamp,
    }
}

/// Smooth recency score using logarithmic decay, quantized to u8 (0-255).
/// Logarithmic scale distributes resolution across human-meaningful time ranges
/// (minutes, hours, days, weeks) — unlike exponential decay which concentrates
/// resolution around a single half-life.
///
/// Approximate values at notable ages:
///   now       → 255
///   5 min     → 227
///   30 min    → 187
///   1 hour    → 169
///   6 hours   → 119
///   24 hours  →  80
///   7 days    →  25
///   17 days   →   0
fn compute_recency_score(timestamp: i64, now: i64) -> u8 {
    let age_secs = (now - timestamp).max(0) as f64;
    let age_hours = age_secs / 3600.0;
    // k: time scaling — higher values increase sensitivity to small age differences.
    // max_hours: age at which score reaches 0.
    let k: f64 = 20.0;
    let max_hours: f64 = 400.0;
    let denom = (1.0 + k * max_hours).ln();
    let score = 255.0 * (1.0 - (1.0 + k * age_hours).ln() / denom);
    score.round().clamp(0.0, 255.0) as u8
}

/// Quantize BM25 score to u16 for the tiebreaker bucket.
/// Scaled by 100× to preserve decimal precision while fitting in u16.
fn quantize_bm25(score: f32) -> u16 {
    (score * 100.0).max(0.0).min(u16::MAX as f32) as u16
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
            let match_weight = if is_word_token(qw) {
                (qw.len() as u16).saturating_mul(qw.len() as u16)
            } else {
                0
            };

            let mut best: Option<WordMatch> = None;

            for (dpos, dw) in doc_words.iter().enumerate() {
                match does_word_match(&qw_lower, dw, allow_prefix) {
                    WordMatchKind::Exact => {
                        return WordMatch {
                            matched: true,
                            edit_dist: 0,
                            doc_word_pos: dpos,
                            is_exact: true,
                            match_weight,
                        };
                    }
                    WordMatchKind::Prefix => {
                        if best.as_ref().map_or(true, |b| b.edit_dist > 0) {
                            best = Some(WordMatch {
                                matched: true,
                                edit_dist: 0,
                                doc_word_pos: dpos,
                                is_exact: false,
                                match_weight,
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
                                match_weight,
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
                                match_weight,
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
                match_weight,
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
/// 3-4 char words allow 1 edit to catch common transpositions (teh→the, form→from).
pub(crate) fn max_edit_distance(word_len: usize) -> u8 {
    if word_len < 3 {
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
                if wm.doc_word_pos > prev_pos {
                    total_distance += (wm.doc_word_pos - prev_pos) as u32;
                } else {
                    total_distance += (prev_pos - wm.doc_word_pos) as u32 + 5;
                }
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
        assert_eq!(max_edit_distance(2), 0);
        assert_eq!(max_edit_distance(3), 1);
        assert_eq!(max_edit_distance(4), 1);
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
        // Short word transpositions (3-4 chars)
        assert_eq!(does_word_match("teh", "the", false), WordMatchKind::Fuzzy(1));
        assert_eq!(does_word_match("form", "from", false), WordMatchKind::Fuzzy(1));
        assert_eq!(does_word_match("adn", "and", false), WordMatchKind::Fuzzy(1));
        // Short word substitution — also matches (same edit distance)
        assert_eq!(does_word_match("tha", "the", false), WordMatchKind::Fuzzy(1));
        // 2-char words still get no fuzzy
        assert_eq!(does_word_match("te", "the", false), WordMatchKind::None);
    }

    #[test]
    fn test_does_word_match_subsequence() {
        // "helo" (4 chars) -> fuzzy wins: edit_distance("helo","hello")=1
        assert_eq!(does_word_match("helo", "hello", false), WordMatchKind::Fuzzy(1));
        // "impt" (4 chars) -> len diff 2 exceeds max_dist 1, falls to subsequence
        assert_eq!(does_word_match("impt", "import", false), WordMatchKind::Subsequence(1));
        // "cls" (3 chars) -> len diff 2 exceeds max_dist 1, falls to subsequence
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
    fn test_match_fuzzy_short_word() {
        // "helo" (4 chars) matches "hello" via fuzzy (edit distance 1)
        let doc_words = vec!["hello"];
        let matches = match_query_words(&["helo"], &doc_words, false);
        assert!(matches[0].matched);
        assert_eq!(matches[0].edit_dist, 1);
    }

    #[test]
    fn test_match_transposition_short_word() {
        // "teh" (3 chars) matches "the" via fuzzy (transposition = 1 edit)
        let doc_words = vec!["the", "quick"];
        let matches = match_query_words(&["teh"], &doc_words, false);
        assert!(matches[0].matched);
        assert_eq!(matches[0].edit_dist, 1);
        assert!(!matches[0].is_exact);
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
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, match_weight: 25 },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 1, is_exact: true, match_weight: 25 },
        ];
        assert_eq!(compute_proximity(&matches), u16::MAX - 1);
    }

    #[test]
    fn test_proximity_gap() {
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, match_weight: 25 },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 5, is_exact: true, match_weight: 25 },
        ];
        assert_eq!(compute_proximity(&matches), u16::MAX - 5);
    }

    #[test]
    fn test_proximity_single_word() {
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 3, is_exact: true, match_weight: 25 },
        ];
        assert_eq!(compute_proximity(&matches), u16::MAX);
    }

    #[test]
    fn test_proximity_unmatched_words_skipped() {
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, match_weight: 25 },
            WordMatch { matched: false, edit_dist: 0, doc_word_pos: 0, is_exact: false, match_weight: 25 },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 3, is_exact: true, match_weight: 25 },
        ];
        assert_eq!(compute_proximity(&matches), u16::MAX - 3);
    }

    // ── compute_exactness tests ──────────────────────────────────

    #[test]
    fn test_exactness_full_substring() {
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, match_weight: 25 },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 1, is_exact: true, match_weight: 25 },
        ];
        assert_eq!(compute_exactness("hello world", &["hello", "world"], &matches), 3);
    }

    #[test]
    fn test_exactness_all_exact_but_not_substring() {
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, match_weight: 25 },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 2, is_exact: true, match_weight: 25 },
        ];
        assert_eq!(compute_exactness("hello beautiful world", &["hello", "world"], &matches), 2);
    }

    #[test]
    fn test_exactness_mix_exact_fuzzy() {
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, match_weight: 25 },
            WordMatch { matched: true, edit_dist: 1, doc_word_pos: 1, is_exact: false, match_weight: 25 },
        ];
        assert_eq!(compute_exactness("hello wrld", &["hello", "world"], &matches), 1);
    }

    #[test]
    fn test_exactness_all_fuzzy() {
        let matches = vec![
            WordMatch { matched: true, edit_dist: 1, doc_word_pos: 0, is_exact: false, match_weight: 25 },
        ];
        assert_eq!(compute_exactness("hallo", &["hello"], &matches), 0);
    }

    // ── recency_score tests ───────────────────────────────────────

    #[test]
    fn test_recency_score_now() {
        let now = 1700000000i64;
        assert_eq!(compute_recency_score(now, now), 255);
    }

    #[test]
    fn test_recency_score_at_old_tier_boundaries() {
        let now = 1700000000i64;
        let at_1h = compute_recency_score(now - 3600, now);
        let at_24h = compute_recency_score(now - 86400, now);
        let at_7d = compute_recency_score(now - 604800, now);

        assert!((160..=180).contains(&(at_1h as u16)), "1h: expected ~169, got {}", at_1h);
        assert!((70..=90).contains(&(at_24h as u16)), "24h: expected ~80, got {}", at_24h);
        assert!((15..=35).contains(&(at_7d as u16)), "7d: expected ~25, got {}", at_7d);
        // 24h-7d gap should be clearly larger than 7d score itself
        assert!(at_24h - at_7d > at_7d, "24h-7d gap ({}) should exceed 7d score ({})", at_24h - at_7d, at_7d);
    }

    #[test]
    fn test_recency_score_very_old() {
        let now = 1700000000i64;
        let seventeen_days = 17 * 86400;
        assert_eq!(compute_recency_score(now - seventeen_days, now), 0);
    }

    #[test]
    fn test_recency_score_monotonically_decreasing() {
        let now = 1700000000i64;
        let mut prev = 255u8;
        for minutes in 1..=50000 {
            let score = compute_recency_score(now - minutes * 60, now);
            assert!(score <= prev, "score should decrease: {} > {} at {}min", score, prev, minutes);
            prev = score;
        }
    }

    #[test]
    fn test_recency_score_differentiates_within_first_hour() {
        let now = 1700000000i64;
        // Items 5 min, 15 min, 30 min, 55 min apart should all have distinct scores
        let at_5m = compute_recency_score(now - 300, now);
        let at_15m = compute_recency_score(now - 900, now);
        let at_30m = compute_recency_score(now - 1800, now);
        let at_55m = compute_recency_score(now - 3300, now);
        assert!(at_5m > at_15m, "5min ({}) should beat 15min ({})", at_5m, at_15m);
        assert!(at_15m > at_30m, "15min ({}) should beat 30min ({})", at_15m, at_30m);
        assert!(at_30m > at_55m, "30min ({}) should beat 55min ({})", at_30m, at_55m);
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
    fn test_recency_dominates_typo() {
        let now = 1700000000i64;
        // Typo match from now vs exact match from 10 days ago
        let typo_new = compute_bucket_score(
            "riversde park", &["riverside"], false, now, 1.0, now,
        );
        let exact_old = compute_bucket_score(
            "riverside park", &["riverside"], false, now - 864000, 1.0, now,
        );
        assert!(typo_new > exact_old, "Recent fuzzy match should beat old exact match");
    }

    #[test]
    fn test_typo_dominates_within_same_recency() {
        let now = 1700000000i64;
        // Both items from the same time — typo should break the tie
        let exact = compute_bucket_score(
            "riverside park", &["riverside"], false, now - 3600, 1.0, now,
        );
        let typo = compute_bucket_score(
            "riversde park", &["riverside"], false, now - 3600, 1.0, now,
        );
        assert!(exact > typo, "Exact match should beat fuzzy at equal recency");
    }

    #[test]
    fn test_recency_dominates_proximity() {
        let now = 1700000000i64;
        // Same words, same typo, but different recency
        let recent = compute_bucket_score(
            "hello world and other things between", &["hello", "world"], false, now - 1800, 1.0, now,
        );
        let old = compute_bucket_score(
            "hello world", &["hello", "world"], false, now - 864000, 1.0, now,
        );
        assert!(recent > old, "Recent item should dominate proximity when words/typo equal");
    }

    #[test]
    fn test_proximity_inversion_penalty() {
        // Forward order: distance = 2 - 0 = 2
        let forward = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, match_weight: 25 },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 2, is_exact: true, match_weight: 25 },
        ];
        // Reverse order: distance = (0 - 2) + 5 penalty = 7
        let reversed = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 2, is_exact: true, match_weight: 25 },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, match_weight: 25 },
        ];
        assert_eq!(compute_proximity(&forward), u16::MAX - 2);
        assert_eq!(compute_proximity(&reversed), u16::MAX - 7);
        assert!(compute_proximity(&forward) > compute_proximity(&reversed),
            "Forward order should score higher than reversed");
    }

    #[test]
    fn test_full_bucket_score_integration() {
        let now = 1700000000i64;
        let score = compute_bucket_score(
            "hello world", &["hello", "world"], false, now, 5.0, now,
        );
        assert_eq!(score.words_matched_weight, 50); // 5² + 5² = 50
        assert_eq!(score.recency_score, 255); // just now
        assert_eq!(score.typo_score, 255);
        assert_eq!(score.proximity_score, u16::MAX - 1);
        assert_eq!(score.exactness_score, 3); // "hello world" contains "hello world"
        assert_eq!(score.bm25_quantized, 500); // 5.0 * 100
    }
}
