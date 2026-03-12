//! Milli-style bucket ranking for search results.
//!
//! Implements a lexicographic tuple with a coarse quality / recency / quality-detail
//! "sandwich". Only foundational quality differences outrank recency; finer coverage
//! and phrase-quality differences break ties after recency.

use crate::search::is_word_token;
use std::collections::HashSet;

/// Documents larger than this threshold use fast matching (exact + prefix only).
/// This trades typo tolerance for performance on large documents like code files.
pub const LARGE_DOC_THRESHOLD_BYTES: usize = 5 * 1024; // 5KB

/// Bucket score tuple — derived Ord gives lexicographic comparison.
/// All components: higher = better.
///
/// Tuple order (most to least important):
/// 1. quality_tier — extremely coarse foundational match quality
/// 2. recency_score — smooth logarithmic decay (255=now, 0=old)
/// 3. quality_detail — nuanced coverage/structure/typo detail within a tier
/// 4. bm25_quantized — BM25 scaled to integer
/// 5. recency — raw unix timestamp (final tiebreaker)
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct BucketScore {
    pub quality_tier: u8,
    pub recency_score: u8,
    pub quality_detail: u64,
    pub bm25_quantized: u16,
    pub recency: i64,
}

const QUALITY_DETAIL_PREFIX_SHIFT: u64 = 56;
const QUALITY_DETAIL_COVERAGE_SHIFT: u64 = 40;
const QUALITY_DETAIL_STRUCTURE_SHIFT: u64 = 8;

impl BucketScore {
    pub fn words_matched_weight(&self) -> u16 {
        quality_detail_words_matched_weight(self.quality_detail)
    }
}

#[derive(Debug, Clone, Copy)]
pub struct PrefixPreferenceQuery<'a> {
    pub raw_query_lower: &'a str,
    pub stripped_query_lower: &'a str,
}

/// Context for computing bucket scores on a candidate document.
/// Groups the document-derived and query-derived parameters.
pub struct ScoringContext<'a> {
    /// Lowercased content of the document
    pub content_lower: &'a str,
    /// Pre-tokenized words from the document
    pub doc_word_strs: &'a [&'a str],
    /// Query words to match against
    pub query_words: &'a [&'a str],
    /// Whether the last query word is a prefix (user still typing)
    pub last_word_is_prefix: bool,
    /// Optional prefix preference for ranking
    pub prefix_preference: Option<PrefixPreferenceQuery<'a>>,
    /// Document timestamp (unix seconds)
    pub timestamp: i64,
    /// BM25 score from tantivy
    pub bm25_score: f32,
    /// Current time (unix seconds)
    pub now: i64,
}

/// Per-query-word match result
#[derive(Debug, Clone, Copy)]
struct WordMatch {
    matched: bool,
    edit_dist: u8,
    doc_word_pos: usize,
    is_exact: bool,
    /// Weight toward coarse coverage and tie-break detail.
    /// Punctuation tokens (like "://", ".") get 0 — they participate in
    /// proximity and highlighting only. Word tokens get len² (IDF proxy).
    match_weight: u16,
}

/// Compute the bucket score for a candidate document.
///
/// `content_lower` and `doc_word_strs` should be pre-computed from the candidate's
/// content to avoid redundant work when the same tokens are needed for highlighting.
///
/// For large documents (>5KB), uses fast matching mode which only supports exact
/// and prefix matching, trading typo tolerance for performance.
pub fn compute_bucket_score(ctx: &ScoringContext<'_>) -> BucketScore {
    if ctx.query_words.is_empty() {
        return BucketScore {
            quality_tier: 0,
            recency_score: compute_recency_score(ctx.timestamp, ctx.now),
            quality_detail: 0,
            bm25_quantized: quantize_bm25(ctx.bm25_score),
            recency: ctx.timestamp,
        };
    }

    // Use fast matching for large documents to avoid expensive fuzzy matching
    let fast_mode = ctx.content_lower.len() > LARGE_DOC_THRESHOLD_BYTES;
    let word_matches = match_query_words(
        ctx.query_words,
        ctx.doc_word_strs,
        ctx.last_word_is_prefix,
        fast_mode,
    );

    let words_matched_weight: u16 = word_matches
        .iter()
        .filter(|m| m.matched)
        .map(|m| m.match_weight)
        .sum();
    let total_query_weight = query_total_match_weight(ctx.query_words);
    let prefix_preference_score =
        compute_prefix_preference_score(ctx.content_lower, ctx.prefix_preference);
    let total_edit_dist: u8 = word_matches
        .iter()
        .filter(|m| m.matched)
        .map(|m| m.edit_dist)
        .sum();
    let typo_score = 255u8.saturating_sub(total_edit_dist);

    let proximity_score = compute_proximity(&word_matches);
    let exactness_score = compute_exactness(ctx.content_lower, ctx.query_words, &word_matches);
    let quality_tier = compute_quality_tier(
        total_query_weight,
        words_matched_weight,
        exactness_score,
        &word_matches,
    );
    let quality_detail = compute_quality_detail(
        prefix_preference_score,
        words_matched_weight,
        typo_score,
        proximity_score,
        exactness_score,
        &word_matches,
    );
    let bm25_quantized = quantize_bm25(ctx.bm25_score);
    let recency_score = compute_recency_score(ctx.timestamp, ctx.now);

    BucketScore {
        quality_tier,
        recency_score,
        quality_detail,
        bm25_quantized,
        recency: ctx.timestamp,
    }
}

fn compute_prefix_preference_score(
    content_lower: &str,
    prefix_preference: Option<PrefixPreferenceQuery<'_>>,
) -> u8 {
    match prefix_preference {
        Some(PrefixPreferenceQuery {
            raw_query_lower,
            stripped_query_lower,
        }) if content_lower.starts_with(raw_query_lower) => 3,
        Some(PrefixPreferenceQuery {
            raw_query_lower, ..
        }) if content_lower.contains(raw_query_lower) => 2,
        Some(PrefixPreferenceQuery {
            stripped_query_lower,
            ..
        }) if content_lower.starts_with(stripped_query_lower) => 1,
        _ => 0,
    }
}

