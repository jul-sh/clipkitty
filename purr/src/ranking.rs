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
/// 2. recency_bucket — coarse human-scale age bands
/// 3. quality_detail — nuanced coverage/structure/typo detail within a recency bucket
/// 4. recency_score — smooth logarithmic decay (255=now, 0=old)
/// 5. bm25_quantized — BM25 scaled to integer
/// 6. recency — raw unix timestamp (final tiebreaker)
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct BucketScore {
    pub quality_tier: u8,
    pub recency_bucket: u8,
    pub quality_detail: u64,
    pub recency_score: u8,
    pub bm25_quantized: u16,
    pub recency: i64,
}

const QUALITY_DETAIL_PREFIX_SHIFT: u64 = 56;
const QUALITY_DETAIL_COVERAGE_SHIFT: u64 = 40;
const QUALITY_DETAIL_STRUCTURE_SHIFT: u64 = 16;
const QUALITY_DETAIL_TYPO_CLASS_SHIFT: u64 = 8;
const RECENCY_BUCKET_LAST_HOUR_MAX_AGE_SECS: i64 = 3600;
const RECENCY_BUCKET_LAST_DAY_MAX_AGE_SECS: i64 = 86_400;
const RECENCY_BUCKET_LAST_WEEK_MAX_AGE_SECS: i64 = 7 * RECENCY_BUCKET_LAST_DAY_MAX_AGE_SECS;
const RECENCY_BUCKET_LAST_MONTH_MAX_AGE_SECS: i64 = 30 * RECENCY_BUCKET_LAST_DAY_MAX_AGE_SECS;
const RECENCY_BUCKET_LAST_QUARTER_MAX_AGE_SECS: i64 = 90 * RECENCY_BUCKET_LAST_DAY_MAX_AGE_SECS;
const RECENCY_BUCKET_LAST_DAY_MIN_AGE_SECS: i64 = RECENCY_BUCKET_LAST_HOUR_MAX_AGE_SECS + 1;
const RECENCY_BUCKET_LAST_WEEK_MIN_AGE_SECS: i64 = RECENCY_BUCKET_LAST_DAY_MAX_AGE_SECS + 1;
const RECENCY_BUCKET_LAST_MONTH_MIN_AGE_SECS: i64 = RECENCY_BUCKET_LAST_WEEK_MAX_AGE_SECS + 1;
const RECENCY_BUCKET_LAST_QUARTER_MIN_AGE_SECS: i64 = RECENCY_BUCKET_LAST_MONTH_MAX_AGE_SECS + 1;
const RECENCY_BUCKET_LAST_HOUR: u8 = 5;
const RECENCY_BUCKET_LAST_DAY: u8 = 4;
const RECENCY_BUCKET_LAST_WEEK: u8 = 3;
const RECENCY_BUCKET_LAST_MONTH: u8 = 2;
const RECENCY_BUCKET_LAST_QUARTER: u8 = 1;
const RECENCY_BUCKET_STALE: u8 = 0;

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
    /// Weight toward coarse coverage and tie-break detail.
    /// Punctuation tokens (like "://", ".") get 0 — they participate in
    /// proximity and highlighting only. Word tokens get len² (IDF proxy).
    query_weight: u16,
    query_len: usize,
    state: WordMatchState,
}

#[derive(Debug, Clone, Copy)]
enum WordMatchState {
    Unmatched,
    Exact {
        doc_word_pos: usize,
    },
    Prefix {
        doc_word_pos: usize,
    },
    Fuzzy {
        doc_word_pos: usize,
        edit_dist: u8,
        typo_class: TypoClass,
    },
    Subsequence {
        doc_word_pos: usize,
        gaps: u8,
    },
}

impl WordMatch {
    fn unmatched(query_word: &str) -> Self {
        Self {
            query_weight: base_match_weight(query_word),
            query_len: query_word.chars().count(),
            state: WordMatchState::Unmatched,
        }
    }

    fn exact(query_word: &str, doc_word_pos: usize) -> Self {
        Self {
            query_weight: base_match_weight(query_word),
            query_len: query_word.chars().count(),
            state: WordMatchState::Exact { doc_word_pos },
        }
    }

    fn prefix(query_word: &str, doc_word_pos: usize) -> Self {
        Self {
            query_weight: base_match_weight(query_word),
            query_len: query_word.chars().count(),
            state: WordMatchState::Prefix { doc_word_pos },
        }
    }

    fn fuzzy(query_word: &str, doc_word_pos: usize, edit_dist: u8, typo_class: TypoClass) -> Self {
        Self {
            query_weight: base_match_weight(query_word),
            query_len: query_word.chars().count(),
            state: WordMatchState::Fuzzy {
                doc_word_pos,
                edit_dist,
                typo_class,
            },
        }
    }

    fn subsequence(query_word: &str, doc_word_pos: usize, gaps: u8) -> Self {
        Self {
            query_weight: base_match_weight(query_word),
            query_len: query_word.chars().count(),
            state: WordMatchState::Subsequence { doc_word_pos, gaps },
        }
    }

    fn doc_word_pos(self) -> Option<usize> {
        match self.state {
            WordMatchState::Unmatched => None,
            WordMatchState::Exact { doc_word_pos }
            | WordMatchState::Prefix { doc_word_pos }
            | WordMatchState::Fuzzy { doc_word_pos, .. }
            | WordMatchState::Subsequence { doc_word_pos, .. } => Some(doc_word_pos),
        }
    }

    fn edit_distance(self) -> u8 {
        match self.state {
            WordMatchState::Unmatched
            | WordMatchState::Exact { .. }
            | WordMatchState::Prefix { .. } => 0,
            WordMatchState::Fuzzy { edit_dist, .. } => edit_dist,
            WordMatchState::Subsequence { gaps, .. } => gaps.saturating_add(1),
        }
    }

    fn typo_class(self) -> TypoClass {
        match self.state {
            WordMatchState::Unmatched
            | WordMatchState::Exact { .. }
            | WordMatchState::Prefix { .. } => TypoClass::None,
            WordMatchState::Fuzzy { typo_class, .. } => typo_class,
            WordMatchState::Subsequence { .. } => TypoClass::Subsequence,
        }
    }

