//! Milli-style bucket ranking for search results.
//!
//! Implements a lexicographic tuple where higher-priority signals always dominate
//! lower ones. 3/3 words ALWAYS beats 2/3, 0 typos ALWAYS beats 1 typo, etc.
//! Intent tier sits above recency to strongly prefer structural matches
//! (anchored, contiguous) over scattered matches regardless of recency.

/// Bucket score tuple — derived Ord gives lexicographic comparison.
/// All components: higher = better.
///
/// Tuple order (most to least important):
/// 1. words_matched_weight — sum of len² for each matched query word (IDF proxy)
/// 2. intent_tier — 4-tier structural intent (prefix/anchored/contiguous/forward)
/// 3. density_score — ratio of matched query chars to doc length (0-255)
/// 4. recency_score — smooth exponential decay (255=now, 0=old), no cliff edges
/// 5. proximity_score — u16::MAX - sum_of_pair_distances
/// 6. typo_score — 255 - total_edit_distance (fewer typos = higher)
/// 7. bm25_quantized — BM25 scaled to integer
/// 8. recency — raw unix timestamp (final tiebreaker)
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct BucketScore {
    pub words_matched_weight: u16,
    pub intent_tier: u8,
    pub density_score: u8,
    pub recency_score: u8,
    pub proximity_score: u16,
    pub typo_score: u8,
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
    /// All tokens (including punctuation) get len² weight. Punctuation tokens
    /// are short (weight 1-4), so they differentiate matches without dominating.
    match_weight: u16,
}

