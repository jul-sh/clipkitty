use super::{ExactnessSignals, MatchSpanStats};

/// Documents larger than this threshold use fast matching (exact + prefix only).
/// This trades typo tolerance for performance on large documents like code files.
pub const LARGE_DOC_THRESHOLD_BYTES: usize = 32 * 1024; // 32KB

/// Bucket score tuple. Higher fields dominate lower ones.
///
/// The field order here is the ranking policy:
/// 1. foundational match quality
/// 2. coarse recency band
/// 3. detailed tie-break quality
/// 4. raw timestamp
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct BucketScore {
    pub quality_tier: QualityTier,
    pub recency_bucket: RecencyBucket,
    pub quality_detail: QualityDetail,
    pub recency: i64,
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

/// Coarse ranking detail used only after `quality_tier` and `recency_bucket`.
///
/// The field order here is still the ranking policy. Each field is deliberately
/// banded so tiny match-quality differences collapse and smooth recency can
/// break ties between similar-feeling results.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub struct QualityDetail {
    pub prefix_preference: PrefixPreferenceBand,
    pub match_class: MatchClassBand,
    pub coverage: CoverageBand,
    pub phrase_shape: PhraseShapeBand,
}

/// Prefix preference state carried from the `^query` mode.
#[derive(Debug, Clone, Copy)]
pub struct PrefixPreferenceQuery<'a> {
    pub raw_query_lower: &'a str,
    pub stripped_query_lower: &'a str,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub enum PrefixPreferenceBand {
    #[default]
    None = 0,
    StrippedContentPrefix = 1,
    RawQueryContains = 2,
    RawQueryContentPrefix = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub enum MatchClassBand {
    #[default]
    None = 0,
    Subsequence = 1,
    MultiEditTypo = 2,
    WeakTypo = 3,
    InfixSubstring = 4,
    CommonTypo = 5,
    SubwordPrefix = 6,
    Prefix = 7,
    Exact = 8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub enum CoverageBand {
    #[default]
    None = 0,
    Weak = 1,
    Adequate = 2,
    Strong = 3,
    Full = 4,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub enum PhraseShapeBand {
    #[default]
    None = 0,
    Scattered = 1,
    Forward = 2,
    TightForward = 3,
    Contiguous = 4,
    QuerySubstring = 5,
    AnchoredSequence = 6,
    ContentPrefix = 7,
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

pub(super) fn compute_quality_detail(
    prefix_preference_score: u8,
    match_class_score: u8,
    total_query_weight: u16,
    words_matched_weight: u16,
    exactness: ExactnessSignals,
    span_stats: Option<MatchSpanStats>,
) -> QualityDetail {
    QualityDetail {
        prefix_preference: compute_prefix_preference_band(prefix_preference_score),
        match_class: compute_match_class_band(match_class_score),
        coverage: compute_coverage_band(total_query_weight, words_matched_weight),
        phrase_shape: compute_phrase_shape_band(exactness, span_stats),
    }
}

fn compute_prefix_preference_band(prefix_preference_score: u8) -> PrefixPreferenceBand {
    match prefix_preference_score {
        0 => PrefixPreferenceBand::None,
        1 => PrefixPreferenceBand::StrippedContentPrefix,
        2 => PrefixPreferenceBand::RawQueryContains,
        _ => PrefixPreferenceBand::RawQueryContentPrefix,
    }
}

fn compute_match_class_band(match_class_score: u8) -> MatchClassBand {
    // Boundaries sit halfway between the raw per-match class scores.
    match match_class_score {
        0 => MatchClassBand::None,
        1..=107 => MatchClassBand::Subsequence,
        108..=131 => MatchClassBand::MultiEditTypo,
        132..=167 => MatchClassBand::WeakTypo,
        168..=183 => MatchClassBand::InfixSubstring,
        184..=215 => MatchClassBand::CommonTypo,
        216..=231 => MatchClassBand::SubwordPrefix,
        232..=247 => MatchClassBand::Prefix,
        248..=u8::MAX => MatchClassBand::Exact,
    }
}

fn compute_coverage_band(total_query_weight: u16, words_matched_weight: u16) -> CoverageBand {
    if words_matched_weight == 0 {
        return CoverageBand::None;
    }
    if total_query_weight == 0 {
        return CoverageBand::Full;
    }

    match ((words_matched_weight as u32) * 100 / total_query_weight as u32) as u8 {
        0 => CoverageBand::None,
        1..=59 => CoverageBand::Weak,
        60..=79 => CoverageBand::Adequate,
        80..=94 => CoverageBand::Strong,
        95..=u8::MAX => CoverageBand::Full,
    }
}

fn compute_phrase_shape_band(
    exactness: ExactnessSignals,
    span_stats: Option<MatchSpanStats>,
) -> PhraseShapeBand {
    match exactness.band() {
        ExactnessBand::ContentPrefix => return PhraseShapeBand::ContentPrefix,
        ExactnessBand::AnchoredSequence => return PhraseShapeBand::AnchoredSequence,
        ExactnessBand::QuerySubstring => return PhraseShapeBand::QuerySubstring,
        ExactnessBand::FuzzyOnly
        | ExactnessBand::MixedZeroCost
        | ExactnessBand::AllZeroCost
        | ExactnessBand::AllExact => {}
    }

    let Some(stats) = span_stats else {
        return PhraseShapeBand::None;
    };
    if stats.matched_count < 2 {
        return PhraseShapeBand::None;
    }
    if !stats.in_sequence {
        return PhraseShapeBand::Scattered;
    }
    if stats.span == stats.matched_count {
        return PhraseShapeBand::Contiguous;
    }
    if stats.span <= stats.matched_count * 2 {
        return PhraseShapeBand::TightForward;
    }
    PhraseShapeBand::Forward
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
