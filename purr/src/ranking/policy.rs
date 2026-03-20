use super::{ExactnessSignals, MatchSpanStats};

/// Documents larger than this threshold use fast matching (exact + prefix only).
/// This trades typo tolerance for performance on large documents like code files.
pub const LARGE_DOC_THRESHOLD_BYTES: usize = 5 * 1024; // 5KB

/// Bucket score tuple. Higher fields dominate lower ones.
///
/// The field order here is the ranking policy:
/// 1. foundational match quality
/// 2. coarse recency band
/// 3. detailed tie-break quality
/// 4. smooth recency decay
/// 5. BM25 tie-break
/// 6. raw timestamp
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct BucketScore {
    pub quality_tier: QualityTier,
    pub recency_bucket: RecencyBucket,
    pub quality_detail: QualityDetail,
    pub recency_score: u8,
    pub bm25_quantized: u16,
    pub recency: i64,
}

impl BucketScore {
    pub fn words_matched_weight(&self) -> u16 {
        self.quality_detail.words_matched_weight
    }
}

/// Coarse, foundational quality levels that should be readable at a glance.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub enum QualityTier {
    #[default]
    NoMatch = 0,
    Basic = 1,
    Dense = 2,
    ContentPrefix = 3,
}

/// Human-scale age bands used ahead of fine-grained ranking detail.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub enum RecencyBucket {
    #[default]
    Stale = 0,
    LastQuarter = 1,
    LastMonth = 2,
    LastWeek = 3,
    LastDay = 4,
    LastHour = 5,
}

/// Fine-grained ranking detail used only after `quality_tier` and `recency_bucket`.
///
/// The field order here is still the ranking policy, but each field now has a
/// named type instead of being packed into an integer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub struct QualityDetail {
    pub prefix_preference_score: u8,
    pub match_class_score: u8,
    pub words_matched_weight: u16,
    pub structure_detail: StructureDetail,
    pub typo_score: u8,
}