fn query_total_match_weight(query_words: &[&str]) -> u16 {
    query_words.iter().map(|qw| base_match_weight(qw)).sum()
}

#[derive(Debug, Clone, Copy)]
struct MatchSpanStats {
    matched_count: usize,
    all_matched: bool,
    in_sequence: bool,
    span: usize,
}

fn compute_match_span_stats(word_matches: &[WordMatch]) -> Option<MatchSpanStats> {
    let matched: Vec<&WordMatch> = word_matches.iter().filter(|m| m.matched).collect();
    if matched.is_empty() {
        return None;
    }

    let min_pos = matched.iter().map(|m| m.doc_word_pos).min().unwrap_or(0);
    let max_pos = matched.iter().map(|m| m.doc_word_pos).max().unwrap_or(0);
    let span = max_pos.saturating_sub(min_pos) + 1;
    let all_matched = word_matches.iter().all(|m| m.matched);

    let mut prev_pos = None;
    let mut in_sequence = true;
    for wm in word_matches {
        if !wm.matched {
            continue;
        }
        if let Some(prev) = prev_pos {
            if wm.doc_word_pos <= prev {
                in_sequence = false;
                break;
            }
        }
        prev_pos = Some(wm.doc_word_pos);
    }

    Some(MatchSpanStats {
        matched_count: matched.len(),
        all_matched,
        in_sequence,
        span,
    })
}

fn compute_quality_tier(
    total_query_weight: u16,
    words_matched_weight: u16,
    exactness_score: u8,
    word_matches: &[WordMatch],
) -> u8 {
    if words_matched_weight == 0 {
        return 0;
    }

    if word_matches.len() < 2 {
        return 1;
    }

    let Some(stats) = compute_match_span_stats(word_matches) else {
        return 0;
    };
    let coverage_pct = if total_query_weight == 0 {
        100
    } else {
        ((words_matched_weight as u32) * 100 / total_query_weight as u32) as u8
    };
    let dense_forward = stats.in_sequence && stats.span <= stats.matched_count + 1;
    let compact_full_match =
        stats.all_matched && stats.in_sequence && stats.span <= stats.matched_count * 2;

    if stats.all_matched && exactness_score >= 6 {
        return 3;
    }
    if (coverage_pct >= 60 && dense_forward) || (exactness_score >= 4 && compact_full_match) {
        return 2;
    }
    if coverage_pct >= 60 || stats.all_matched {
        return 1;
    }
    0
}

fn compute_structure_detail(
    proximity_score: u16,
    exactness_score: u8,
    word_matches: &[WordMatch],
) -> u32 {
    let Some(stats) = compute_match_span_stats(word_matches) else {
        return exactness_score as u32;
    };
    if stats.matched_count < 2 {
        return exactness_score as u32;
    }

    let order_rank = if stats.in_sequence {
        if stats.span == stats.matched_count {
            2u8
        } else {
            1u8
        }
    } else {
        0u8
    };
    let density = (((stats.matched_count as u32) * u8::MAX as u32) / stats.span.max(1) as u32)
        .min(u8::MAX as u32) as u8;
    let proximity_quantized = (proximity_score >> 8) as u8;

    ((order_rank as u32) << 24)
        | ((density as u32) << 16)
        | ((proximity_quantized as u32) << 8)
        | exactness_score as u32
}

fn compute_quality_detail(
    prefix_preference_score: u8,
    words_matched_weight: u16,
    typo_score: u8,
    proximity_score: u16,
    exactness_score: u8,
    word_matches: &[WordMatch],
) -> u64 {
    let structure_detail = compute_structure_detail(proximity_score, exactness_score, word_matches);
    ((prefix_preference_score as u64) << QUALITY_DETAIL_PREFIX_SHIFT)
        | ((words_matched_weight as u64) << QUALITY_DETAIL_COVERAGE_SHIFT)
        | ((structure_detail as u64) << QUALITY_DETAIL_STRUCTURE_SHIFT)
        | typo_score as u64
}

fn quality_detail_words_matched_weight(quality_detail: u64) -> u16 {
    ((quality_detail >> QUALITY_DETAIL_COVERAGE_SHIFT) & 0xFFFF) as u16
}

#[cfg(test)]
fn quality_detail_structure(quality_detail: u64) -> u32 {
    ((quality_detail >> QUALITY_DETAIL_STRUCTURE_SHIFT) & 0xFFFF_FFFF) as u32
}