/// Compute the bucket score for a candidate document.
///
/// `content_lower` and `doc_word_strs` should be pre-computed from the candidate's
/// content to avoid redundant work when the same tokens are needed for highlighting.
pub fn compute_bucket_score(
    content_lower: &str,
    doc_word_strs: &[&str],
    query_words: &[&str],
    last_word_is_prefix: bool,
    timestamp: i64,
    bm25_score: f32,
    now: i64,
) -> BucketScore {
    if query_words.is_empty() {
        return BucketScore {
            words_matched_weight: 0,
            intent_tier: 1,
            density_score: 0,
            recency_score: compute_recency_score(timestamp, now),
            proximity_score: u16::MAX,
            typo_score: 255,
            bm25_quantized: quantize_bm25(bm25_score),
            recency: timestamp,
        };
    }

    let word_matches = match_query_words(query_words, doc_word_strs, last_word_is_prefix);

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

    let matched_word_lengths: Vec<usize> = word_matches.iter()
        .zip(query_words.iter())
        .filter(|(m, _)| m.matched)
        .map(|(_, qw)| qw.chars().count())
        .collect();

    let density_score = compute_density_score(&matched_word_lengths, content_lower.chars().count());
    let proximity_score = compute_proximity(&word_matches);
    let intent_tier = compute_intent_tier(content_lower, query_words, &word_matches);
    let bm25_quantized = quantize_bm25(bm25_score);
    let recency_score = compute_recency_score(timestamp, now);

    BucketScore {
        words_matched_weight,
        intent_tier,
        density_score,
        recency_score,
        proximity_score,
        typo_score,
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

/// Compute density score: ratio of matched query chars to document length.
/// Higher density = shorter, more focused document where the query represents
/// a larger fraction of the content.
fn compute_density_score(
    matched_word_lengths: &[usize], // char lengths of matched query words
    doc_char_len: usize,
) -> u8 {
    if doc_char_len == 0 {
        return 255;
    }
    let matched_chars: usize = matched_word_lengths.iter().sum();
    let ratio = matched_chars as f64 / doc_char_len as f64;
    (ratio * 255.0).round().clamp(0.0, 255.0) as u8
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
            let match_weight = (qw.len() as u16).saturating_mul(qw.len() as u16);

            // Try acronym match first (before per-word matching)
            for start_pos in 0..doc_words.len() {
                if let Some(_words_consumed) = try_acronym_match(&qw_lower, doc_words, start_pos) {
                    return WordMatch {
                        matched: true,
                        edit_dist: 0,
                        doc_word_pos: start_pos,
                        is_exact: false,
                        match_weight, // full weight for acronyms
                    };
                }
            }

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
                            // Fuzzy matches get full weight for words_matched_weight.
                            // The typo penalty is captured in edit_dist → typo_score.
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
                            // Subsequence matches get full weight for words_matched_weight.
                            // The gap penalty is captured in edit_dist → typo_score.
                            best = Some(WordMatch {
                                matched: true,
                                edit_dist: dist,
                                doc_word_pos: dpos,
                                is_exact: false,
                                match_weight,
                            });
                        }
                    }
                    WordMatchKind::Acronym => {
                        // Acronym matching is handled at the multi-word level above,
                        // so this case is unreachable in the per-word loop
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
    Acronym,  // NEW: query matches first letters of consecutive doc words
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

/// Try to match a query word as an acronym of consecutive document words.
/// Returns the number of document words consumed if matched, None otherwise.
///
/// Example: "lgtm" matches "looks good to me" (4 consecutive words).
///
/// Guards against false positives:
/// - Minimum query length: 3 characters
/// - Each query char must match first char of consecutive doc word
/// - Only alphanumeric doc words count (skip punctuation)
fn try_acronym_match(qw: &str, doc_words: &[&str], start: usize) -> Option<usize> {
    let q_chars: Vec<char> = qw.chars().collect();
    if q_chars.len() < 3 {
        return None; // min 3 chars to avoid noise
    }

    let mut qi = 0;
    let mut doc_idx = start;

    while qi < q_chars.len() && doc_idx < doc_words.len() {
        let dw = doc_words[doc_idx];
        // Skip punctuation tokens (only match against word tokens)
        if !dw.starts_with(|c: char| c.is_alphanumeric()) {
            doc_idx += 1;
            continue;
        }

        // Check if first char of doc word matches query char (case-insensitive)
        let dw_first = dw.chars().next()?;
        if dw_first.to_lowercase().next()? != q_chars[qi].to_lowercase().next()? {
            return None; // Mismatch - no gaps allowed
        }

        qi += 1;
        doc_idx += 1;
    }

    if qi == q_chars.len() {
        Some(doc_idx - start) // Number of doc words consumed
    } else {
        None
    }
}

/// Check if all characters in `query` appear in order in `target`.
/// Returns the number of gaps (non-contiguous segments - 1) if matched, None otherwise.
fn subsequence_match(query: &str, target: &str) -> Option<u8> {
    let q_chars: Vec<char> = query.chars().collect();
    let t_chars: Vec<char> = target.chars().collect();

    // Min 4 chars to avoid spurious matches (<=3 too short for meaningful subsequence)
    if q_chars.len() <= 3 {
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
/// 1-2 char words get no fuzzy tolerance. 3+ chars allow 1 edit (catches transpositions).
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

/// Compute intent tier (1-4 scale, higher = stronger intent).
/// Evaluated top-down, first match wins:
///
/// Tier 4: Content starts with query (prefix), OR first word anchored + forward sequence
/// Tier 3: Full query is contiguous substring anywhere (but not Tier 4)
/// Tier 2: All words in forward order, each with edit distance ≤ 1
/// Tier 1: Everything else (reversed, heavy fuzzy, scattered)
fn compute_intent_tier(content_lower: &str, query_words: &[&str], word_matches: &[WordMatch]) -> u8 {
    let matched: Vec<&WordMatch> = word_matches.iter().filter(|m| m.matched).collect();
    if matched.is_empty() {
        return 1;
    }

    let full_query = if !query_words.is_empty() {
        query_words.join(" ").to_lowercase()
    } else {
        String::new()
    };

    // Tier 4: Content starts with query (prefix match)
    if !full_query.is_empty() && content_lower.starts_with(&full_query) {
        return 4;
    }

    // Tier 4: First word anchored at doc start + all words in forward sequence
    let all_matched = word_matches.iter().all(|m| m.matched);
    if all_matched && !word_matches.is_empty() {
        let first = &word_matches[0];
        if first.doc_word_pos == 0 && first.edit_dist == 0 {
            let in_forward_sequence = word_matches.windows(2)
                .all(|w| w[1].doc_word_pos > w[0].doc_word_pos);
            if in_forward_sequence {
                return 4;
            }
        }
    }

    // Tier 3: Full query appears as contiguous substring anywhere
    if !full_query.is_empty() && content_lower.contains(&full_query) {
        return 3;
    }

    // Tier 2: All words in forward order, each with edit distance ≤ 1
    // Check forward order AND edit distance
    if all_matched && !word_matches.is_empty() {
        let in_forward_order = word_matches.windows(2)
            .all(|w| w[1].doc_word_pos > w[0].doc_word_pos);
        let all_edit_dist_ok = matched.iter().all(|m| m.edit_dist <= 1);

        if in_forward_order && all_edit_dist_ok {
            return 2;
        }
    }

    // Tier 1: Everything else (reversed, scattered, heavy fuzzy)
    1
}

/// Damerau-Levenshtein edit distance (optimal string alignment) with threshold pruning.
/// Counts insertions, deletions, substitutions, and adjacent transpositions each as 1 edit.
/// Returns `Some(distance)` if distance <= max_dist, `None` otherwise.
///
/// Applies the "first-character rule": ~98% of real typos preserve the first letter,
/// so a first-character mismatch incurs an extra +1 penalty. This prevents false
/// positives like "cat"→"bat" (distance 1 + penalty 1 = 2, exceeds max_dist=1).
/// Exception: transpositions of the first two characters (e.g., "hte"→"the") are
/// exempt since they're common fast-typing errors.
pub fn edit_distance_bounded(a: &str, b: &str, max_dist: u8) -> Option<u8> {
    let a_chars: Vec<char> = a.chars().collect();
    let b_chars: Vec<char> = b.chars().collect();
    let m = a_chars.len();
    let n = b_chars.len();
    let max_d = max_dist as usize;

    if m == 0 || n == 0 {
        let dist = m.max(n);
        return if dist <= max_d { Some(dist as u8) } else { None };
    }

    // First-character penalty: mismatch on position 0 costs +1 edit.
    // Exception: first-two-char transposition ("hte"→"the") is a common fast-typing error.
    let is_first_char_transposed = m >= 2
        && n >= 2
        && a_chars[0] == b_chars[1]
        && a_chars[1] == b_chars[0];
    let first_char_penalty =
        if a_chars[0] != b_chars[0] && !is_first_char_transposed { 1 } else { 0 };

    if m.abs_diff(n) + first_char_penalty > max_d {
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

        if row_min + first_char_penalty > max_d {
            return None;
        }

        std::mem::swap(&mut prev2, &mut prev);
        std::mem::swap(&mut prev, &mut curr);
    }

    let result = prev[n] + first_char_penalty;
    if result <= max_d {
        Some(result as u8)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: compute bucket score from raw content (handles lowercasing/tokenization).
    fn score(content: &str, query_words: &[&str], last_word_is_prefix: bool, timestamp: i64, bm25: f32, now: i64) -> BucketScore {
        use crate::search::tokenize_words;
        let content_lower = content.to_lowercase();
        let doc_words = tokenize_words(&content_lower);
        let doc_word_strs: Vec<&str> = doc_words.iter().map(|(_, _, w): &(usize, usize, String)| w.as_str()).collect();
        compute_bucket_score(&content_lower, &doc_word_strs, query_words, last_word_is_prefix, timestamp, bm25, now)
    }

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

    #[test]
    fn test_edit_distance_first_char_penalty() {
        // First-char mismatch adds +1 penalty: "cat"→"bat" = DL 1 + penalty 1 = 2
        assert_eq!(edit_distance_bounded("cat", "bat", 1), None);
        assert_eq!(edit_distance_bounded("cat", "bat", 2), Some(2));
        // Interior typo with same first char: "cat"→"cot" = DL 1, no penalty
        assert_eq!(edit_distance_bounded("cat", "cot", 1), Some(1));
    }

    #[test]
    fn test_edit_distance_first_char_transposition_exempt() {
        // First-two-char transposition is exempt from penalty: "hte"→"the"
        assert_eq!(edit_distance_bounded("hte", "the", 1), Some(1));
        // But non-transposition first-char mismatch is penalized: "bhe"→"the"
        assert_eq!(edit_distance_bounded("bhe", "the", 1), None);
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
        // 3 chars also too short now
        assert_eq!(subsequence_match("abc", "abdc"), None);
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
        // First-char mismatch penalty prevents false positives
        assert_eq!(does_word_match("bat", "cat", false), WordMatchKind::None);
        assert_eq!(does_word_match("rat", "cat", false), WordMatchKind::None);
        // 2-char words still get no fuzzy
        assert_eq!(does_word_match("te", "the", false), WordMatchKind::None);
    }

    #[test]
    fn test_does_word_match_subsequence() {
        // "helo" (4 chars) -> fuzzy wins: edit_distance("helo","hello")=1
        assert_eq!(does_word_match("helo", "hello", false), WordMatchKind::Fuzzy(1));
        // "impt" (4 chars) -> len diff 2 exceeds max_dist 1, falls to subsequence
        assert_eq!(does_word_match("impt", "import", false), WordMatchKind::Subsequence(1));
        // "cls" (3 chars) -> too short for both fuzzy and subsequence now
        assert_eq!(does_word_match("cls", "class", false), WordMatchKind::None);
        // Too short for subsequence (<= 3 chars)
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

    // ── compute_intent_tier tests ────────────────────────────────

    #[test]
    fn test_intent_tier_prefix_of_content() {
        // "hello world" starts with "hello world" → Tier 4
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, match_weight: 25 },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 1, is_exact: true, match_weight: 25 },
        ];
        assert_eq!(compute_intent_tier("hello world", &["hello", "world"], &matches), 4);
    }

    #[test]
    fn test_intent_tier_anchored_forward_sequence() {
        // first word at pos 0, forward sequence → Tier 4
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, match_weight: 25 },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 2, is_exact: true, match_weight: 25 },
        ];
        assert_eq!(compute_intent_tier("hello beautiful world", &["hello", "world"], &matches), 4);
    }

    #[test]
    fn test_intent_tier_anchored_with_typo() {
        // first word at pos 0 exact, second fuzzy (edit_dist 1) in forward sequence → Tier 4
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, match_weight: 25 },
            WordMatch { matched: true, edit_dist: 1, doc_word_pos: 1, is_exact: false, match_weight: 25 },
        ];
        assert_eq!(compute_intent_tier("hello wrld", &["hello", "world"], &matches), 4);
    }

    #[test]
    fn test_intent_tier_anchored_prefix_sequence() {
        // Multi-word query matches as prefix (edit_dist 0, is_exact false).
        // First word at pos 0 with edit_dist 0, forward sequence → Tier 4 (anchored)
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: false, match_weight: 25 },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 1, is_exact: false, match_weight: 25 },
        ];
        assert_eq!(compute_intent_tier("hello world", &["hel", "wor"], &matches), 4);
    }

    #[test]
    fn test_intent_tier_anchored_beats_scattered() {
        // Anchored (Tier 4) should rank above scattered (Tier 2 or Tier 1)
        let anchored = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: false, match_weight: 25 },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 1, is_exact: false, match_weight: 25 },
        ];
        let scattered = vec![
            WordMatch { matched: true, edit_dist: 1, doc_word_pos: 0, is_exact: false, match_weight: 25 },
        ];
        assert!(
            compute_intent_tier("hello world", &["hel", "wor"], &anchored)
            > compute_intent_tier("hallo", &["hello"], &scattered)
        );
    }

    #[test]
    fn test_intent_tier_forward_order_with_typo() {
        // Single word with edit_dist 1 in forward order → Tier 2
        let matches = vec![
            WordMatch { matched: true, edit_dist: 1, doc_word_pos: 0, is_exact: false, match_weight: 25 },
        ];
        assert_eq!(compute_intent_tier("hallo", &["hello"], &matches), 2);
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
        let score_3w = score(
            "hello beautiful world", &["hello", "beautiful", "world"], false, now - 86400, 1.0, now,
        );
        let score_2w = score(
            "hello world xyz", &["hello", "beautiful", "world"], false, now, 10.0, now,
        );
        assert!(score_3w > score_2w, "3 words matched should beat 2 words");
    }

    #[test]
    fn test_intent_dominates_recency_for_typo() {
        let now = 1700000000i64;
        // V2: intent_tier dominates recency. Exact match (higher tier) beats fuzzy.
        let typo_new = score(
            "riversde park", &["riverside"], false, now, 1.0, now,
        );
        let exact_old = score(
            "riverside park", &["riverside"], false, now - 864000, 1.0, now,
        );
        assert!(exact_old > typo_new, "Exact match beats fuzzy despite recency (intent > recency)");
    }

    #[test]
    fn test_typo_dominates_within_same_recency() {
        let now = 1700000000i64;
        // Both items from the same time — typo should break the tie
        let exact = score(
            "riverside park", &["riverside"], false, now - 3600, 1.0, now,
        );
        let typo = score(
            "riversde park", &["riverside"], false, now - 3600, 1.0, now,
        );
        assert!(exact > typo, "Exact match should beat fuzzy at equal recency");
    }

    #[test]
    fn test_density_dominates_recency() {
        let now = 1700000000i64;
        // V2: density_score dominates recency. Short focused doc beats long diluted doc.
        let diluted_recent = score(
            "hello world and other things between", &["hello", "world"], false, now - 1800, 1.0, now,
        );
        let dense_old = score(
            "hello world", &["hello", "world"], false, now - 864000, 1.0, now,
        );
        assert!(dense_old > diluted_recent, "Dense doc beats diluted despite recency (density > recency)");
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
        let s = score(
            "hello world", &["hello", "world"], false, now, 5.0, now,
        );
        assert_eq!(s.words_matched_weight, 50); // 5² + 5² = 50
        assert_eq!(s.intent_tier, 4); // "hello world" starts with "hello world" → Tier 4
        assert_eq!(s.density_score, 232); // 10 matched chars / 11 total chars = 0.909 → 232
        assert_eq!(s.recency_score, 255); // just now
        assert_eq!(s.proximity_score, u16::MAX - 1);
        assert_eq!(s.typo_score, 255);
        assert_eq!(s.bm25_quantized, 500); // 5.0 * 100
    }

    // ── additional intent tier tests ─────────────────────────────

    #[test]
    fn test_intent_tier_content_prefix_multi_word() {
        // "hello wo" is a prefix of "hello world foo" → Tier 4
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, match_weight: 25 },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 1, is_exact: false, match_weight: 25 },
        ];
        assert_eq!(compute_intent_tier("hello world foo", &["hello", "wo"], &matches), 4);
    }

    #[test]
    fn test_intent_tier_content_prefix_single_word() {
        // "hel" is a prefix of "hello world" → Tier 4
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: false, match_weight: 25 },
        ];
        assert_eq!(compute_intent_tier("hello world", &["hel"], &matches), 4);
    }

    #[test]
    fn test_intent_tier_anchored_sequence_with_typo() {
        // first word exact at pos 0, second fuzzy at pos 1 → Tier 4
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, match_weight: 25 },
            WordMatch { matched: true, edit_dist: 1, doc_word_pos: 1, is_exact: false, match_weight: 25 },
        ];
        assert_eq!(compute_intent_tier("hello wrold foo", &["hello", "world"], &matches), 4);
    }

    #[test]
    fn test_intent_tier_not_anchored_but_substring() {
        // first word matches but not at pos 0, but query is substring → Tier 3
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 1, is_exact: true, match_weight: 25 },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 2, is_exact: true, match_weight: 25 },
        ];
        // "hello world" IS a substring of "say hello world"
        assert_eq!(compute_intent_tier("say hello world", &["hello", "world"], &matches), 3);
    }

    #[test]
    fn test_intent_tier_wrong_order() {
        // first word at pos 0 but words out of order → Tier 1 (not in forward sequence)
        let matches = vec![
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 0, is_exact: true, match_weight: 25 },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 2, is_exact: true, match_weight: 25 },
            WordMatch { matched: true, edit_dist: 0, doc_word_pos: 1, is_exact: true, match_weight: 25 },
        ];
        // words go 0, 2, 1 — not strictly forward, and "hello beautiful world" is not a substring
        assert_eq!(compute_intent_tier("hello world beautiful", &["hello", "beautiful", "world"], &matches), 1);
    }

    // ── ranking v2: desired outcomes (currently failing) ─────────
    //
    // These tests document ranking losses in the current algorithm.
    // Each asserts the DESIRED outcome. Remove #[ignore] as fixes land.
    //
    // Cases 2, 3, 6, 10, 16 from the proposal already pass and are omitted.

    // Category A: Structural Intent vs Recency

    #[test]
    fn test_v2_case1_anchored_docker_run_beats_buried() {
        let now = 1700000000i64;
        let anchored = score("docker run -d nginx", &["docker", "run"], false, now - 86400, 1.0, now);
        let buried = score("failed at docker run step", &["docker", "run"], false, now - 600, 1.0, now);
        assert!(anchored > buried, "Anchored 'docker run' (1d old) should beat buried match (10m old)");
    }

    #[test]
    fn test_v2_case4_anchored_git_status_beats_scattered() {
        let now = 1700000000i64;
        let anchored = score("git status", &["git", "status"], false, now - 3600, 1.0, now);
        // 30m old — enough recency gap to overcome proximity under current ordering
        let scattered = score("status of the git migration", &["git", "status"], false, now - 1800, 1.0, now);
        assert!(anchored > scattered, "Anchored 'git status' should beat reversed scattered match");
    }

    #[test]
    fn test_v2_case5_anchored_meeting_notes_beats_reversed() {
        let now = 1700000000i64;
        let anchored = score("Meeting Notes: Proj X", &["meeting", "notes"], false, now - 86400, 1.0, now);
        let reversed = score("notes from the meeting", &["meeting", "notes"], false, now - 1800, 1.0, now);
        assert!(anchored > reversed, "Anchored 'Meeting Notes' (1d old) should beat reversed (30m old)");
    }

    // Category B: Phrase Quality vs Recency

    #[test]
    fn test_v2_case7_contiguous_git_push_beats_scattered() {
        let now = 1700000000i64;
        let contiguous = score("git push origin main", &["git", "push"], false, now - 7200, 1.0, now);
        let scattered = score("git is failing to push changes", &["git", "push"], false, now - 300, 1.0, now);
        assert!(contiguous > scattered, "Contiguous 'git push' (2h old) should beat scattered (5m old)");
    }

    #[test]
    fn test_v2_case8_contiguous_phrase_beats_gapped() {
        let now = 1700000000i64;
        // A: "react spring" contiguous at start → exactness 6
        let contiguous = score("react spring config", &["react", "spring"], false, now - 10800, 1.0, now);
        // B: "react" at start, "spring" far away → exactness 5
        let gapped = score(
            "react component with many features including spring",
            &["react", "spring"], false, now - 600, 1.0, now,
        );
        assert!(contiguous > gapped, "Contiguous 'react spring' (3h old) should beat gapped (10m old)");
    }

    #[test]
    fn test_v2_case9_ip_with_dots_beats_spaces() {
        let now = 1700000000i64;
        // Both have same numeric tokens, but A also matches the dots
        let with_dots = score(
            "192.168.1.1", &["192", ".", "168", ".", "1", ".", "1"],
            false, now - 3600, 1.0, now,
        );
        let without_dots = score(
            "192 168 1 1", &["192", ".", "168", ".", "1", ".", "1"],
            false, now - 300, 1.0, now,
        );
        assert!(with_dots > without_dots, "IP '192.168.1.1' with dots should beat '192 168 1 1'");
    }

    // Category C: Tie-Breaking Hierarchy

    #[test]
    fn test_v2_case11_forward_order_beats_perfect_spelling() {
        let now = 1700000000i64;
        // A: forward order, minor typo — "git statuss"
        let forward_typo = score("git statuss", &["git", "status"], false, now - 3600, 1.0, now);
        // B: reversed order, no typos — "status git"
        let reversed_exact = score("status git", &["git", "status"], false, now - 3600, 1.0, now);
        assert!(forward_typo > reversed_exact,
            "Forward 'git statuss' (typo) should beat reversed 'status git' (exact)");
    }

    #[test]
    fn test_v2_case12_anchored_beats_closer_proximity() {
        let now = 1700000000i64;
        // A: anchored at start, wider gap (distance 3)
        let anchored = score("npm --global install", &["npm", "install"], false, now - 3600, 1.0, now);
        // B: not anchored, tighter gap (distance 1)
        let closer = score("error: npm install failed", &["npm", "install"], false, now - 3600, 1.0, now);
        assert!(anchored > closer, "Anchored 'npm' at start should beat closer but buried match");
    }

    #[test]
    fn test_v2_case13_dense_doc_beats_diluted() {
        let now = 1700000000i64;
        // A: short focused doc — "password" is >50% of content
        let dense = score("my password", &["password"], false, now - 7200, 10.0, now);
        // B: long doc where "password" is <5% of content
        let diluted = score(
            "this is a very long document that contains many words and paragraphs \
             of text discussing various topics including security and the word \
             password appears somewhere in this enormous body of text among \
             hundreds of other words that dilute its significance considerably",
            &["password"], false, now - 300, 0.5, now,
        );
        assert!(dense > diluted, "Dense short doc should beat diluted long doc despite recency");
    }

    #[test]
    fn test_v2_case14_exact_beats_typo_close_recency() {
        let now = 1700000000i64;
        // 19 minutes apart — recency scores ~117 vs ~119 (2 points in u8)
        let exact = score("localhost", &["localhost"], false, now - 22800, 1.0, now); // 6h20m
        let typo = score("localhast", &["localhost"], false, now - 21660, 1.0, now); // 6h1m
        assert!(exact > typo,
            "Exact 'localhost' should beat typo 'localhast' despite 19min recency gap");
    }

    // Category D: Matching Pipeline Gaps

    #[test]
    fn test_try_acronym_match_basic() {
        let doc_words = vec!["looks", "good", "to", "me"];
        assert_eq!(try_acronym_match("lgtm", &doc_words, 0), Some(4));
    }

    #[test]
    fn test_try_acronym_match_too_short() {
        let doc_words = vec!["as", "soon"];
        // Only 2 chars, should fail
        assert_eq!(try_acronym_match("as", &doc_words, 0), None);
    }

    #[test]
    fn test_try_acronym_match_with_punctuation() {
        let doc_words = vec!["looks", ".", "good", "to", "me"];
        // Should skip the punctuation "."
        assert_eq!(try_acronym_match("lgtm", &doc_words, 0), Some(5));
    }

    #[test]
    fn test_try_acronym_match_case_insensitive() {
        let doc_words = vec!["looks", "good", "to", "me"];
        assert_eq!(try_acronym_match("LGTM", &doc_words, 0), Some(4));
    }

    #[test]
    fn test_try_acronym_match_partial_fail() {
        let doc_words = vec!["looks", "good", "time"];
        // "lgtm" should fail because "time" doesn't start with "m"
        assert_eq!(try_acronym_match("lgtm", &doc_words, 0), None);
    }

    #[test]
    fn test_v2_case15_acronym_match() {
        let now = 1700000000i64;
        let acronym = score("looks good to me", &["lgtm"], true, now - 18000, 1.0, now);
        assert!(acronym.words_matched_weight > 0,
            "'lgtm' should match 'looks good to me' via first-letter acronym");
    }
}