/// Prefix preference state carried from the `^query` mode.
#[derive(Debug, Clone, Copy)]
pub struct PrefixPreferenceQuery<'a> {
    pub raw_query_lower: &'a str,
    pub stripped_query_lower: &'a str,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub struct StructureDetail {
    order_rank: MatchOrderRank,
    density_score: u8,
    proximity_score: u8,
    exactness_band: ExactnessBand,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub enum MatchOrderRank {
    #[default]
    None = 0,
    Forward = 1,
    Contiguous = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub(crate) enum ExactnessBand {
    #[default]
    FuzzyOnly = 0,
    MixedZeroCost = 1,
    AllZeroCost = 2,
    AllExact = 3,
    QuerySubstring = 4,
    AnchoredSequence = 5,
    ContentPrefix = 6,
}

impl ExactnessBand {
    #[cfg(test)]
    pub(crate) fn score(self) -> u8 {
        self as u8
    }
}

impl ExactnessSignals {
    pub(crate) fn band(self) -> ExactnessBand {
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

const RECENCY_BUCKET_LAST_HOUR_MAX_AGE_SECS: i64 = 3600;
const RECENCY_BUCKET_LAST_DAY_MAX_AGE_SECS: i64 = 86_400;
const RECENCY_BUCKET_LAST_WEEK_MAX_AGE_SECS: i64 = 7 * RECENCY_BUCKET_LAST_DAY_MAX_AGE_SECS;
const RECENCY_BUCKET_LAST_MONTH_MAX_AGE_SECS: i64 = 30 * RECENCY_BUCKET_LAST_DAY_MAX_AGE_SECS;
const RECENCY_BUCKET_LAST_QUARTER_MAX_AGE_SECS: i64 = 90 * RECENCY_BUCKET_LAST_DAY_MAX_AGE_SECS;
const RECENCY_BUCKET_LAST_DAY_MIN_AGE_SECS: i64 = RECENCY_BUCKET_LAST_HOUR_MAX_AGE_SECS + 1;
const RECENCY_BUCKET_LAST_WEEK_MIN_AGE_SECS: i64 = RECENCY_BUCKET_LAST_DAY_MAX_AGE_SECS + 1;
const RECENCY_BUCKET_LAST_MONTH_MIN_AGE_SECS: i64 = RECENCY_BUCKET_LAST_WEEK_MAX_AGE_SECS + 1;
const RECENCY_BUCKET_LAST_QUARTER_MIN_AGE_SECS: i64 = RECENCY_BUCKET_LAST_MONTH_MAX_AGE_SECS + 1;

pub(super) fn compute_quality_tier(
    query_word_count: usize,
    total_query_weight: u16,
    words_matched_weight: u16,
    exactness: ExactnessSignals,
    span_stats: Option<MatchSpanStats>,
) -> QualityTier {
    if words_matched_weight == 0 {
        return QualityTier::NoMatch;
    }

    if query_word_count < 2 {
        return QualityTier::Basic;
    }

    let Some(stats) = span_stats else {
        return QualityTier::NoMatch;
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
        return QualityTier::ContentPrefix;
    }
    if (coverage_pct >= 60 && dense_forward)
        || (exactness.band() >= ExactnessBand::QuerySubstring && compact_full_match)
    {
        return QualityTier::Dense;
    }
    if coverage_pct >= 60 || stats.all_matched {
        return QualityTier::Basic;
    }
    QualityTier::NoMatch
}

pub(super) fn compute_structure_detail(
    proximity_score: u16,
    exactness: ExactnessSignals,
    span_stats: Option<MatchSpanStats>,
) -> StructureDetail {
    let exactness_band = exactness.band();
    let Some(stats) = span_stats else {
        return StructureDetail {
            exactness_band,
            ..StructureDetail::default()
        };
    };
    if stats.matched_count < 2 {
        return StructureDetail {
            exactness_band,
            ..StructureDetail::default()
        };
    }

    let order_rank = if stats.in_sequence {
        if stats.span == stats.matched_count {
            MatchOrderRank::Contiguous
        } else {
            MatchOrderRank::Forward
        }
    } else {
        MatchOrderRank::None
    };
    let density_score = (((stats.matched_count as u32) * u8::MAX as u32) / stats.span.max(1) as u32)
        .min(u8::MAX as u32) as u8;
    let proximity_score = (proximity_score >> 8) as u8;

    StructureDetail {
        order_rank,
        density_score,
        proximity_score,
        exactness_band,
    }
}

pub(super) fn compute_quality_detail(
    prefix_preference_score: u8,
    match_class_score: u8,
    words_matched_weight: u16,
    typo_score: u8,
    structure_detail: StructureDetail,
) -> QualityDetail {
    QualityDetail {
        prefix_preference_score,
        match_class_score,
        words_matched_weight,
        structure_detail,
        typo_score,
    }
}

/// Coarse human-scale recency bands.
///
/// This sits before `quality_detail` in the tuple so quality can win within a
/// modest age band, while genuinely old-vs-recent gaps still defer to recency.
pub(super) fn compute_recency_bucket(timestamp: i64, now: i64) -> RecencyBucket {
    let age_secs = (now - timestamp).max(0);
    match age_secs {
        0..=RECENCY_BUCKET_LAST_HOUR_MAX_AGE_SECS => RecencyBucket::LastHour,
        RECENCY_BUCKET_LAST_DAY_MIN_AGE_SECS..=RECENCY_BUCKET_LAST_DAY_MAX_AGE_SECS => {
            RecencyBucket::LastDay
        }
        RECENCY_BUCKET_LAST_WEEK_MIN_AGE_SECS..=RECENCY_BUCKET_LAST_WEEK_MAX_AGE_SECS => {
            RecencyBucket::LastWeek
        }
        RECENCY_BUCKET_LAST_MONTH_MIN_AGE_SECS..=RECENCY_BUCKET_LAST_MONTH_MAX_AGE_SECS => {
            RecencyBucket::LastMonth
        }
        RECENCY_BUCKET_LAST_QUARTER_MIN_AGE_SECS..=RECENCY_BUCKET_LAST_QUARTER_MAX_AGE_SECS => {
            RecencyBucket::LastQuarter
        }
        _ => RecencyBucket::Stale,
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
pub(super) fn compute_recency_score(timestamp: i64, now: i64) -> u8 {
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
pub(super) fn quantize_bm25(score: f32) -> u16 {
    (score * 100.0).max(0.0).min(u16::MAX as f32) as u16
}

#[cfg(test)]
pub(super) fn quality_detail_structure(quality_detail: QualityDetail) -> StructureDetail {
    quality_detail.structure_detail
}

#[cfg(test)]
pub(super) fn quality_detail_typo_score(quality_detail: QualityDetail) -> u8 {
    quality_detail.typo_score
}

#[cfg(test)]
pub(super) fn recency_bucket_last_hour_max_age_secs() -> i64 {
    RECENCY_BUCKET_LAST_HOUR_MAX_AGE_SECS
}

#[cfg(test)]
pub(super) fn recency_bucket_last_day_max_age_secs() -> i64 {
    RECENCY_BUCKET_LAST_DAY_MAX_AGE_SECS
}

#[cfg(test)]
pub(super) fn recency_bucket_last_week_max_age_secs() -> i64 {
    RECENCY_BUCKET_LAST_WEEK_MAX_AGE_SECS
}

#[cfg(test)]
pub(super) fn recency_bucket_last_month_max_age_secs() -> i64 {
    RECENCY_BUCKET_LAST_MONTH_MAX_AGE_SECS
}

#[cfg(test)]
pub(super) fn recency_bucket_last_quarter_max_age_secs() -> i64 {
    RECENCY_BUCKET_LAST_QUARTER_MAX_AGE_SECS
}