#[cfg(test)]
fn quality_detail_typo_score(quality_detail: u64) -> u8 {
    quality_detail as u8
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
/// When `fast_mode` is true (for large documents), only exact and prefix matching
/// is used, skipping expensive fuzzy edit distance and subsequence matching.
fn match_query_words(
    query_words: &[&str],
    doc_words: &[&str],
    last_word_is_prefix: bool,
    fast_mode: bool,
) -> Vec<WordMatch> {
    let defaults: Vec<WordMatch> = query_words
        .iter()
        .map(|qw| WordMatch {
            matched: false,
            edit_dist: 0,
            doc_word_pos: 0,
            is_exact: false,
            match_weight: base_match_weight(qw),
        })
        .collect();

    let candidate_lists: Vec<Vec<WordMatch>> = query_words
        .iter()
        .enumerate()
        .map(|(qi, qw)| {
            let is_last = qi == query_words.len() - 1;
            let allow_prefix = is_last && last_word_is_prefix;
            collect_match_candidates(qw, doc_words, allow_prefix, fast_mode)
        })
        .collect();

    choose_best_alignment(&candidate_lists, &defaults)
}

fn base_match_weight(qw: &str) -> u16 {
    if is_word_token(qw) {
        (qw.len() as u16).saturating_mul(qw.len() as u16)
    } else {
        0
    }
}

fn collect_match_candidates(
    query_word: &str,
    doc_words: &[&str],
    allow_prefix: bool,
    fast_mode: bool,
) -> Vec<WordMatch> {
    let qw_lower = query_word.to_lowercase();
    let match_weight = base_match_weight(query_word);

    let candidates: Vec<WordMatch> = doc_words
        .iter()
        .enumerate()
        .filter_map(|(dpos, dw)| {
            let wmk = if fast_mode {
                does_word_match_fast(&qw_lower, dw, allow_prefix)
            } else {
                does_word_match(&qw_lower, dw, allow_prefix)
            };
            match wmk {
                WordMatchKind::Exact => Some(WordMatch {
                    matched: true,
                    edit_dist: 0,
                    doc_word_pos: dpos,
                    is_exact: true,
                    match_weight,
                }),
                WordMatchKind::Prefix => Some(WordMatch {
                    matched: true,
                    edit_dist: 0,
                    doc_word_pos: dpos,
                    is_exact: false,
                    match_weight,
                }),
                WordMatchKind::Fuzzy(dist) => Some(WordMatch {
                    matched: true,
                    edit_dist: dist,
                    doc_word_pos: dpos,
                    is_exact: false,
                    match_weight: if query_word.len() <= 3 {
                        1
                    } else {
                        match_weight
                    },
                }),
                WordMatchKind::Subsequence(gaps) => Some(WordMatch {
                    matched: true,
                    edit_dist: gaps.saturating_add(1),
                    doc_word_pos: dpos,
                    is_exact: false,
                    match_weight: if query_word.len() <= 3 {
                        1
                    } else {
                        match_weight
                    },
                }),
                WordMatchKind::None => None,
            }
        })
        .collect();

    trim_match_candidates(candidates)
}

fn trim_match_candidates(candidates: Vec<WordMatch>) -> Vec<WordMatch> {
    const MAX_CANDIDATES_PER_QUERY_WORD: usize = 8;
    if candidates.len() <= MAX_CANDIDATES_PER_QUERY_WORD {
        return candidates;
    }

    let mut by_quality = candidates.clone();
    by_quality.sort_by(candidate_quality_cmp);

    let mut by_pos = candidates;
    by_pos.sort_by_key(|c| c.doc_word_pos);

    let mut chosen = Vec::new();
    let mut seen_positions = HashSet::new();

    for cand in by_quality.iter().take(4) {
        if seen_positions.insert(cand.doc_word_pos) {
            chosen.push(*cand);
        }
    }
    for cand in by_pos.iter().take(2).chain(by_pos.iter().rev().take(2)) {
        if seen_positions.insert(cand.doc_word_pos) {
            chosen.push(*cand);
        }
    }
    for cand in by_quality {
        if chosen.len() >= MAX_CANDIDATES_PER_QUERY_WORD {
            break;
        }
        if seen_positions.insert(cand.doc_word_pos) {
            chosen.push(cand);
        }
    }

    chosen
}

fn candidate_quality_cmp(a: &WordMatch, b: &WordMatch) -> std::cmp::Ordering {
    candidate_quality_key(b).cmp(&candidate_quality_key(a))
}

fn candidate_quality_key(m: &WordMatch) -> (u8, u16, u8, std::cmp::Reverse<usize>) {
    let kind_rank = if m.is_exact {
        3
    } else if m.edit_dist == 0 {
        2
    } else {
        1
    };
    (
        kind_rank,
        m.match_weight,
        255u8.saturating_sub(m.edit_dist),
        std::cmp::Reverse(m.doc_word_pos),
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct AlignmentScore {
    quality_tier: u8,
    quality_detail: u64,
    matched_query_mask: u64,
}

fn choose_best_alignment(
    candidate_lists: &[Vec<WordMatch>],
    defaults: &[WordMatch],
) -> Vec<WordMatch> {
    let mut current = defaults.to_vec();
    let mut best = defaults.to_vec();
    let mut best_score = score_alignment(&best);
    let mut used_positions = HashSet::new();

    choose_best_alignment_recursive(
        0,
        candidate_lists,
        defaults,
        &mut used_positions,
        &mut current,
        &mut best,
        &mut best_score,
    );

    best
}

fn choose_best_alignment_recursive(
    qi: usize,
    candidate_lists: &[Vec<WordMatch>],
    defaults: &[WordMatch],
    used_positions: &mut HashSet<usize>,
    current: &mut [WordMatch],
    best: &mut Vec<WordMatch>,
    best_score: &mut AlignmentScore,
) {
    if qi == candidate_lists.len() {
        let score = score_alignment(current);
        if score > *best_score {
            *best_score = score;
            *best = current.to_vec();
        }
        return;
    }

    current[qi] = defaults[qi];
    choose_best_alignment_recursive(
        qi + 1,
        candidate_lists,
        defaults,
        used_positions,
        current,
        best,
        best_score,
    );

    for candidate in &candidate_lists[qi] {
        if !used_positions.insert(candidate.doc_word_pos) {
            continue;
        }
        current[qi] = *candidate;
        choose_best_alignment_recursive(
            qi + 1,
            candidate_lists,
            defaults,
            used_positions,
            current,
            best,
            best_score,
        );
        used_positions.remove(&candidate.doc_word_pos);
    }
}

fn score_alignment(word_matches: &[WordMatch]) -> AlignmentScore {
    let total_query_weight: u16 = word_matches.iter().map(|m| m.match_weight).sum();
    let words_matched_weight: u16 = word_matches
        .iter()
        .filter(|m| m.matched)
        .map(|m| m.match_weight)
        .sum();
    let typo_score = 255u8.saturating_sub(
        word_matches
            .iter()
            .filter(|m| m.matched)
            .map(|m| m.edit_dist)
            .sum::<u8>(),
    );
    let proximity_score = compute_proximity(word_matches);
    let exactness_hint = alignment_exactness_hint(word_matches);
    let quality_tier = compute_quality_tier(
        total_query_weight,
        words_matched_weight,
        exactness_hint,
        word_matches,
    );
    let quality_detail = compute_quality_detail(
        0,
        words_matched_weight,
        typo_score,
        proximity_score,
        exactness_hint,
        word_matches,
    );

    AlignmentScore {
        quality_tier,
        quality_detail,
        matched_query_mask: alignment_matched_query_mask(word_matches),
    }
}

fn alignment_matched_query_mask(word_matches: &[WordMatch]) -> u64 {
    word_matches.iter().enumerate().fold(0u64, |mask, (i, wm)| {
        if wm.matched {
            mask | (1u64 << (63usize.saturating_sub(i)))
        } else {
            mask
        }
    })
}

fn alignment_exactness_hint(word_matches: &[WordMatch]) -> u8 {
    let matched_count = word_matches.iter().filter(|m| m.matched).count();
    if matched_count < 2 {
        return 0;
    }

    let all_matched = word_matches.iter().all(|m| m.matched);
    if all_matched {
        let in_sequence = word_matches
            .windows(2)
            .all(|w| w[1].doc_word_pos > w[0].doc_word_pos);
        if in_sequence {
            let contiguous = word_matches
                .windows(2)
                .all(|w| w[1].doc_word_pos == w[0].doc_word_pos + 1);
            if contiguous {
                return 4;
            }
            return 2;
        }
    }

    0
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

/// Fast word matching for large documents (>5KB). Only exact and prefix matching,
/// no fuzzy edit distance or subsequence matching. This is much faster as it avoids
/// expensive DP table allocations for edit distance computation.
pub(crate) fn does_word_match_fast(
    qw_lower: &str,
    dw_lower: &str,
    allow_prefix: bool,
) -> WordMatchKind {
    if dw_lower == qw_lower {
        return WordMatchKind::Exact;
    }
    if allow_prefix && qw_lower.len() >= 2 && dw_lower.starts_with(qw_lower) {
        return WordMatchKind::Prefix;
    }
    WordMatchKind::None
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

/// Compute exactness score (0-6 scale).
/// 6: Full query is a prefix of the content (starts_with)
/// 5: First query word matches first doc word exactly + all matched words in forward sequence
/// 4: Full query appears as exact substring anywhere (case-insensitive)
/// 3: All matched words are exact (0 edit distance, exact string match)
/// 2: All matched words are exact or prefix (0 edit distance; "typing in progress")
/// 1: At least one exact or prefix match mixed with fuzzy
/// 0: All matches are fuzzy only
fn compute_exactness(content_lower: &str, query_words: &[&str], word_matches: &[WordMatch]) -> u8 {
    let matched: Vec<&WordMatch> = word_matches.iter().filter(|m| m.matched).collect();
    if matched.is_empty() {
        return 0;
    }

    let full_query = if !query_words.is_empty() {
        query_words.join(" ").to_lowercase()
    } else {
        String::new()
    };

    // Level 6: query is prefix of content
    if !full_query.is_empty() && content_lower.starts_with(&full_query) {
        return 6;
    }

    // Level 5: first word anchored at doc start, all words in forward sequence
    let all_matched = word_matches.iter().all(|m| m.matched);
    if all_matched && word_matches.len() > 1 {
        let first = &word_matches[0];
        if first.doc_word_pos == 0 && first.edit_dist == 0 {
            let in_sequence = word_matches
                .windows(2)
                .all(|w| w[1].doc_word_pos > w[0].doc_word_pos);
            if in_sequence {
                return 5;
            }
        }
    }

    // Level 4: full query is substring anywhere
    if !full_query.is_empty() && content_lower.contains(&full_query) {
        return 4;
    }

    let all_exact = matched.iter().all(|m| m.is_exact);
    if all_exact {
        return 3;
    }

    // Prefix matches have edit_dist == 0 but is_exact == false.
    // They represent "typing in progress" — higher intent than a fuzzy typo.
    let all_exact_or_prefix = matched.iter().all(|m| m.edit_dist == 0);
    if all_exact_or_prefix {
        return 2;
    }

    let any_exact_or_prefix = matched.iter().any(|m| m.edit_dist == 0);
    if any_exact_or_prefix {
        return 1;
    }

    0
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
        return if dist <= max_d {
            Some(dist as u8)
        } else {
            None
        };
    }

    // First-character penalty: mismatch on position 0 costs +1 edit.
    // Exception: first-two-char transposition ("hte"→"the") is a common fast-typing error.
    let is_first_char_transposed =
        m >= 2 && n >= 2 && a_chars[0] == b_chars[1] && a_chars[1] == b_chars[0];
    let first_char_penalty = if a_chars[0] != b_chars[0] && !is_first_char_transposed {
        1
    } else {
        0
    };

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
            let cost = if a_chars[i - 1] == b_chars[j - 1] {
                0
            } else {
                1
            };
            curr[j] = (prev[j] + 1).min(curr[j - 1] + 1).min(prev[j - 1] + cost);

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
    fn score(
        content: &str,
        query_words: &[&str],
        last_word_is_prefix: bool,
        prefix_preference: Option<PrefixPreferenceQuery<'_>>,
        timestamp: i64,
        bm25: f32,
        now: i64,
    ) -> BucketScore {
        use crate::search::tokenize_words;
        let content_lower = content.to_lowercase();
        let doc_words = tokenize_words(&content_lower);
        let doc_word_strs: Vec<&str> = doc_words
            .iter()
            .map(|(_, _, w): &(usize, usize, String)| w.as_str())
            .collect();
        compute_bucket_score(&ScoringContext {
            content_lower: &content_lower,
            doc_word_strs: &doc_word_strs,
            query_words,
            last_word_is_prefix,
            prefix_preference,
            timestamp,
            bm25_score: bm25,
            now,
        })
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
        assert_eq!(
            does_word_match("hello", "hello", false),
            WordMatchKind::Exact
        );
    }

    #[test]
    fn test_does_word_match_prefix() {
        assert_eq!(
            does_word_match("cl", "clipkitty", true),
            WordMatchKind::Prefix
        );
        // Not allowed when allow_prefix=false
        assert_eq!(
            does_word_match("cl", "clipkitty", false),
            WordMatchKind::None
        );
        // Single char prefix not allowed (< 2 chars)
        assert_eq!(does_word_match("c", "clipkitty", true), WordMatchKind::None);
    }

    #[test]
    fn test_does_word_match_fuzzy() {
        // "riversde" (8 chars) -> max_dist 1
        assert_eq!(
            does_word_match("riversde", "riverside", false),
            WordMatchKind::Fuzzy(1)
        );
        // "improt" (6 chars) -> max_dist 1, transposition counts as 1
        assert_eq!(
            does_word_match("improt", "import", false),
            WordMatchKind::Fuzzy(1)
        );
        // Short word transpositions (3-4 chars)
        assert_eq!(
            does_word_match("teh", "the", false),
            WordMatchKind::Fuzzy(1)
        );
        assert_eq!(
            does_word_match("form", "from", false),
            WordMatchKind::Fuzzy(1)
        );
        assert_eq!(
            does_word_match("adn", "and", false),
            WordMatchKind::Fuzzy(1)
        );
        // Short word substitution — also matches (same edit distance)
        assert_eq!(
            does_word_match("tha", "the", false),
            WordMatchKind::Fuzzy(1)
        );
        // First-char mismatch penalty prevents false positives
        assert_eq!(does_word_match("bat", "cat", false), WordMatchKind::None);
        assert_eq!(does_word_match("rat", "cat", false), WordMatchKind::None);
        // 2-char words still get no fuzzy
        assert_eq!(does_word_match("te", "the", false), WordMatchKind::None);
    }

    #[test]
    fn test_does_word_match_subsequence() {
        // "helo" (4 chars) -> fuzzy wins: edit_distance("helo","hello")=1
        assert_eq!(
            does_word_match("helo", "hello", false),
            WordMatchKind::Fuzzy(1)
        );
        // "impt" (4 chars) -> len diff 2 exceeds max_dist 1, falls to subsequence
        assert_eq!(
            does_word_match("impt", "import", false),
            WordMatchKind::Subsequence(1)
        );
        // "cls" (3 chars) -> too short for both fuzzy and subsequence now
        assert_eq!(does_word_match("cls", "class", false), WordMatchKind::None);
        // Too short for subsequence (<= 3 chars)
        assert_eq!(does_word_match("ab", "abc", false), WordMatchKind::None);
        // Coverage too low: 3 chars vs 7 char target (43% < 50%)
        assert_eq!(
            does_word_match("abc", "abcdefg", false),
            WordMatchKind::None
        );
        // Fuzzy takes priority over subsequence when both could match
        // "imprt" (5 chars) has edit_distance 1 to "import", so fuzzy wins
        assert_eq!(
            does_word_match("imprt", "import", false),
            WordMatchKind::Fuzzy(1)
        );
    }

    // ── match_query_words tests ──────────────────────────────────

    #[test]
    fn test_match_exact() {
        let doc_words = vec!["hello", "world"];
        let matches = match_query_words(&["hello"], &doc_words, false, false);
        assert_eq!(matches.len(), 1);
        assert!(matches[0].matched);
        assert_eq!(matches[0].edit_dist, 0);
        assert!(matches[0].is_exact);
    }

    #[test]
    fn test_match_prefix_last_word() {
        let doc_words = vec!["clipkitty"];
        let matches = match_query_words(&["cl"], &doc_words, true, false);
        assert_eq!(matches.len(), 1);
        assert!(matches[0].matched);
        assert_eq!(matches[0].edit_dist, 0);
    }

    #[test]
    fn test_match_prefix_not_allowed_non_last() {
        let doc_words = vec!["clipkitty"];
        let matches = match_query_words(&["cl", "hello"], &doc_words, true, false);
        assert!(!matches[0].matched);
    }

    #[test]
    fn test_match_fuzzy() {
        let doc_words = vec!["riverside", "park"];
        let matches = match_query_words(&["riversde"], &doc_words, false, false);
        assert!(matches[0].matched);
        assert_eq!(matches[0].edit_dist, 1);
    }

    #[test]
    fn test_match_fuzzy_short_word() {
        // "helo" (4 chars) matches "hello" via fuzzy (edit distance 1)
        let doc_words = vec!["hello"];
        let matches = match_query_words(&["helo"], &doc_words, false, false);
        assert!(matches[0].matched);
        assert_eq!(matches[0].edit_dist, 1);
    }

    #[test]
    fn test_match_transposition_short_word() {
        // "teh" (3 chars) matches "the" via fuzzy (transposition = 1 edit)
        let doc_words = vec!["the", "quick"];
        let matches = match_query_words(&["teh"], &doc_words, false, false);
        assert!(matches[0].matched);
        assert_eq!(matches[0].edit_dist, 1);
        assert!(!matches[0].is_exact);
    }

    #[test]
    fn test_match_multi_word() {
        let doc_words = vec!["hello", "beautiful", "world"];
        let matches = match_query_words(&["hello", "world"], &doc_words, false, false);
        assert!(matches[0].matched);
        assert!(matches[1].matched);
        assert_eq!(matches[0].doc_word_pos, 0);
        assert_eq!(matches[1].doc_word_pos, 2);
    }

    #[test]
    fn test_match_repeated_query_words_require_distinct_doc_occurrences() {
        let doc_words = vec!["hello", "world"];
        let matches = match_query_words(&["hello", "hello"], &doc_words, false, false);
        assert!(matches[0].matched);
        assert!(
            !matches[1].matched,
            "A repeated query token should not reuse the same document token"
        );
    }

    #[test]
    fn test_match_prefers_best_global_alignment_over_earliest_exact_occurrences() {
        let doc_words = vec!["alpha", "noise", "noise", "noise", "beta", "alpha", "beta"];
        let matches = match_query_words(&["alpha", "beta"], &doc_words, false, false);
        assert_eq!(
            matches[0].doc_word_pos, 5,
            "Should use the tighter trailing cluster"
        );
        assert_eq!(
            matches[1].doc_word_pos, 6,
            "Should use the tighter trailing cluster"
        );
    }

    // ── compute_proximity tests ──────────────────────────────────

    #[test]
    fn test_proximity_adjacent() {
        let matches = vec![
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 0,
                is_exact: true,
                match_weight: 25,
            },
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 1,
                is_exact: true,
                match_weight: 25,
            },
        ];
        assert_eq!(compute_proximity(&matches), u16::MAX - 1);
    }

    #[test]
    fn test_proximity_gap() {
        let matches = vec![
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 0,
                is_exact: true,
                match_weight: 25,
            },
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 5,
                is_exact: true,
                match_weight: 25,
            },
        ];
        assert_eq!(compute_proximity(&matches), u16::MAX - 5);
    }

    #[test]
    fn test_proximity_single_word() {
        let matches = vec![WordMatch {
            matched: true,
            edit_dist: 0,
            doc_word_pos: 3,
            is_exact: true,
            match_weight: 25,
        }];
        assert_eq!(compute_proximity(&matches), u16::MAX);
    }

    #[test]
    fn test_proximity_unmatched_words_skipped() {
        let matches = vec![
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 0,
                is_exact: true,
                match_weight: 25,
            },
            WordMatch {
                matched: false,
                edit_dist: 0,
                doc_word_pos: 0,
                is_exact: false,
                match_weight: 25,
            },
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 3,
                is_exact: true,
                match_weight: 25,
            },
        ];
        assert_eq!(compute_proximity(&matches), u16::MAX - 3);
    }

    #[test]
    fn test_quality_tier_prefers_dense_matches() {
        let dense = vec![
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 0,
                is_exact: true,
                match_weight: 25,
            },
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 1,
                is_exact: true,
                match_weight: 25,
            },
        ];
        let scattered = vec![
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 0,
                is_exact: true,
                match_weight: 25,
            },
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 8,
                is_exact: true,
                match_weight: 25,
            },
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 16,
                is_exact: true,
                match_weight: 25,
            },
        ];

        let dense_tier = compute_quality_tier(75, 50, 3, &dense);
        let scattered_tier = compute_quality_tier(75, 75, 3, &scattered);
        assert!(dense_tier > scattered_tier);
    }

    // ── compute_exactness tests ──────────────────────────────────

    #[test]
    fn test_exactness_full_substring() {
        // "hello world" starts with "hello world" → level 6
        let matches = vec![
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 0,
                is_exact: true,
                match_weight: 25,
            },
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 1,
                is_exact: true,
                match_weight: 25,
            },
        ];
        assert_eq!(
            compute_exactness("hello world", &["hello", "world"], &matches),
            6
        );
    }

    #[test]
    fn test_exactness_all_exact_but_not_substring() {
        // first word at pos 0, forward sequence → level 5
        let matches = vec![
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 0,
                is_exact: true,
                match_weight: 25,
            },
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 2,
                is_exact: true,
                match_weight: 25,
            },
        ];
        assert_eq!(
            compute_exactness("hello beautiful world", &["hello", "world"], &matches),
            5
        );
    }

    #[test]
    fn test_exactness_mix_exact_fuzzy() {
        // first word at pos 0 exact, second fuzzy in forward sequence → level 5
        let matches = vec![
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 0,
                is_exact: true,
                match_weight: 25,
            },
            WordMatch {
                matched: true,
                edit_dist: 1,
                doc_word_pos: 1,
                is_exact: false,
                match_weight: 25,
            },
        ];
        assert_eq!(
            compute_exactness("hello wrld", &["hello", "world"], &matches),
            5
        );
    }

    #[test]
    fn test_exactness_all_prefix() {
        // Multi-word query where both match as prefix (edit_dist 0, is_exact false).
        // First word at pos 0 with edit_dist 0, forward sequence → level 5.
        let matches = vec![
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 0,
                is_exact: false,
                match_weight: 25,
            },
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 1,
                is_exact: false,
                match_weight: 25,
            },
        ];
        assert_eq!(
            compute_exactness("hello world", &["hel", "wor"], &matches),
            5
        );
    }

    #[test]
    fn test_exactness_prefix_beats_fuzzy() {
        // Prefix (level 2) should rank above all-fuzzy (level 0)
        let prefix = vec![
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 0,
                is_exact: false,
                match_weight: 25,
            },
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 1,
                is_exact: false,
                match_weight: 25,
            },
        ];
        let fuzzy = vec![WordMatch {
            matched: true,
            edit_dist: 1,
            doc_word_pos: 0,
            is_exact: false,
            match_weight: 25,
        }];
        assert!(
            compute_exactness("hello world", &["hel", "wor"], &prefix)
                > compute_exactness("hallo", &["hello"], &fuzzy)
        );
    }

    #[test]
    fn test_exactness_all_fuzzy() {
        let matches = vec![WordMatch {
            matched: true,
            edit_dist: 1,
            doc_word_pos: 0,
            is_exact: false,
            match_weight: 25,
        }];
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

        assert!(
            (160..=180).contains(&(at_1h as u16)),
            "1h: expected ~169, got {}",
            at_1h
        );
        assert!(
            (70..=90).contains(&(at_24h as u16)),
            "24h: expected ~80, got {}",
            at_24h
        );
        assert!(
            (15..=35).contains(&(at_7d as u16)),
            "7d: expected ~25, got {}",
            at_7d
        );
        // 24h-7d gap should be clearly larger than 7d score itself
        assert!(
            at_24h - at_7d > at_7d,
            "24h-7d gap ({}) should exceed 7d score ({})",
            at_24h - at_7d,
            at_7d
        );
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
            assert!(
                score <= prev,
                "score should decrease: {} > {} at {}min",
                score,
                prev,
                minutes
            );
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
        assert!(
            at_5m > at_15m,
            "5min ({}) should beat 15min ({})",
            at_5m,
            at_15m
        );
        assert!(
            at_15m > at_30m,
            "15min ({}) should beat 30min ({})",
            at_15m,
            at_30m
        );
        assert!(
            at_30m > at_55m,
            "30min ({}) should beat 55min ({})",
            at_30m,
            at_55m
        );
    }

    // ── bucket score ordering tests ──────────────────────────────

    #[test]
    fn test_long_important_term_can_beat_multiple_short_terms() {
        let now = 1700000000i64;
        let long_term = score(
            "encyclopedia",
            &["encyclopedia", "to", "be", "or"],
            false,
            None,
            now - 3600,
            1.0,
            now,
        );
        let short_terms = score(
            "to be or",
            &["encyclopedia", "to", "be", "or"],
            false,
            None,
            now - 3600,
            1.0,
            now,
        );
        assert!(
            long_term > short_terms,
            "A single long, important term should outrank several short terms"
        );
    }

    #[test]
    fn test_exact_phrase_can_beat_scattered_full_coverage() {
        let now = 1700000000i64;
        let exact_phrase = score(
            "hello world",
            &["hello", "world", "today"],
            false,
            None,
            now,
            1.0,
            now,
        );
        let scattered_full = score(
            "hello unrelated unrelated unrelated world unrelated unrelated unrelated today",
            &["hello", "world", "today"],
            false,
            None,
            now,
            1.0,
            now,
        );
        assert!(
            exact_phrase > scattered_full,
            "A dense exact phrase should beat scattered full coverage"
        );
    }

    #[test]
    fn test_recency_dominates_typo() {
        let now = 1700000000i64;
        // Typo match from now vs exact match from 10 days ago
        let typo_new = score("riversde park", &["riverside"], false, None, now, 1.0, now);
        let exact_old = score(
            "riverside park",
            &["riverside"],
            false,
            None,
            now - 864000,
            1.0,
            now,
        );
        assert_eq!(typo_new.quality_tier, exact_old.quality_tier);
        assert!(
            typo_new > exact_old,
            "Recent fuzzy match should beat old exact match"
        );
    }

    #[test]
    fn test_typo_dominates_within_same_recency() {
        let now = 1700000000i64;
        // Both items from the same time — typo should break the tie
        let exact = score(
            "riverside park",
            &["riverside"],
            false,
            None,
            now - 3600,
            1.0,
            now,
        );
        let typo = score(
            "riversde park",
            &["riverside"],
            false,
            None,
            now - 3600,
            1.0,
            now,
        );
        assert!(
            exact > typo,
            "Exact match should beat fuzzy at equal recency"
        );
    }

    #[test]
    fn test_single_word_prefix_beats_slightly_newer_fuzzy_match() {
        let now = 1700000000i64;
        let older_prefix = score("claude", &["cla"], true, None, now - 60, 1.0, now);
        let newer_fuzzy = score("cli", &["cla"], true, None, now, 1.0, now);
        assert!(
            older_prefix > newer_fuzzy,
            "A strong single-word prefix should beat a slightly newer fuzzy near-match"
        );
    }

    #[test]
    fn test_content_prefix_beats_moderately_newer_word_prefix() {
        let now = 1700000000i64;
        let older_content_prefix = score("claude notes", &["cla"], true, None, now - 600, 1.0, now);
        let newer_word_prefix = score("say claude notes", &["cla"], true, None, now - 180, 1.0, now);
        assert!(
            older_content_prefix > newer_word_prefix,
            "Across a moderate age gap, content-prefix should beat a newer non-initial word-prefix match"
        );
    }

    #[test]
    fn test_recent_word_prefix_beats_ancient_content_prefix() {
        let now = 1700000000i64;
        let ancient_content_prefix =
            score("claude notes", &["cla"], true, None, now - 60 * 86400, 1.0, now);
        let recent_word_prefix =
            score("say claude notes", &["cla"], true, None, now - 600, 1.0, now);
        assert!(
            recent_word_prefix > ancient_content_prefix,
            "Across a massive age gap, recency should beat the stronger content-prefix match"
        );
    }

    #[test]
    fn test_exact_short_typo_beats_slightly_newer_common_transposition() {
        let now = 1700000000i64;
        let older_exact = score("teh", &["teh"], true, None, now - 60, 1.0, now);
        let newer_transposition = score("the", &["teh"], true, None, now, 1.0, now);
        assert!(
            older_exact > newer_transposition,
            "Within roughly the same recency, the literal query should beat a recent transposition match"
        );
    }

    #[test]
    fn test_exact_match_beats_moderately_newer_typo_match() {
        let now = 1700000000i64;
        let older_exact = score("the", &["the"], false, None, now - 600, 1.0, now);
        let newer_typo = score("teh", &["the"], false, None, now - 180, 1.0, now);
        assert!(
            older_exact > newer_typo,
            "Across a moderate age gap, exact match quality should beat a newer typo match"
        );
    }

    #[test]
    fn test_recent_common_transposition_beats_ancient_exact_typo() {
        let now = 1700000000i64;
        let ancient_exact = score("teh", &["teh"], true, None, now - 864000, 1.0, now);
        let recent_transposition = score("the", &["teh"], true, None, now, 1.0, now);
        assert!(
            recent_transposition > ancient_exact,
            "A recent common transposition should still beat an ancient literal typo"
        );
    }

    #[test]
    fn test_recent_typo_beats_ancient_exact_match() {
        let now = 1700000000i64;
        let ancient_exact = score("the", &["the"], false, None, now - 90 * 86400, 1.0, now);
        let recent_typo = score("teh", &["the"], false, None, now - 180, 1.0, now);
        assert!(
            recent_typo > ancient_exact,
            "Across a massive age gap, recency should beat the stronger exact match"
        );
    }

    #[test]
    fn test_recency_breaks_ties_when_structure_equal() {
        let now = 1700000000i64;
        // Same structure and same word quality - recency should break the tie.
        let recent = score(
            "hello world alpha",
            &["hello", "world"],
            false,
            None,
            now - 1800,
            1.0,
            now,
        );
        let old = score(
            "hello world beta",
            &["hello", "world"],
            false,
            None,
            now - 864000,
            1.0,
            now,
        );
        assert_eq!(recent.quality_tier, old.quality_tier);
        assert!(
            recent > old,
            "Recent item should win when structure and words are equal"
        );
    }

    #[test]
    fn test_phrase_quality_can_beat_small_recency_gap() {
        let now = 1700000000i64;
        let older_phrase = score(
            "hello world",
            &["hello", "world"],
            false,
            None,
            now - 30,
            1.0,
            now,
        );
        let newer_reversed = score(
            "world hello",
            &["hello", "world"],
            false,
            None,
            now,
            1.0,
            now,
        );
        assert!(older_phrase.quality_tier > newer_reversed.quality_tier);
        assert!(
            older_phrase > newer_reversed,
            "A high-quality phrase should beat a slightly newer reversed match"
        );
    }

    #[test]
    fn test_proximity_inversion_penalty() {
        // Forward order: distance = 2 - 0 = 2
        let forward = vec![
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 0,
                is_exact: true,
                match_weight: 25,
            },
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 2,
                is_exact: true,
                match_weight: 25,
            },
        ];
        // Reverse order: distance = (0 - 2) + 5 penalty = 7
        let reversed = vec![
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 2,
                is_exact: true,
                match_weight: 25,
            },
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 0,
                is_exact: true,
                match_weight: 25,
            },
        ];
        assert_eq!(compute_proximity(&forward), u16::MAX - 2);
        assert_eq!(compute_proximity(&reversed), u16::MAX - 7);
        assert!(
            compute_proximity(&forward) > compute_proximity(&reversed),
            "Forward order should score higher than reversed"
        );
    }

    #[test]
    fn test_full_bucket_score_integration() {
        let now = 1700000000i64;
        let s = score(
            "hello world",
            &["hello", "world"],
            false,
            None,
            now,
            5.0,
            now,
        );
        assert_eq!(s.quality_tier, 3); // exact prefix of the content
        assert_eq!(s.words_matched_weight(), 50); // 5² + 5² = 50
        assert_eq!(s.recency_score, 255); // just now
        assert_eq!(quality_detail_typo_score(s.quality_detail), 255);
        assert!(quality_detail_structure(s.quality_detail) > 0);
        assert_eq!(s.bm25_quantized, 500); // 5.0 * 100
    }

    // ── new exactness level 6 & 5 tests ─────────────────────────

    #[test]
    fn test_exactness_prefix_of_content() {
        // "hello wo" is a prefix of "hello world foo" → level 6
        let matches = vec![
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 0,
                is_exact: true,
                match_weight: 25,
            },
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 1,
                is_exact: false,
                match_weight: 25,
            },
        ];
        assert_eq!(
            compute_exactness("hello world foo", &["hello", "wo"], &matches),
            6
        );
    }

    #[test]
    fn test_exactness_prefix_of_content_single_word() {
        // "hel" is a prefix of "hello world" → level 6
        let matches = vec![WordMatch {
            matched: true,
            edit_dist: 0,
            doc_word_pos: 0,
            is_exact: false,
            match_weight: 25,
        }];
        assert_eq!(compute_exactness("hello world", &["hel"], &matches), 6);
    }

    #[test]
    fn test_exactness_first_word_anchored_sequence() {
        // first word exact at pos 0, second fuzzy at pos 1 → level 5
        let matches = vec![
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 0,
                is_exact: true,
                match_weight: 25,
            },
            WordMatch {
                matched: true,
                edit_dist: 1,
                doc_word_pos: 1,
                is_exact: false,
                match_weight: 25,
            },
        ];
        assert_eq!(
            compute_exactness("hello wrold foo", &["hello", "world"], &matches),
            5
        );
    }

    #[test]
    fn test_exactness_first_word_not_at_start() {
        // first word matches but not at pos 0 → falls through to lower level
        let matches = vec![
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 1,
                is_exact: true,
                match_weight: 25,
            },
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 2,
                is_exact: true,
                match_weight: 25,
            },
        ];
        // "hello world" is not a substring of "say hello world" when query is ["hello", "world"]
        // Wait — it IS a substring. Use a query that won't be a substring.
        assert_eq!(
            compute_exactness("say hello beautiful world", &["hello", "world"], &matches),
            3
        );
    }

    #[test]
    fn test_exactness_anchored_but_wrong_order() {
        // first word at pos 0 but words out of order → falls through to level 3 (all exact)
        let matches = vec![
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 0,
                is_exact: true,
                match_weight: 25,
            },
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 2,
                is_exact: true,
                match_weight: 25,
            },
            WordMatch {
                matched: true,
                edit_dist: 0,
                doc_word_pos: 1,
                is_exact: true,
                match_weight: 25,
            },
        ];
        // words go 0, 2, 1 — not strictly forward, and "hello beautiful world" is not a substring
        assert_eq!(
            compute_exactness(
                "hello world beautiful",
                &["hello", "beautiful", "world"],
                &matches
            ),
            3
        );
    }
}