    fn matched_weight(self) -> u16 {
        match self.state {
            WordMatchState::Unmatched => 0,
            WordMatchState::Exact { .. } | WordMatchState::Prefix { .. } => self.query_weight,
            WordMatchState::Fuzzy { typo_class, .. } => scaled_match_weight(
                self.query_weight,
                fuzzy_match_weight_multiplier(self.query_len, typo_class),
            ),
            WordMatchState::Subsequence { .. } => scaled_match_weight(
                self.query_weight,
                subsequence_match_weight_multiplier(self.query_len),
            ),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum TypoClass {
    None,
    CommonTransposition,
    RepeatedCharEdit,
    InsertionOrDeletion,
    Substitution,
    MultiEdit,
    Subsequence,
}

impl TypoClass {
    fn score(self) -> u8 {
        match self {
            Self::None => u8::MAX,
            Self::CommonTransposition => 240,
            Self::RepeatedCharEdit => 224,
            Self::InsertionOrDeletion => 208,
            Self::Substitution => 192,
            Self::MultiEdit => 160,
            Self::Subsequence => 96,
        }
    }
}

const MATCH_WEIGHT_SCALE: u16 = 256;
const TYPO_CLASS_WORST_CASE_SLACK: u8 = 64;
const COMMON_TRANSPOSITION_WEIGHT_MULTIPLIER: u16 = 224;
const REPEATED_CHAR_WEIGHT_MULTIPLIER: u16 = 208;
const INSERT_DELETE_WEIGHT_MULTIPLIER: u16 = 192;
const SUBSTITUTION_WEIGHT_MULTIPLIER: u16 = 176;
const MULTI_EDIT_WEIGHT_MULTIPLIER: u16 = 144;
const SHORT_QUERY_FUZZY_FLOOR_MULTIPLIER: u16 = 64;
const SUBSEQUENCE_WEIGHT_MULTIPLIER: u16 = 96;
const SHORT_QUERY_SUBSEQUENCE_MULTIPLIER: u16 = 48;

fn scaled_match_weight(base_weight: u16, multiplier: u16) -> u16 {
    if base_weight == 0 {
        return 0;
    }

    ((base_weight as u32 * multiplier as u32 + (MATCH_WEIGHT_SCALE as u32 / 2))
        / MATCH_WEIGHT_SCALE as u32)
        .max(1) as u16
}

fn fuzzy_match_weight_multiplier(query_len: usize, typo_class: TypoClass) -> u16 {
    let base_multiplier = match typo_class {
        TypoClass::None => MATCH_WEIGHT_SCALE,
        TypoClass::CommonTransposition => COMMON_TRANSPOSITION_WEIGHT_MULTIPLIER,
        TypoClass::RepeatedCharEdit => REPEATED_CHAR_WEIGHT_MULTIPLIER,
        TypoClass::InsertionOrDeletion => INSERT_DELETE_WEIGHT_MULTIPLIER,
        TypoClass::Substitution => SUBSTITUTION_WEIGHT_MULTIPLIER,
        TypoClass::MultiEdit => MULTI_EDIT_WEIGHT_MULTIPLIER,
        TypoClass::Subsequence => SUBSEQUENCE_WEIGHT_MULTIPLIER,
    };

    if query_len <= 3 {
        match typo_class {
            TypoClass::CommonTransposition => 96,
            TypoClass::RepeatedCharEdit => 80,
            TypoClass::InsertionOrDeletion => SHORT_QUERY_FUZZY_FLOOR_MULTIPLIER,
            TypoClass::Substitution => 48,
            TypoClass::MultiEdit | TypoClass::Subsequence => 32,
            TypoClass::None => MATCH_WEIGHT_SCALE,
        }
    } else {
        base_multiplier
    }
}

fn subsequence_match_weight_multiplier(query_len: usize) -> u16 {
    if query_len <= 4 {
        SHORT_QUERY_SUBSEQUENCE_MULTIPLIER
    } else {
        SUBSEQUENCE_WEIGHT_MULTIPLIER
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum ExactnessBand {
    FuzzyOnly = 0,
    MixedZeroCost = 1,
    AllZeroCost = 2,
    AllExact = 3,
    QuerySubstring = 4,
    AnchoredSequence = 5,
    ContentPrefix = 6,
}

impl ExactnessBand {
    fn score(self) -> u8 {
        self as u8
    }
}

#[derive(Debug, Clone, Copy, Default)]
struct ExactnessSignals {
    content_prefix: bool,
    anchored_sequence: bool,
    query_substring: bool,
    all_exact: bool,
    all_zero_cost: bool,
    any_zero_cost: bool,
}

impl ExactnessSignals {
    fn band(self) -> ExactnessBand {
        if self.content_prefix {
            ExactnessBand::ContentPrefix
        } else if self.anchored_sequence {
            ExactnessBand::AnchoredSequence
        } else if self.query_substring {
            ExactnessBand::QuerySubstring
        } else if self.all_exact {
            ExactnessBand::AllExact
        } else if self.all_zero_cost {
            ExactnessBand::AllZeroCost
        } else if self.any_zero_cost {
            ExactnessBand::MixedZeroCost
        } else {
            ExactnessBand::FuzzyOnly
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct QualitySignals {
    query_word_count: usize,
    total_query_weight: u16,
    words_matched_weight: u16,
    prefix_preference_score: u8,
    exactness: ExactnessSignals,
    proximity_score: u16,
    typo_class_score: u8,
    typo_score: u8,
    span_stats: Option<MatchSpanStats>,
}

impl QualitySignals {
    fn quality_tier(self) -> u8 {
        compute_quality_tier(
            self.query_word_count,
            self.total_query_weight,
            self.words_matched_weight,
            self.exactness,
            self.span_stats,
        )
    }

    fn quality_detail(self) -> u64 {
        compute_quality_detail(
            self.prefix_preference_score,
            self.words_matched_weight,
            self.typo_class_score,
            self.typo_score,
            compute_structure_detail(self.proximity_score, self.exactness, self.span_stats),
        )
    }
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
            recency_bucket: compute_recency_bucket(ctx.timestamp, ctx.now),
            quality_detail: 0,
            recency_score: compute_recency_score(ctx.timestamp, ctx.now),
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
    let signals = compute_bucket_quality_signals(
        ctx.content_lower,
        ctx.query_words,
        ctx.prefix_preference,
        &word_matches,
    );
    let bm25_quantized = quantize_bm25(ctx.bm25_score);
    let recency_bucket = compute_recency_bucket(ctx.timestamp, ctx.now);
    let recency_score = compute_recency_score(ctx.timestamp, ctx.now);

    BucketScore {
        quality_tier: signals.quality_tier(),
        recency_bucket,
        quality_detail: signals.quality_detail(),
        recency_score,
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
    let matched: Vec<&WordMatch> = word_matches
        .iter()
        .filter(|m| !matches!(m.state, WordMatchState::Unmatched))
        .collect();
    if matched.is_empty() {
        return None;
    }

    let min_pos = matched
        .iter()
        .filter_map(|m| m.doc_word_pos())
        .min()
        .unwrap_or(0);
    let max_pos = matched
        .iter()
        .filter_map(|m| m.doc_word_pos())
        .max()
        .unwrap_or(0);
    let span = max_pos.saturating_sub(min_pos) + 1;
    let all_matched = word_matches
        .iter()
        .all(|m| !matches!(m.state, WordMatchState::Unmatched));

    let mut prev_pos = None;
    let mut in_sequence = true;
    for wm in word_matches {
        let Some(doc_word_pos) = wm.doc_word_pos() else {
            continue;
        };
        if let Some(prev) = prev_pos {
            if doc_word_pos <= prev {
                in_sequence = false;
                break;
            }
        }
        prev_pos = Some(doc_word_pos);
    }

    Some(MatchSpanStats {
        matched_count: matched.len(),
        all_matched,
        in_sequence,
        span,
    })
}

fn compute_bucket_quality_signals(
    content_lower: &str,
    query_words: &[&str],
    prefix_preference: Option<PrefixPreferenceQuery<'_>>,
    word_matches: &[WordMatch],
) -> QualitySignals {
    let words_matched_weight: u16 = word_matches.iter().map(|m| m.matched_weight()).sum();
    let total_query_weight = query_total_match_weight(query_words);
    let prefix_preference_score = compute_prefix_preference_score(content_lower, prefix_preference);
    let exactness = compute_exactness_signals(content_lower, query_words, word_matches);
    let proximity_score = compute_proximity(word_matches);
    let typo_score = compute_typo_score(word_matches);
    let typo_class_score = compute_typo_class_score(word_matches);

    QualitySignals {
        query_word_count: query_words.len(),
        total_query_weight,
        words_matched_weight,
        prefix_preference_score,
        exactness,
        proximity_score,
        typo_class_score,
        typo_score,
        span_stats: compute_match_span_stats(word_matches),
    }
}

fn compute_alignment_quality_signals(
    word_matches: &[WordMatch],
    total_query_weight: u16,
) -> QualitySignals {
    let words_matched_weight: u16 = word_matches.iter().map(|m| m.matched_weight()).sum();

    QualitySignals {
        query_word_count: word_matches.len(),
        total_query_weight,
        words_matched_weight,
        prefix_preference_score: 0,
        exactness: alignment_exactness_signals(word_matches),
        proximity_score: compute_proximity(word_matches),
        typo_class_score: compute_typo_class_score(word_matches),
        typo_score: compute_typo_score(word_matches),
        span_stats: compute_match_span_stats(word_matches),
    }
}

fn compute_quality_tier(
    query_word_count: usize,
    total_query_weight: u16,
    words_matched_weight: u16,
    exactness: ExactnessSignals,
    span_stats: Option<MatchSpanStats>,
) -> u8 {
    if words_matched_weight == 0 {
        return 0;
    }

    if query_word_count < 2 {
        return 1;
    }

    let Some(stats) = span_stats else {
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

    if stats.all_matched && exactness.content_prefix {
        return 3;
    }
    if (coverage_pct >= 60 && dense_forward)
        || (exactness.band() >= ExactnessBand::QuerySubstring && compact_full_match)
    {
        return 2;
    }
    if coverage_pct >= 60 || stats.all_matched {
        return 1;
    }
    0
}

fn compute_structure_detail(
    proximity_score: u16,
    exactness: ExactnessSignals,
    span_stats: Option<MatchSpanStats>,
) -> u32 {
    let exactness_score = exactness.band().score();
    let Some(stats) = span_stats else {
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

    ((order_rank as u32) << 19)
        | ((density as u32) << 11)
        | ((proximity_quantized as u32) << 3)
        | exactness_score as u32
}

fn compute_quality_detail(
    prefix_preference_score: u8,
    words_matched_weight: u16,
    typo_class_score: u8,
    typo_score: u8,
    structure_detail: u32,
) -> u64 {
    ((prefix_preference_score as u64) << QUALITY_DETAIL_PREFIX_SHIFT)
        | ((words_matched_weight as u64) << QUALITY_DETAIL_COVERAGE_SHIFT)
        | ((structure_detail as u64) << QUALITY_DETAIL_STRUCTURE_SHIFT)
        | ((typo_class_score as u64) << QUALITY_DETAIL_TYPO_CLASS_SHIFT)
        | typo_score as u64
}

fn quality_detail_words_matched_weight(quality_detail: u64) -> u16 {
    ((quality_detail >> QUALITY_DETAIL_COVERAGE_SHIFT) & 0xFFFF) as u16
}

#[cfg(test)]
fn quality_detail_structure(quality_detail: u64) -> u32 {
    ((quality_detail >> QUALITY_DETAIL_STRUCTURE_SHIFT) & 0xFF_FFFF) as u32
}

#[cfg(test)]
fn quality_detail_typo_score(quality_detail: u64) -> u8 {
    quality_detail as u8
}

fn compute_typo_score(word_matches: &[WordMatch]) -> u8 {
    let total_edit_dist: u8 = word_matches
        .iter()
        .filter(|m| !matches!(m.state, WordMatchState::Unmatched))
        .map(|m| m.edit_distance())
        .sum();
    255u8.saturating_sub(total_edit_dist)
}

fn compute_typo_class_score(word_matches: &[WordMatch]) -> u8 {
    let mut total_weight = 0u32;
    let mut weighted_sum = 0u32;
    let mut worst: Option<u8> = None;

    for word_match in word_matches
        .iter()
        .filter(|m| !matches!(m.state, WordMatchState::Unmatched))
    {
        let weight = word_match.query_weight.max(1) as u32;
        let score = word_match.typo_class().score();
        total_weight += weight;
        weighted_sum += weight * score as u32;
        worst = Some(match worst {
            Some(current) => current.min(score),
            None => score,
        });
    }

    let Some(worst_score) = worst else {
        return 0;
    };
    let weighted_avg = if total_weight == 0 {
        worst_score
    } else {
        (weighted_sum / total_weight) as u8
    };
    weighted_avg.min(worst_score.saturating_add(TYPO_CLASS_WORST_CASE_SLACK))
}

/// Coarse human-scale recency bands.
///
/// This sits before `quality_detail` in the tuple so quality can win within a
/// modest age band, while genuinely old-vs-recent gaps still defer to recency.
fn compute_recency_bucket(timestamp: i64, now: i64) -> u8 {
    let age_secs = (now - timestamp).max(0);
    match age_secs {
        0..=RECENCY_BUCKET_LAST_HOUR_MAX_AGE_SECS => RECENCY_BUCKET_LAST_HOUR,
        RECENCY_BUCKET_LAST_DAY_MIN_AGE_SECS..=RECENCY_BUCKET_LAST_DAY_MAX_AGE_SECS => {
            RECENCY_BUCKET_LAST_DAY
        }
        RECENCY_BUCKET_LAST_WEEK_MIN_AGE_SECS..=RECENCY_BUCKET_LAST_WEEK_MAX_AGE_SECS => {
            RECENCY_BUCKET_LAST_WEEK
        }
        RECENCY_BUCKET_LAST_MONTH_MIN_AGE_SECS..=RECENCY_BUCKET_LAST_MONTH_MAX_AGE_SECS => {
            RECENCY_BUCKET_LAST_MONTH
        }
        RECENCY_BUCKET_LAST_QUARTER_MIN_AGE_SECS..=RECENCY_BUCKET_LAST_QUARTER_MAX_AGE_SECS => {
            RECENCY_BUCKET_LAST_QUARTER
        }
        _ => RECENCY_BUCKET_STALE,
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
        .map(|qw| WordMatch::unmatched(qw))
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
                WordMatchKind::Exact => Some(WordMatch::exact(query_word, dpos)),
                WordMatchKind::Prefix => Some(WordMatch::prefix(query_word, dpos)),
                WordMatchKind::Fuzzy(dist) => Some(WordMatch::fuzzy(
                    query_word,
                    dpos,
                    dist,
                    classify_fuzzy_typo(&qw_lower, dw, dist),
                )),
                WordMatchKind::Subsequence(gaps) => {
                    Some(WordMatch::subsequence(query_word, dpos, gaps))
                }
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
    by_pos.sort_by_key(|c| c.doc_word_pos().unwrap_or(usize::MAX));

    let mut chosen = Vec::new();
    let mut seen_positions = HashSet::new();

    for cand in by_quality.iter().take(4) {
        if let Some(doc_word_pos) = cand.doc_word_pos() {
            if seen_positions.insert(doc_word_pos) {
                chosen.push(*cand);
            }
        }
    }
    for cand in by_pos.iter().take(2).chain(by_pos.iter().rev().take(2)) {
        if let Some(doc_word_pos) = cand.doc_word_pos() {
            if seen_positions.insert(doc_word_pos) {
                chosen.push(*cand);
            }
        }
    }
    for cand in by_quality {
        if chosen.len() >= MAX_CANDIDATES_PER_QUERY_WORD {
            break;
        }
        if let Some(doc_word_pos) = cand.doc_word_pos() {
            if seen_positions.insert(doc_word_pos) {
                chosen.push(cand);
            }
        }
    }

    chosen
}

#[derive(Debug, Clone, Copy)]
struct IndexedCandidate {
    position_mask: u64,
    word_match: WordMatch,
}

fn build_indexed_candidate_lists(
    candidate_lists: &[Vec<WordMatch>],
) -> Option<Vec<Vec<IndexedCandidate>>> {
    let mut unique_positions = Vec::new();
    for candidate in candidate_lists.iter().flatten() {
        let Some(doc_word_pos) = candidate.doc_word_pos() else {
            continue;
        };
        if !unique_positions.contains(&doc_word_pos) {
            unique_positions.push(doc_word_pos);
        }
    }

    if unique_positions.len() > u64::BITS as usize {
        return None;
    }

    Some(
        candidate_lists
            .iter()
            .map(|candidates| {
                candidates
                    .iter()
                    .filter_map(|candidate| {
                        let doc_word_pos = candidate.doc_word_pos()?;
                        let bit_idx = unique_positions
                            .iter()
                            .position(|pos| *pos == doc_word_pos)?;
                        Some(IndexedCandidate {
                            position_mask: 1u64 << bit_idx,
                            word_match: *candidate,
                        })
                    })
                    .collect()
            })
            .collect(),
    )
}

fn choose_best_alignment(
    candidate_lists: &[Vec<WordMatch>],
    defaults: &[WordMatch],
) -> Vec<WordMatch> {
    let total_query_weight: u16 = defaults.iter().map(|m| m.query_weight).sum();
    let mut current = defaults.to_vec();
    let mut best = defaults.to_vec();
    let mut best_score = score_alignment(&best, total_query_weight);

    if let Some(indexed_candidate_lists) = build_indexed_candidate_lists(candidate_lists) {
        choose_best_alignment_recursive_indexed(
            0,
            &indexed_candidate_lists,
            defaults,
            total_query_weight,
            0,
            &mut current,
            &mut best,
            &mut best_score,
        );
        return best;
    }

    let mut used_positions = HashSet::new();
    choose_best_alignment_recursive_fallback(
        0,
        candidate_lists,
        defaults,
        total_query_weight,
        &mut used_positions,
        &mut current,
        &mut best,
        &mut best_score,
    );

    best
}

fn choose_best_alignment_recursive_indexed(
    qi: usize,
    candidate_lists: &[Vec<IndexedCandidate>],
    defaults: &[WordMatch],
    total_query_weight: u16,
    used_positions_mask: u64,
    current: &mut [WordMatch],
    best: &mut Vec<WordMatch>,
    best_score: &mut AlignmentScore,
) {
    if qi == candidate_lists.len() {
        let score = score_alignment(current, total_query_weight);
        if score > *best_score {
            *best_score = score;
            *best = current.to_vec();
        }
        return;
    }

    current[qi] = defaults[qi];
    choose_best_alignment_recursive_indexed(
        qi + 1,
        candidate_lists,
        defaults,
        total_query_weight,
        used_positions_mask,
        current,
        best,
        best_score,
    );

    for candidate in &candidate_lists[qi] {
        if used_positions_mask & candidate.position_mask != 0 {
            continue;
        }
        current[qi] = candidate.word_match;
        choose_best_alignment_recursive_indexed(
            qi + 1,
            candidate_lists,
            defaults,
            total_query_weight,
            used_positions_mask | candidate.position_mask,
            current,
            best,
            best_score,
        );
    }
}

fn choose_best_alignment_recursive_fallback(
    qi: usize,
    candidate_lists: &[Vec<WordMatch>],
    defaults: &[WordMatch],
    total_query_weight: u16,
    used_positions: &mut HashSet<usize>,
    current: &mut [WordMatch],
    best: &mut Vec<WordMatch>,
    best_score: &mut AlignmentScore,
) {
    if qi == candidate_lists.len() {
        let score = score_alignment(current, total_query_weight);
        if score > *best_score {
            *best_score = score;
            *best = current.to_vec();
        }
        return;
    }

    current[qi] = defaults[qi];
    choose_best_alignment_recursive_fallback(
        qi + 1,
        candidate_lists,
        defaults,
        total_query_weight,
        used_positions,
        current,
        best,
        best_score,
    );

    for candidate in &candidate_lists[qi] {
        let Some(doc_word_pos) = candidate.doc_word_pos() else {
            continue;
        };
        if !used_positions.insert(doc_word_pos) {
            continue;
        }
        current[qi] = *candidate;
        choose_best_alignment_recursive_fallback(
            qi + 1,
            candidate_lists,
            defaults,
            total_query_weight,
            used_positions,
            current,
            best,
            best_score,
        );
        used_positions.remove(&doc_word_pos);
    }
}

fn candidate_quality_cmp(a: &WordMatch, b: &WordMatch) -> std::cmp::Ordering {
    candidate_quality_key(b).cmp(&candidate_quality_key(a))
}

fn candidate_quality_key(m: &WordMatch) -> (u8, u16, u8, u8, std::cmp::Reverse<usize>) {
    let kind_rank = match m.state {
        WordMatchState::Exact { .. } => 4,
        WordMatchState::Prefix { .. } => 3,
        WordMatchState::Fuzzy { .. } => 2,
        WordMatchState::Subsequence { .. } => 1,
        WordMatchState::Unmatched => 0,
    };
    (
        kind_rank,
        m.matched_weight(),
        m.typo_class().score(),
        255u8.saturating_sub(m.edit_distance()),
        std::cmp::Reverse(m.doc_word_pos().unwrap_or(usize::MAX)),
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct AlignmentScore {
    quality_tier: u8,
    quality_detail: u64,
    matched_query_mask: u64,
}

fn score_alignment(word_matches: &[WordMatch], total_query_weight: u16) -> AlignmentScore {
    let signals = compute_alignment_quality_signals(word_matches, total_query_weight);

    AlignmentScore {
        quality_tier: signals.quality_tier(),
        quality_detail: signals.quality_detail(),
        matched_query_mask: alignment_matched_query_mask(word_matches),
    }
}

fn alignment_matched_query_mask(word_matches: &[WordMatch]) -> u64 {
    word_matches.iter().enumerate().fold(0u64, |mask, (i, wm)| {
        if !matches!(wm.state, WordMatchState::Unmatched) {
            mask | (1u64 << (63usize.saturating_sub(i)))
        } else {
            mask
        }
    })
}

fn alignment_exactness_signals(word_matches: &[WordMatch]) -> ExactnessSignals {
    let matched_count = word_matches
        .iter()
        .filter(|m| !matches!(m.state, WordMatchState::Unmatched))
        .count();
    if matched_count < 2 {
        return ExactnessSignals::default();
    }

    let all_matched = word_matches
        .iter()
        .all(|m| !matches!(m.state, WordMatchState::Unmatched));
    if all_matched {
        let in_sequence =
            word_matches
                .windows(2)
                .all(|w| match (w[0].doc_word_pos(), w[1].doc_word_pos()) {
                    (Some(left), Some(right)) => right > left,
                    _ => false,
                });
        if in_sequence {
            let contiguous =
                word_matches
                    .windows(2)
                    .all(|w| match (w[0].doc_word_pos(), w[1].doc_word_pos()) {
                        (Some(left), Some(right)) => right == left + 1,
                        _ => false,
                    });
            if contiguous {
                return ExactnessSignals {
                    query_substring: true,
                    ..alignment_zero_cost_signals(word_matches)
                };
            }
            return ExactnessSignals {
                all_zero_cost: word_matches.iter().all(|m| m.edit_distance() == 0),
                any_zero_cost: word_matches.iter().any(|m| m.edit_distance() == 0),
                all_exact: word_matches
                    .iter()
                    .all(|m| matches!(m.state, WordMatchState::Exact { .. })),
                ..ExactnessSignals::default()
            };
        }
    }

    alignment_zero_cost_signals(word_matches)
}

fn alignment_zero_cost_signals(word_matches: &[WordMatch]) -> ExactnessSignals {
    ExactnessSignals {
        all_exact: word_matches
            .iter()
            .filter(|m| !matches!(m.state, WordMatchState::Unmatched))
            .all(|m| matches!(m.state, WordMatchState::Exact { .. })),
        all_zero_cost: word_matches
            .iter()
            .filter(|m| !matches!(m.state, WordMatchState::Unmatched))
            .all(|m| m.edit_distance() == 0),
        any_zero_cost: word_matches
            .iter()
            .filter(|m| !matches!(m.state, WordMatchState::Unmatched))
            .any(|m| m.edit_distance() == 0),
        ..ExactnessSignals::default()
    }
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

fn classify_fuzzy_typo(query: &str, target: &str, dist: u8) -> TypoClass {
    if is_adjacent_transposition(query, target) {
        return TypoClass::CommonTransposition;
    }

    if dist == 1 {
        if let Some(is_repeated_char) = classify_single_insert_delete(query, target) {
            return if is_repeated_char {
                TypoClass::RepeatedCharEdit
            } else {
                TypoClass::InsertionOrDeletion
            };
        }
        return TypoClass::Substitution;
    }

    TypoClass::MultiEdit
}

fn is_adjacent_transposition(a: &str, b: &str) -> bool {
    let a_chars: Vec<char> = a.chars().collect();
    let b_chars: Vec<char> = b.chars().collect();
    if a_chars.len() != b_chars.len() || a_chars.len() < 2 {
        return false;
    }

    let mut first_diff = None;
    for i in 0..a_chars.len() {
        if a_chars[i] != b_chars[i] {
            first_diff = Some(i);
            break;
        }
    }
    let Some(i) = first_diff else {
        return false;
    };
    if i + 1 >= a_chars.len() {
        return false;
    }

    if a_chars[i] != b_chars[i + 1] || a_chars[i + 1] != b_chars[i] {
        return false;
    }

    for j in (i + 2)..a_chars.len() {
        if a_chars[j] != b_chars[j] {
            return false;
        }
    }

    true
}

/// Returns whether the edit is a repeated-char insertion/deletion when the strings
/// differ by a single inserted or deleted character. `None` means it is not a
/// one-char insertion/deletion relationship.
fn classify_single_insert_delete(shorter: &str, longer: &str) -> Option<bool> {
    let shorter_chars: Vec<char> = shorter.chars().collect();
    let longer_chars: Vec<char> = longer.chars().collect();
    let (shorter_chars, longer_chars) = if shorter_chars.len() <= longer_chars.len() {
        (shorter_chars, longer_chars)
    } else {
        (longer_chars, shorter_chars)
    };

    if longer_chars.len() != shorter_chars.len() + 1 {
        return None;
    }

    let mut si = 0usize;
    let mut li = 0usize;
    let mut skipped_idx = None;

    while si < shorter_chars.len() && li < longer_chars.len() {
        if shorter_chars[si] == longer_chars[li] {
            si += 1;
            li += 1;
            continue;
        }

        if skipped_idx.is_some() {
            return None;
        }

        skipped_idx = Some(li);
        li += 1;
    }

    let skipped_idx = skipped_idx.unwrap_or(longer_chars.len() - 1);
    let skipped_char = longer_chars[skipped_idx];
    let repeated_prev = skipped_idx > 0 && longer_chars[skipped_idx - 1] == skipped_char;
    let repeated_next =
        skipped_idx + 1 < longer_chars.len() && longer_chars[skipped_idx + 1] == skipped_char;

    Some(repeated_prev || repeated_next)
}

/// Compute proximity score from matched word positions.
fn compute_proximity(word_matches: &[WordMatch]) -> u16 {
    let matched: Vec<&WordMatch> = word_matches
        .iter()
        .filter(|m| !matches!(m.state, WordMatchState::Unmatched))
        .collect();
    if matched.len() < 2 {
        return u16::MAX;
    }

    let mut total_distance: u32 = 0;
    let mut prev_matched: Option<usize> = None;

    for wm in word_matches {
        if let Some(doc_word_pos) = wm.doc_word_pos() {
            if let Some(prev_pos) = prev_matched {
                if doc_word_pos > prev_pos {
                    total_distance += (doc_word_pos - prev_pos) as u32;
                } else {
                    total_distance += (prev_pos - doc_word_pos) as u32 + 5;
                }
            }
            prev_matched = Some(doc_word_pos);
        }
    }

    u16::MAX.saturating_sub(total_distance.min(u16::MAX as u32) as u16)
}

/// Compute explicit exactness signals for the matched query terms.
fn compute_exactness_signals(
    content_lower: &str,
    query_words: &[&str],
    word_matches: &[WordMatch],
) -> ExactnessSignals {
    let matched: Vec<&WordMatch> = word_matches
        .iter()
        .filter(|m| !matches!(m.state, WordMatchState::Unmatched))
        .collect();
    if matched.is_empty() {
        return ExactnessSignals::default();
    }

    let full_query = if !query_words.is_empty() {
        query_words.join(" ").to_lowercase()
    } else {
        String::new()
    };

    let all_matched = word_matches
        .iter()
        .all(|m| !matches!(m.state, WordMatchState::Unmatched));
    let content_prefix = !full_query.is_empty() && content_lower.starts_with(&full_query);
    let query_substring = !full_query.is_empty() && content_lower.contains(&full_query);
    let all_exact = matched
        .iter()
        .all(|m| matches!(m.state, WordMatchState::Exact { .. }));
    let all_zero_cost = matched.iter().all(|m| m.edit_distance() == 0);
    let any_zero_cost = matched.iter().any(|m| m.edit_distance() == 0);

    let anchored_sequence = if all_matched && word_matches.len() > 1 {
        match word_matches[0].state {
            WordMatchState::Exact { doc_word_pos } | WordMatchState::Prefix { doc_word_pos }
                if doc_word_pos == 0 =>
            {
                word_matches
                    .windows(2)
                    .all(|w| match (w[0].doc_word_pos(), w[1].doc_word_pos()) {
                        (Some(left), Some(right)) => right > left,
                        _ => false,
                    })
            }
            _ => false,
        }
    } else {
        false
    };

    ExactnessSignals {
        content_prefix,
        anchored_sequence,
        query_substring,
        all_exact,
        all_zero_cost,
        any_zero_cost,
    }
}

/// Compute exactness score (0-6 scale) from explicit exactness signals.
fn compute_exactness(content_lower: &str, query_words: &[&str], word_matches: &[WordMatch]) -> u8 {
    compute_exactness_signals(content_lower, query_words, word_matches)
        .band()
        .score()
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

    fn wm_unmatched(query_word: &str) -> WordMatch {
        WordMatch::unmatched(query_word)
    }

    fn wm_exact(query_word: &str, doc_word_pos: usize) -> WordMatch {
        WordMatch::exact(query_word, doc_word_pos)
    }

    fn wm_prefix(query_word: &str, doc_word_pos: usize) -> WordMatch {
        WordMatch::prefix(query_word, doc_word_pos)
    }

    fn wm_fuzzy(
        query_word: &str,
        doc_word_pos: usize,
        edit_dist: u8,
        typo_class: TypoClass,
    ) -> WordMatch {
        WordMatch::fuzzy(query_word, doc_word_pos, edit_dist, typo_class)
    }

    fn wm_subsequence(query_word: &str, doc_word_pos: usize, gaps: u8) -> WordMatch {
        WordMatch::subsequence(query_word, doc_word_pos, gaps)
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
        assert!(matches!(matches[0].state, WordMatchState::Exact { .. }));
        assert_eq!(matches[0].edit_distance(), 0);
    }

    #[test]
    fn test_match_prefix_last_word() {
        let doc_words = vec!["clipkitty"];
        let matches = match_query_words(&["cl"], &doc_words, true, false);
        assert_eq!(matches.len(), 1);
        assert!(matches!(matches[0].state, WordMatchState::Prefix { .. }));
        assert_eq!(matches[0].edit_distance(), 0);
    }

    #[test]
    fn test_match_prefix_not_allowed_non_last() {
        let doc_words = vec!["clipkitty"];
        let matches = match_query_words(&["cl", "hello"], &doc_words, true, false);
        assert!(matches!(matches[0].state, WordMatchState::Unmatched));
    }

    #[test]
    fn test_match_fuzzy() {
        let doc_words = vec!["riverside", "park"];
        let matches = match_query_words(&["riversde"], &doc_words, false, false);
        assert!(matches!(matches[0].state, WordMatchState::Fuzzy { .. }));
        assert_eq!(matches[0].edit_distance(), 1);
    }

    #[test]
    fn test_match_fuzzy_short_word() {
        // "helo" (4 chars) matches "hello" via fuzzy (edit distance 1)
        let doc_words = vec!["hello"];
        let matches = match_query_words(&["helo"], &doc_words, false, false);
        assert!(matches!(matches[0].state, WordMatchState::Fuzzy { .. }));
        assert_eq!(matches[0].edit_distance(), 1);
    }

    #[test]
    fn test_match_transposition_short_word() {
        // "teh" (3 chars) matches "the" via fuzzy (transposition = 1 edit)
        let doc_words = vec!["the", "quick"];
        let matches = match_query_words(&["teh"], &doc_words, false, false);
        assert!(matches!(matches[0].state, WordMatchState::Fuzzy { .. }));
        assert_eq!(matches[0].edit_distance(), 1);
    }

    #[test]
    fn test_match_multi_word() {
        let doc_words = vec!["hello", "beautiful", "world"];
        let matches = match_query_words(&["hello", "world"], &doc_words, false, false);
        assert!(!matches!(matches[0].state, WordMatchState::Unmatched));
        assert!(!matches!(matches[1].state, WordMatchState::Unmatched));
        assert_eq!(matches[0].doc_word_pos(), Some(0));
        assert_eq!(matches[1].doc_word_pos(), Some(2));
    }

    #[test]
    fn test_match_repeated_query_words_require_distinct_doc_occurrences() {
        let doc_words = vec!["hello", "world"];
        let matches = match_query_words(&["hello", "hello"], &doc_words, false, false);
        assert!(!matches!(matches[0].state, WordMatchState::Unmatched));
        assert!(
            matches!(matches[1].state, WordMatchState::Unmatched),
            "A repeated query token should not reuse the same document token"
        );
    }

    #[test]
    fn test_match_prefers_best_global_alignment_over_earliest_exact_occurrences() {
        let doc_words = vec!["alpha", "noise", "noise", "noise", "beta", "alpha", "beta"];
        let matches = match_query_words(&["alpha", "beta"], &doc_words, false, false);
        assert_eq!(
            matches[0].doc_word_pos(),
            Some(5),
            "Should use the tighter trailing cluster"
        );
        assert_eq!(
            matches[1].doc_word_pos(),
            Some(6),
            "Should use the tighter trailing cluster"
        );
    }

    // ── compute_proximity tests ──────────────────────────────────

    #[test]
    fn test_proximity_adjacent() {
        let matches = vec![wm_exact("hello", 0), wm_exact("world", 1)];
        assert_eq!(compute_proximity(&matches), u16::MAX - 1);
    }

    #[test]
    fn test_proximity_gap() {
        let matches = vec![wm_exact("hello", 0), wm_exact("world", 5)];
        assert_eq!(compute_proximity(&matches), u16::MAX - 5);
    }

    #[test]
    fn test_proximity_single_word() {
        let matches = vec![wm_exact("hello", 3)];
        assert_eq!(compute_proximity(&matches), u16::MAX);
    }

    #[test]
    fn test_proximity_unmatched_words_skipped() {
        let matches = vec![
            wm_exact("hello", 0),
            wm_unmatched("skip"),
            wm_exact("world", 3),
        ];
        assert_eq!(compute_proximity(&matches), u16::MAX - 3);
    }

    #[test]
    fn test_quality_tier_prefers_dense_matches() {
        let dense = vec![wm_exact("hello", 0), wm_exact("world", 1)];
        let scattered = vec![
            wm_exact("hello", 0),
            wm_exact("world", 8),
            wm_exact("today", 16),
        ];

        let exact_signals = ExactnessSignals {
            all_exact: true,
            all_zero_cost: true,
            any_zero_cost: true,
            ..ExactnessSignals::default()
        };
        let dense_tier =
            compute_quality_tier(2, 75, 50, exact_signals, compute_match_span_stats(&dense));
        let scattered_tier = compute_quality_tier(
            3,
            75,
            75,
            exact_signals,
            compute_match_span_stats(&scattered),
        );
        assert!(dense_tier > scattered_tier);
    }

    // ── compute_exactness tests ──────────────────────────────────

    #[test]
    fn test_exactness_full_substring() {
        // "hello world" starts with "hello world" → level 6
        let matches = vec![wm_exact("hello", 0), wm_exact("world", 1)];
        assert_eq!(
            compute_exactness("hello world", &["hello", "world"], &matches),
            6
        );
    }

    #[test]
    fn test_exactness_all_exact_but_not_substring() {
        // first word at pos 0, forward sequence → level 5
        let matches = vec![wm_exact("hello", 0), wm_exact("world", 2)];
        assert_eq!(
            compute_exactness("hello beautiful world", &["hello", "world"], &matches),
            5
        );
    }

    #[test]
    fn test_exactness_mix_exact_fuzzy() {
        // first word at pos 0 exact, second fuzzy in forward sequence → level 5
        let matches = vec![
            wm_exact("hello", 0),
            wm_fuzzy("world", 1, 1, TypoClass::Substitution),
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
        let matches = vec![wm_prefix("hel", 0), wm_prefix("wor", 1)];
        assert_eq!(
            compute_exactness("hello world", &["hel", "wor"], &matches),
            5
        );
    }

    #[test]
    fn test_exactness_prefix_beats_fuzzy() {
        // Prefix (level 2) should rank above all-fuzzy (level 0)
        let prefix = vec![wm_prefix("hel", 0), wm_prefix("wor", 1)];
        let fuzzy = vec![wm_fuzzy("hello", 0, 1, TypoClass::Substitution)];
        assert!(
            compute_exactness("hello world", &["hel", "wor"], &prefix)
                > compute_exactness("hallo", &["hello"], &fuzzy)
        );
    }

    #[test]
    fn test_exactness_all_fuzzy() {
        let matches = vec![wm_fuzzy("hello", 0, 1, TypoClass::Substitution)];
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

    #[test]
    fn test_recency_bucket_boundaries() {
        let now = 1700000000i64;

        assert_eq!(compute_recency_bucket(now, now), RECENCY_BUCKET_LAST_HOUR);
        assert_eq!(
            compute_recency_bucket(now - RECENCY_BUCKET_LAST_HOUR_MAX_AGE_SECS, now),
            RECENCY_BUCKET_LAST_HOUR
        );
        assert_eq!(
            compute_recency_bucket(now - (RECENCY_BUCKET_LAST_HOUR_MAX_AGE_SECS + 1), now),
            RECENCY_BUCKET_LAST_DAY
        );
        assert_eq!(
            compute_recency_bucket(now - RECENCY_BUCKET_LAST_DAY_MAX_AGE_SECS, now),
            RECENCY_BUCKET_LAST_DAY
        );
        assert_eq!(
            compute_recency_bucket(now - (RECENCY_BUCKET_LAST_DAY_MAX_AGE_SECS + 1), now),
            RECENCY_BUCKET_LAST_WEEK
        );
        assert_eq!(
            compute_recency_bucket(now - RECENCY_BUCKET_LAST_WEEK_MAX_AGE_SECS, now),
            RECENCY_BUCKET_LAST_WEEK
        );
        assert_eq!(
            compute_recency_bucket(now - (RECENCY_BUCKET_LAST_WEEK_MAX_AGE_SECS + 1), now),
            RECENCY_BUCKET_LAST_MONTH
        );
        assert_eq!(
            compute_recency_bucket(now - RECENCY_BUCKET_LAST_MONTH_MAX_AGE_SECS, now),
            RECENCY_BUCKET_LAST_MONTH
        );
        assert_eq!(
            compute_recency_bucket(now - (RECENCY_BUCKET_LAST_MONTH_MAX_AGE_SECS + 1), now),
            RECENCY_BUCKET_LAST_QUARTER
        );
        assert_eq!(
            compute_recency_bucket(now - RECENCY_BUCKET_LAST_QUARTER_MAX_AGE_SECS, now),
            RECENCY_BUCKET_LAST_QUARTER
        );
        assert_eq!(
            compute_recency_bucket(now - (RECENCY_BUCKET_LAST_QUARTER_MAX_AGE_SECS + 1), now),
            RECENCY_BUCKET_STALE
        );
    }

    #[test]
    fn test_typo_class_score_uses_weighted_average_with_worst_case_clamp() {
        let mixed = vec![
            wm_exact("encyclopedia", 0),
            wm_subsequence("hello", 3, 2),
            wm_exact("documentation", 5),
        ];

        assert_eq!(
            compute_typo_class_score(&mixed),
            TypoClass::Subsequence
                .score()
                .saturating_add(TYPO_CLASS_WORST_CASE_SLACK)
        );
    }

    #[test]
    fn test_common_transposition_keeps_more_match_weight_than_substitution() {
        let transposition = wm_fuzzy("teh", 0, 1, TypoClass::CommonTransposition);
        let substitution = wm_fuzzy("teh", 0, 1, TypoClass::Substitution);

        assert!(transposition.matched_weight() > substitution.matched_weight());
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
        let newer_word_prefix = score(
            "say claude notes",
            &["cla"],
            true,
            None,
            now - 180,
            1.0,
            now,
        );
        assert!(
            older_content_prefix > newer_word_prefix,
            "Across a moderate age gap, content-prefix should beat a newer non-initial word-prefix match"
        );
    }

    #[test]
    fn test_recent_word_prefix_beats_ancient_content_prefix() {
        let now = 1700000000i64;
        let ancient_content_prefix = score(
            "claude notes",
            &["cla"],
            true,
            None,
            now - 60 * 86400,
            1.0,
            now,
        );
        let recent_word_prefix = score(
            "say claude notes",
            &["cla"],
            true,
            None,
            now - 600,
            1.0,
            now,
        );
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
        let forward = vec![wm_exact("hello", 0), wm_exact("world", 2)];
        // Reverse order: distance = (0 - 2) + 5 penalty = 7
        let reversed = vec![wm_exact("hello", 2), wm_exact("world", 0)];
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
        let matches = vec![wm_exact("hello", 0), wm_prefix("wo", 1)];
        assert_eq!(
            compute_exactness("hello world foo", &["hello", "wo"], &matches),
            6
        );
    }

    #[test]
    fn test_exactness_prefix_of_content_single_word() {
        // "hel" is a prefix of "hello world" → level 6
        let matches = vec![wm_prefix("hel", 0)];
        assert_eq!(compute_exactness("hello world", &["hel"], &matches), 6);
    }

    #[test]
    fn test_exactness_first_word_anchored_sequence() {
        // first word exact at pos 0, second fuzzy at pos 1 → level 5
        let matches = vec![
            wm_exact("hello", 0),
            wm_fuzzy("world", 1, 1, TypoClass::CommonTransposition),
        ];
        assert_eq!(
            compute_exactness("hello wrold foo", &["hello", "world"], &matches),
            5
        );
    }

    #[test]
    fn test_exactness_first_word_not_at_start() {
        // first word matches but not at pos 0 → falls through to lower level
        let matches = vec![wm_exact("hello", 1), wm_exact("world", 2)];
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
            wm_exact("hello", 0),
            wm_exact("beautiful", 2),
            wm_exact("world", 1),
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
