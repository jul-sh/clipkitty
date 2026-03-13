//! Milli-style bucket ranking for search results.
//!
//! Read this module as a pipeline:
//! 1. Match each query token against document tokens.
//! 2. Choose the best non-overlapping alignment across those token matches.
//! 3. Turn that alignment into quality signals.
//! 4. Combine quality, recency, and BM25 into a lexicographic bucket score.
//!
//! The implementation is split by stage:
//! - [`matching`] holds low-level word matching and edit distance logic.
//! - [`alignment`] solves the "best non-overlapping token assignment" problem.
//! - [`policy`] defines the ordered score types and tuning rules.

mod alignment;
mod matching;
mod policy;

use crate::search::is_word_token;
#[cfg(feature = "perf-log")]
use std::time::Instant;

use self::alignment::{alignment_exactness_signals, choose_best_alignment, trim_match_candidates};
pub use self::matching::edit_distance_bounded;
#[cfg(test)]
use self::matching::subsequence_match;
pub(crate) use self::matching::{
    does_word_match, does_word_match_fast, does_word_match_fast_raw, max_edit_distance,
    WordMatchKind,
};
use self::policy::{
    compute_quality_detail, compute_quality_tier, compute_recency_bucket, compute_recency_score,
    compute_structure_detail, quantize_bm25,
};
#[cfg(test)]
use self::policy::{
    quality_detail_structure, quality_detail_typo_score, recency_bucket_last_day_max_age_secs,
    recency_bucket_last_hour_max_age_secs, recency_bucket_last_month_max_age_secs,
    recency_bucket_last_quarter_max_age_secs, recency_bucket_last_week_max_age_secs,
};
pub use self::policy::{
    BucketScore, PrefixPreferenceQuery, QualityDetail, QualityTier, RecencyBucket, StructureDetail,
    LARGE_DOC_THRESHOLD_BYTES,
};

/// Context for computing bucket scores on a candidate document.
/// Groups the document-derived and query-derived parameters.
pub struct ScoringContext<'a> {
    /// Pre-tokenized, mode-specific document representation
    pub document: &'a PreparedDocument<'a>,
    /// Query words to match against
    pub query_words: &'a [&'a str],
    /// Lowercased query words, precomputed once per search
    pub query_words_lower: &'a [&'a str],
    /// Lowercased full query with spaces preserved between query tokens
    pub joined_query_lower: Option<&'a str>,
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

#[derive(Debug, Clone, Copy)]
pub(crate) struct TokenSpan {
    start: usize,
    end: usize,
}

#[derive(Debug)]
pub struct SmallPreparedDocument<'a> {
    content: &'a str,
    content_lower: String,
    token_spans: Vec<TokenSpan>,
    lower_tokens: Vec<String>,
}

#[derive(Debug)]
enum LargeFastCaseMode {
    Ascii,
    Unicode,
}

#[derive(Debug)]
pub struct LargeFastPreparedDocument<'a> {
    content: &'a str,
    token_spans: Vec<TokenSpan>,
    case_mode: LargeFastCaseMode,
}

#[derive(Debug)]
pub enum PreparedDocument<'a> {
    Small(SmallPreparedDocument<'a>),
    LargeFast(LargeFastPreparedDocument<'a>),
}

impl<'a> PreparedDocument<'a> {
    #[cfg_attr(not(feature = "perf-log"), allow(dead_code))]
    fn token_count(&self) -> usize {
        match self {
            Self::Small(doc) => doc.token_spans.len(),
            Self::LargeFast(doc) => doc.token_spans.len(),
        }
    }

    fn for_each_fast_token(&self, mut visit: impl FnMut(usize, &'a str) -> bool) {
        match self {
            Self::LargeFast(doc) => {
                for_each_prepared_token(doc.content, &doc.token_spans, &mut visit)
            }
            Self::Small(_) => {}
        }
    }

    fn starts_with_case_insensitive(&self, needle_lower: &str) -> bool {
        match self {
            Self::Small(doc) => doc.content_lower.starts_with(needle_lower),
            Self::LargeFast(doc) => match doc.case_mode {
                LargeFastCaseMode::Ascii => {
                    starts_with_ignore_ascii_case(doc.content, needle_lower)
                }
                LargeFastCaseMode::Unicode => doc.content.to_lowercase().starts_with(needle_lower),
            },
        }
    }

    fn contains_case_insensitive(&self, needle_lower: &str) -> bool {
        match self {
            Self::Small(doc) => doc.content_lower.contains(needle_lower),
            Self::LargeFast(doc) => match doc.case_mode {
                LargeFastCaseMode::Ascii => contains_ignore_ascii_case(doc.content, needle_lower),
                LargeFastCaseMode::Unicode => doc.content.to_lowercase().contains(needle_lower),
            },
        }
    }

    fn is_fast_mode(&self) -> bool {
        matches!(self, Self::LargeFast(_))
    }
}

impl<'a> SmallPreparedDocument<'a> {
    fn raw_token(&self, index: usize) -> &'a str {
        raw_token_from(self.content, self.token_spans[index])
    }

    fn lower_token(&self, index: usize) -> &str {
        self.lower_tokens[index].as_str()
    }
}

fn raw_token_from(content: &str, span: TokenSpan) -> &str {
    &content[span.start..span.end]
}

fn for_each_prepared_token<'a>(
    content: &'a str,
    token_spans: &[TokenSpan],
    visit: &mut impl FnMut(usize, &'a str) -> bool,
) {
    for (dpos, span) in token_spans.iter().copied().enumerate() {
        if !visit(dpos, raw_token_from(content, span)) {
            break;
        }
    }
}

pub(crate) fn prepare_document_for_ranking(content: &str) -> PreparedDocument<'_> {
    let token_spans = tokenize_for_ranking(content);

    if content.len() > LARGE_DOC_THRESHOLD_BYTES {
        PreparedDocument::LargeFast(LargeFastPreparedDocument {
            content,
            token_spans,
            case_mode: if content.is_ascii() {
                LargeFastCaseMode::Ascii
            } else {
                LargeFastCaseMode::Unicode
            },
        })
    } else {
        let content_lower = content.to_lowercase();
        let lower_tokens = token_spans
            .iter()
            .map(|span| content[span.start..span.end].to_lowercase())
            .collect();
        PreparedDocument::Small(SmallPreparedDocument {
            content,
            content_lower,
            token_spans,
            lower_tokens,
        })
    }
}

#[cfg(feature = "perf-log")]
#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct RankingPerfBreakdown {
    pub doc_word_count: usize,
    pub query_word_count: usize,
    pub raw_candidate_count: usize,
    pub trimmed_candidate_count: usize,
    pub match_query_words_ns: u64,
    pub collect_candidates_ns: u64,
    pub alignment_ns: u64,
    pub quality_signals_ns: u64,
    pub exactness_ns: u64,
}

fn tokenize_for_ranking(content: &str) -> Vec<TokenSpan> {
    if content.is_ascii() {
        tokenize_for_ranking_ascii(content.as_bytes())
    } else {
        tokenize_for_ranking_unicode(content)
    }
}

fn tokenize_for_ranking_ascii(bytes: &[u8]) -> Vec<TokenSpan> {
    let mut tokens = Vec::new();
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i].is_ascii_whitespace() {
            i += 1;
            continue;
        }

        let start = i;
        let is_word = bytes[i].is_ascii_alphanumeric();
        i += 1;

        while i < bytes.len()
            && !bytes[i].is_ascii_whitespace()
            && bytes[i].is_ascii_alphanumeric() == is_word
        {
            i += 1;
        }

        tokens.push(TokenSpan { start, end: i });
    }
    tokens
}

fn tokenize_for_ranking_unicode(content: &str) -> Vec<TokenSpan> {
    let mut tokens = Vec::new();
    let mut chars = content.char_indices().peekable();

    while let Some((start, ch)) = chars.next() {
        if ch.is_whitespace() {
            continue;
        }

        let is_word = ch.is_alphanumeric();
        let mut end = start + ch.len_utf8();

        while let Some(&(next_start, next_ch)) = chars.peek() {
            if next_ch.is_whitespace() || next_ch.is_alphanumeric() != is_word {
                break;
            }
            end = next_start + next_ch.len_utf8();
            chars.next();
        }

        tokens.push(TokenSpan { start, end });
    }

    tokens
}

/// Per-query-word match result
#[derive(Debug, Clone, Copy)]
struct WordMatch {
    /// Weight toward coarse coverage and tie-break detail.
    /// Punctuation tokens (like "://", ".") get 0 — they participate in
    /// proximity and highlighting only. Word tokens get len² (IDF proxy).
    query_weight: u16,
    query_char_len: usize,
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
    SubwordPrefix {
        doc_word_pos: usize,
    },
    InfixSubstring {
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
            query_char_len: query_word.chars().count(),
            state: WordMatchState::Unmatched,
        }
    }

    fn exact(query_word: &str, doc_word_pos: usize) -> Self {
        Self {
            query_weight: base_match_weight(query_word),
            query_char_len: query_word.chars().count(),
            state: WordMatchState::Exact { doc_word_pos },
        }
    }

    fn prefix(query_word: &str, doc_word_pos: usize) -> Self {
        Self {
            query_weight: base_match_weight(query_word),
            query_char_len: query_word.chars().count(),
            state: WordMatchState::Prefix { doc_word_pos },
        }
    }

    fn subword_prefix(query_word: &str, doc_word_pos: usize) -> Self {
        Self {
            query_weight: base_match_weight(query_word),
            query_char_len: query_word.chars().count(),
            state: WordMatchState::SubwordPrefix { doc_word_pos },
        }
    }

    fn infix_substring(query_word: &str, doc_word_pos: usize) -> Self {
        Self {
            query_weight: base_match_weight(query_word),
            query_char_len: query_word.chars().count(),
            state: WordMatchState::InfixSubstring { doc_word_pos },
        }
    }

    fn fuzzy(query_word: &str, doc_word_pos: usize, edit_dist: u8, typo_class: TypoClass) -> Self {
        Self {
            query_weight: base_match_weight(query_word),
            query_char_len: query_word.chars().count(),
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
            query_char_len: query_word.chars().count(),
            state: WordMatchState::Subsequence { doc_word_pos, gaps },
        }
    }

    fn doc_word_pos(self) -> Option<usize> {
        match self.state {
            WordMatchState::Unmatched => None,
            WordMatchState::Exact { doc_word_pos }
            | WordMatchState::Prefix { doc_word_pos }
            | WordMatchState::SubwordPrefix { doc_word_pos }
            | WordMatchState::InfixSubstring { doc_word_pos }
            | WordMatchState::Fuzzy { doc_word_pos, .. }
            | WordMatchState::Subsequence { doc_word_pos, .. } => Some(doc_word_pos),
        }
    }

    fn edit_distance(self) -> u8 {
        match self.state {
            WordMatchState::Unmatched
            | WordMatchState::Exact { .. }
            | WordMatchState::Prefix { .. }
            | WordMatchState::SubwordPrefix { .. }
            | WordMatchState::InfixSubstring { .. } => 0,
            WordMatchState::Fuzzy { edit_dist, .. } => edit_dist,
            WordMatchState::Subsequence { gaps, .. } => gaps.saturating_add(1),
        }
    }

    fn match_class_score(self) -> u8 {
        self.state.match_class_score()
    }

    fn matched_weight(self) -> u16 {
        match self.state {
            WordMatchState::Unmatched => 0,
            WordMatchState::Exact { .. } | WordMatchState::Prefix { .. } => self.query_weight,
            WordMatchState::SubwordPrefix { .. } | WordMatchState::InfixSubstring { .. } => {
                scaled_match_weight(
                    self.query_weight,
                    self.state.weight_multiplier(self.query_char_len),
                )
            }
            WordMatchState::Fuzzy { typo_class, .. } => scaled_match_weight(
                self.query_weight,
                typo_class.weight_multiplier(self.query_char_len),
            ),
            WordMatchState::Subsequence { .. } => scaled_match_weight(
                self.query_weight,
                self.state.weight_multiplier(self.query_char_len),
            ),
        }
    }
}

impl WordMatchState {
    fn match_class_score(self) -> u8 {
        match self {
            Self::Unmatched => 0,
            Self::Exact { .. } => 255,
            Self::Prefix { .. } => 240,
            Self::SubwordPrefix { .. } => 224,
            Self::InfixSubstring { .. } => 176,
            Self::Fuzzy { typo_class, .. } => typo_class.match_class_score(),
            Self::Subsequence { .. } => TypoClass::Subsequence.match_class_score(),
        }
    }

    fn weight_multiplier(self, query_char_len: usize) -> u16 {
        match self {
            Self::SubwordPrefix { .. } => SUBWORD_PREFIX_WEIGHT_MULTIPLIER,
            Self::InfixSubstring { .. } => INFIX_SUBSTRING_WEIGHT_MULTIPLIER,
            Self::Subsequence { .. } => {
                if query_char_len <= 4 {
                    SHORT_SUBSEQUENCE_WEIGHT_MULTIPLIER
                } else {
                    TypoClass::Subsequence.weight_multiplier(query_char_len)
                }
            }
            _ => MATCH_WEIGHT_SCALE,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum TypoClass {
    CommonTransposition,
    RepeatedCharEdit,
    InsertionOrDeletion,
    Substitution,
    MultiEdit,
    Subsequence,
}

impl TypoClass {
    fn match_class_score(self) -> u8 {
        match self {
            Self::CommonTransposition => 208,
            Self::RepeatedCharEdit => 192,
            Self::InsertionOrDeletion => 160,
            Self::Substitution => 144,
            Self::MultiEdit => 120,
            Self::Subsequence => 96,
        }
    }

    fn weight_multiplier(self, query_char_len: usize) -> u16 {
        if query_char_len == 3 {
            return match self {
                Self::CommonTransposition => SHORT_COMMON_TRANSPOSITION_WEIGHT_MULTIPLIER,
                Self::RepeatedCharEdit => SHORT_REPEATED_CHAR_WEIGHT_MULTIPLIER,
                Self::InsertionOrDeletion => SHORT_INSERTION_OR_DELETION_WEIGHT_MULTIPLIER,
                Self::Substitution => SHORT_SUBSTITUTION_WEIGHT_MULTIPLIER,
                Self::MultiEdit | Self::Subsequence => SHORT_MULTI_EDIT_WEIGHT_MULTIPLIER,
            };
        }

        match self {
            Self::CommonTransposition => COMMON_TRANSPOSITION_WEIGHT_MULTIPLIER,
            Self::RepeatedCharEdit => REPEATED_CHAR_WEIGHT_MULTIPLIER,
            Self::InsertionOrDeletion => INSERTION_OR_DELETION_WEIGHT_MULTIPLIER,
            Self::Substitution => SUBSTITUTION_WEIGHT_MULTIPLIER,
            Self::MultiEdit => MULTI_EDIT_WEIGHT_MULTIPLIER,
            Self::Subsequence => SUBSEQUENCE_WEIGHT_MULTIPLIER,
        }
    }
}

// Match-weight policy:
//
// Each matched query term contributes some fraction of its "base" weight
// (`len^2`) depending on how trustworthy that match shape is. The enum methods
// above hold the product policy for each match kind; this helper section just
// provides the fixed-point arithmetic they use.
//
// We use fixed-point multipliers with `256 == 1.0x` so the math stays cheap and
// deterministic. The policy values above are expressed directly in that scale.
const MATCH_WEIGHT_SCALE: u16 = 256;
macro_rules! define_weight_multiplier {
    ($name:ident = $value:expr $(,)?) => {
        const $name: u16 = $value;
        const _: () = assert!($name <= MATCH_WEIGHT_SCALE);
    };
}

const _: () = assert!(MATCH_WEIGHT_SCALE == 256);
define_weight_multiplier!(SUBWORD_PREFIX_WEIGHT_MULTIPLIER = 176);
define_weight_multiplier!(INFIX_SUBSTRING_WEIGHT_MULTIPLIER = 112);
define_weight_multiplier!(SHORT_SUBSEQUENCE_WEIGHT_MULTIPLIER = 48);
define_weight_multiplier!(COMMON_TRANSPOSITION_WEIGHT_MULTIPLIER = 160);
define_weight_multiplier!(REPEATED_CHAR_WEIGHT_MULTIPLIER = 144);
define_weight_multiplier!(INSERTION_OR_DELETION_WEIGHT_MULTIPLIER = 128);
define_weight_multiplier!(SUBSTITUTION_WEIGHT_MULTIPLIER = 112);
define_weight_multiplier!(MULTI_EDIT_WEIGHT_MULTIPLIER = 96);
define_weight_multiplier!(SUBSEQUENCE_WEIGHT_MULTIPLIER = 96);
define_weight_multiplier!(SHORT_COMMON_TRANSPOSITION_WEIGHT_MULTIPLIER = 96);
define_weight_multiplier!(SHORT_REPEATED_CHAR_WEIGHT_MULTIPLIER = 80);
define_weight_multiplier!(SHORT_INSERTION_OR_DELETION_WEIGHT_MULTIPLIER = 64);
define_weight_multiplier!(SHORT_SUBSTITUTION_WEIGHT_MULTIPLIER = 48);
define_weight_multiplier!(SHORT_MULTI_EDIT_WEIGHT_MULTIPLIER = 32);

// When aggregating match-class quality across multiple query terms, we use a
// weighted average but clamp how much it can exceed the weakest matched term.
// This preserves the signal that "one bad term should still matter" without
// letting a single weak term completely dominate a good multi-word match.
const MATCH_CLASS_WORST_CASE_SLACK: u8 = 64;

fn scaled_match_weight(base_weight: u16, multiplier: u16) -> u16 {
    if base_weight == 0 {
        return 0;
    }

    ((base_weight as u32 * multiplier as u32 + (MATCH_WEIGHT_SCALE as u32 / 2))
        / MATCH_WEIGHT_SCALE as u32)
        .max(1) as u16
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

#[derive(Debug, Clone, Copy)]
struct QualitySignals {
    query_word_count: usize,
    total_query_weight: u16,
    words_matched_weight: u16,
    prefix_preference_score: u8,
    exactness: ExactnessSignals,
    proximity_score: u16,
    match_class_score: u8,
    typo_score: u8,
    span_stats: Option<MatchSpanStats>,
}

impl QualitySignals {
    fn quality_tier(self) -> QualityTier {
        compute_quality_tier(
            self.query_word_count,
            self.total_query_weight,
            self.words_matched_weight,
            self.exactness,
            self.span_stats,
        )
    }

    fn quality_detail(self) -> QualityDetail {
        compute_quality_detail(
            self.prefix_preference_score,
            self.match_class_score,
            self.words_matched_weight,
            self.typo_score,
            compute_structure_detail(self.proximity_score, self.exactness, self.span_stats),
        )
    }
}

#[derive(Debug)]
struct RankingBreakdown {
    quality_signals: QualitySignals,
    recency_bucket: RecencyBucket,
    recency_score: u8,
    bm25_quantized: u16,
}

impl RankingBreakdown {
    fn into_bucket_score(self, timestamp: i64) -> BucketScore {
        BucketScore {
            quality_tier: self.quality_signals.quality_tier(),
            recency_bucket: self.recency_bucket,
            quality_detail: self.quality_signals.quality_detail(),
            recency_score: self.recency_score,
            bm25_quantized: self.bm25_quantized,
            recency: timestamp,
        }
    }
}

fn build_ranking_breakdown(ctx: &ScoringContext<'_>) -> RankingBreakdown {
    let word_matches = match_query_words(
        ctx.document,
        ctx.query_words,
        ctx.query_words_lower,
        ctx.last_word_is_prefix,
    );
    let quality_signals = compute_document_quality_signals(
        ctx.document,
        ctx.joined_query_lower,
        ctx.prefix_preference,
        &word_matches,
    );

    RankingBreakdown {
        quality_signals,
        recency_bucket: compute_recency_bucket(ctx.timestamp, ctx.now),
        recency_score: compute_recency_score(ctx.timestamp, ctx.now),
        bm25_quantized: quantize_bm25(ctx.bm25_score),
    }
}

#[cfg(feature = "perf-log")]
fn build_ranking_breakdown_with_perf(
    ctx: &ScoringContext<'_>,
) -> (RankingBreakdown, RankingPerfBreakdown) {
    let match_start = Instant::now();
    let (word_matches, mut perf) = match_query_words_with_perf(
        ctx.document,
        ctx.query_words,
        ctx.query_words_lower,
        ctx.last_word_is_prefix,
    );
    perf.match_query_words_ns = match_start.elapsed().as_nanos() as u64;

    let quality_start = Instant::now();
    let (quality_signals, exactness_ns) = compute_document_quality_signals_with_perf(
        ctx.document,
        ctx.joined_query_lower,
        ctx.prefix_preference,
        &word_matches,
    );
    perf.quality_signals_ns = quality_start.elapsed().as_nanos() as u64;
    perf.exactness_ns = exactness_ns;

    (
        RankingBreakdown {
            quality_signals,
            recency_bucket: compute_recency_bucket(ctx.timestamp, ctx.now),
            recency_score: compute_recency_score(ctx.timestamp, ctx.now),
            bm25_quantized: quantize_bm25(ctx.bm25_score),
        },
        perf,
    )
}

/// Compute the bucket score for a candidate document.
///
/// The prepared document in `ctx` should be built once per candidate and reused across
/// matching and quality scoring. Large documents automatically take a cheaper fast path
/// that avoids the full small-document fuzzy pipeline.
pub fn compute_bucket_score(ctx: &ScoringContext<'_>) -> BucketScore {
    if ctx.query_words.is_empty() {
        return BucketScore {
            quality_tier: QualityTier::NoMatch,
            recency_bucket: compute_recency_bucket(ctx.timestamp, ctx.now),
            quality_detail: QualityDetail::default(),
            recency_score: compute_recency_score(ctx.timestamp, ctx.now),
            bm25_quantized: quantize_bm25(ctx.bm25_score),
            recency: ctx.timestamp,
        };
    }

    build_ranking_breakdown(ctx).into_bucket_score(ctx.timestamp)
}

#[cfg(feature = "perf-log")]
pub(crate) fn compute_bucket_score_with_perf(
    ctx: &ScoringContext<'_>,
) -> (BucketScore, RankingPerfBreakdown) {
    if ctx.query_words.is_empty() {
        return (
            BucketScore {
                quality_tier: QualityTier::NoMatch,
                recency_bucket: compute_recency_bucket(ctx.timestamp, ctx.now),
                quality_detail: QualityDetail::default(),
                recency_score: compute_recency_score(ctx.timestamp, ctx.now),
                bm25_quantized: quantize_bm25(ctx.bm25_score),
                recency: ctx.timestamp,
            },
            RankingPerfBreakdown::default(),
        );
    }

    let (breakdown, perf) = build_ranking_breakdown_with_perf(ctx);
    (breakdown.into_bucket_score(ctx.timestamp), perf)
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

fn total_query_weight(word_matches: &[WordMatch]) -> u16 {
    word_matches.iter().map(|m| m.query_weight).sum()
}

fn words_matched_weight(word_matches: &[WordMatch]) -> u16 {
    word_matches.iter().map(|m| m.matched_weight()).sum()
}

fn build_quality_signals(
    word_matches: &[WordMatch],
    total_query_weight: u16,
    prefix_preference_score: u8,
    exactness: ExactnessSignals,
) -> QualitySignals {
    QualitySignals {
        query_word_count: word_matches.len(),
        total_query_weight,
        words_matched_weight: words_matched_weight(word_matches),
        prefix_preference_score,
        exactness,
        proximity_score: compute_proximity(word_matches),
        match_class_score: compute_match_class_score(word_matches),
        typo_score: compute_typo_score(word_matches),
        span_stats: compute_match_span_stats(word_matches),
    }
}

fn has_single_word_content_prefix(word_matches: &[WordMatch]) -> bool {
    let [word_match] = word_matches else {
        return false;
    };

    matches!(
        word_match.state,
        WordMatchState::Exact { doc_word_pos: 0 } | WordMatchState::Prefix { doc_word_pos: 0 }
    )
}

fn compute_fast_quality_signals(
    prefix_preference_score: u8,
    word_matches: &[WordMatch],
) -> QualitySignals {
    let mut exactness = alignment_exactness_signals(word_matches);
    exactness.content_prefix |= has_single_word_content_prefix(word_matches);

    build_quality_signals(
        word_matches,
        total_query_weight(word_matches),
        prefix_preference_score,
        exactness,
    )
}

enum DocumentQualityPlan {
    Fast(QualitySignals),
    Detailed { prefix_preference_score: u8 },
}

fn plan_document_quality_signals(
    document: &PreparedDocument<'_>,
    prefix_preference: Option<PrefixPreferenceQuery<'_>>,
    word_matches: &[WordMatch],
) -> DocumentQualityPlan {
    let prefix_preference_score =
        compute_prefix_preference_score_case_insensitive(document, prefix_preference);

    if document.is_fast_mode() {
        return DocumentQualityPlan::Fast(compute_fast_quality_signals(
            prefix_preference_score,
            word_matches,
        ));
    }

    DocumentQualityPlan::Detailed {
        prefix_preference_score,
    }
}

fn compute_document_quality_signals(
    document: &PreparedDocument<'_>,
    joined_query_lower: Option<&str>,
    prefix_preference: Option<PrefixPreferenceQuery<'_>>,
    word_matches: &[WordMatch],
) -> QualitySignals {
    match plan_document_quality_signals(document, prefix_preference, word_matches) {
        DocumentQualityPlan::Fast(signals) => signals,
        DocumentQualityPlan::Detailed {
            prefix_preference_score,
        } => {
            let exactness = compute_exactness_signals(document, joined_query_lower, word_matches);
            build_quality_signals(
                word_matches,
                total_query_weight(word_matches),
                prefix_preference_score,
                exactness,
            )
        }
    }
}

#[cfg(feature = "perf-log")]
fn compute_document_quality_signals_with_perf(
    document: &PreparedDocument<'_>,
    joined_query_lower: Option<&str>,
    prefix_preference: Option<PrefixPreferenceQuery<'_>>,
    word_matches: &[WordMatch],
) -> (QualitySignals, u64) {
    match plan_document_quality_signals(document, prefix_preference, word_matches) {
        DocumentQualityPlan::Fast(signals) => (signals, 0),
        DocumentQualityPlan::Detailed {
            prefix_preference_score,
        } => {
            let exactness_start = Instant::now();
            let exactness = compute_exactness_signals(document, joined_query_lower, word_matches);
            let exactness_ns = exactness_start.elapsed().as_nanos() as u64;

            (
                build_quality_signals(
                    word_matches,
                    total_query_weight(word_matches),
                    prefix_preference_score,
                    exactness,
                ),
                exactness_ns,
            )
        }
    }
}

fn compute_alignment_quality_signals(
    word_matches: &[WordMatch],
    total_query_weight: u16,
) -> QualitySignals {
    build_quality_signals(
        word_matches,
        total_query_weight,
        0,
        alignment_exactness_signals(word_matches),
    )
}

fn compute_typo_score(word_matches: &[WordMatch]) -> u8 {
    let total_edit_dist: u8 = word_matches
        .iter()
        .filter(|m| !matches!(m.state, WordMatchState::Unmatched))
        .map(|m| m.edit_distance())
        .sum();
    255u8.saturating_sub(total_edit_dist)
}

fn compute_match_class_score(word_matches: &[WordMatch]) -> u8 {
    let mut total_weight = 0u32;
    let mut weighted_sum = 0u32;
    let mut worst: Option<u8> = None;

    for word_match in word_matches
        .iter()
        .filter(|m| !matches!(m.state, WordMatchState::Unmatched))
    {
        let weight = word_match.query_weight.max(1) as u32;
        let score = word_match.match_class_score();
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
    weighted_avg.min(worst_score.saturating_add(MATCH_CLASS_WORST_CASE_SLACK))
}

/// For each query word, find the best-matching document word.
/// When `fast_mode` is true (for large documents), only exact and prefix matching
/// is used, skipping expensive fuzzy edit distance and subsequence matching.
#[cfg_attr(not(feature = "perf-log"), allow(dead_code))]
enum MatchQueryPlan {
    SingleFast {
        word_match: WordMatch,
        raw_candidate_count: usize,
    },
    Aligned {
        defaults: Vec<WordMatch>,
        candidate_lists: Vec<Vec<WordMatch>>,
        raw_candidate_count: usize,
        trimmed_candidate_count: usize,
    },
}

fn build_match_query_plan(
    document: &PreparedDocument<'_>,
    query_words: &[&str],
    query_words_lower: &[&str],
    last_word_is_prefix: bool,
) -> MatchQueryPlan {
    if document.is_fast_mode() && query_words.len() == 1 {
        let (word_match, raw_candidate_count) = match_single_query_word_fast_with_count(
            document,
            query_words[0],
            query_words_lower[0],
            last_word_is_prefix,
        );
        return MatchQueryPlan::SingleFast {
            word_match,
            raw_candidate_count,
        };
    }

    let defaults: Vec<WordMatch> = query_words
        .iter()
        .map(|qw| WordMatch::unmatched(qw))
        .collect();

    let mut raw_candidate_count = 0usize;
    let mut trimmed_candidate_count = 0usize;
    let candidate_lists: Vec<Vec<WordMatch>> = query_words
        .iter()
        .enumerate()
        .map(|(qi, qw)| {
            let is_last = qi == query_words.len() - 1;
            let allow_prefix = is_last && last_word_is_prefix;
            let (candidates, raw_count) =
                collect_match_candidates(qw, query_words_lower[qi], document, allow_prefix);
            raw_candidate_count += raw_count;
            trimmed_candidate_count += candidates.len();
            candidates
        })
        .collect();

    MatchQueryPlan::Aligned {
        defaults,
        candidate_lists,
        raw_candidate_count,
        trimmed_candidate_count,
    }
}

fn match_query_words(
    document: &PreparedDocument<'_>,
    query_words: &[&str],
    query_words_lower: &[&str],
    last_word_is_prefix: bool,
) -> Vec<WordMatch> {
    match build_match_query_plan(
        document,
        query_words,
        query_words_lower,
        last_word_is_prefix,
    ) {
        MatchQueryPlan::SingleFast { word_match, .. } => vec![word_match],
        MatchQueryPlan::Aligned {
            defaults,
            candidate_lists,
            ..
        } => choose_best_alignment(&candidate_lists, &defaults),
    }
}

#[cfg(feature = "perf-log")]
fn match_query_words_with_perf(
    document: &PreparedDocument<'_>,
    query_words: &[&str],
    query_words_lower: &[&str],
    last_word_is_prefix: bool,
) -> (Vec<WordMatch>, RankingPerfBreakdown) {
    let collect_start = Instant::now();
    let plan = build_match_query_plan(
        document,
        query_words,
        query_words_lower,
        last_word_is_prefix,
    );
    let collect_candidates_ns = collect_start.elapsed().as_nanos() as u64;

    match plan {
        MatchQueryPlan::SingleFast {
            word_match,
            raw_candidate_count,
        } => (
            vec![word_match],
            RankingPerfBreakdown {
                doc_word_count: document.token_count(),
                query_word_count: 1,
                raw_candidate_count,
                trimmed_candidate_count: usize::from(!matches!(
                    word_match.state,
                    WordMatchState::Unmatched
                )),
                collect_candidates_ns,
                alignment_ns: 0,
                ..RankingPerfBreakdown::default()
            },
        ),
        MatchQueryPlan::Aligned {
            defaults,
            candidate_lists,
            raw_candidate_count,
            trimmed_candidate_count,
        } => {
            let alignment_start = Instant::now();
            let word_matches = choose_best_alignment(&candidate_lists, &defaults);
            let alignment_ns = alignment_start.elapsed().as_nanos() as u64;

            (
                word_matches,
                RankingPerfBreakdown {
                    doc_word_count: document.token_count(),
                    query_word_count: query_words.len(),
                    raw_candidate_count,
                    trimmed_candidate_count,
                    collect_candidates_ns,
                    alignment_ns,
                    ..RankingPerfBreakdown::default()
                },
            )
        }
    }
}

fn base_match_weight(qw: &str) -> u16 {
    if is_word_token(qw) {
        (qw.len() as u16).saturating_mul(qw.len() as u16)
    } else {
        0
    }
}

fn match_single_query_word_fast_with_count(
    document: &PreparedDocument<'_>,
    query_word: &str,
    query_word_lower: &str,
    allow_prefix: bool,
) -> (WordMatch, usize) {
    if !document.is_fast_mode() {
        return (WordMatch::unmatched(query_word), 0);
    }

    let mut raw_candidate_count = 0usize;
    let mut best_exact = None;
    let mut best_prefix = None;

    document.for_each_fast_token(|dpos, doc_token| {
        let Some(candidate) = classify_fast_match_candidate(
            query_word,
            query_word_lower,
            doc_token,
            dpos,
            allow_prefix,
        ) else {
            return true;
        };

        raw_candidate_count += 1;
        match candidate.state {
            WordMatchState::Exact { .. } => {
                best_exact = Some(candidate);
                false
            }
            WordMatchState::Prefix { .. } => {
                best_prefix.get_or_insert(candidate);
                true
            }
            WordMatchState::Unmatched
            | WordMatchState::SubwordPrefix { .. }
            | WordMatchState::InfixSubstring { .. }
            | WordMatchState::Fuzzy { .. }
            | WordMatchState::Subsequence { .. } => true,
        }
    });

    if let Some(best_exact) = best_exact {
        return (best_exact, raw_candidate_count);
    }

    (
        best_prefix.unwrap_or_else(|| WordMatch::unmatched(query_word)),
        raw_candidate_count,
    )
}

fn collect_match_candidates(
    query_word: &str,
    query_word_lower: &str,
    document: &PreparedDocument<'_>,
    allow_prefix: bool,
) -> (Vec<WordMatch>, usize) {
    collect_match_candidates_impl(query_word, query_word_lower, document, allow_prefix)
}

fn collect_match_candidates_impl(
    query_word: &str,
    query_word_lower: &str,
    document: &PreparedDocument<'_>,
    allow_prefix: bool,
) -> (Vec<WordMatch>, usize) {
    let candidates: Vec<WordMatch> = match document {
        PreparedDocument::Small(doc) => (0..doc.token_spans.len())
            .filter_map(|dpos| {
                let dw_raw = doc.raw_token(dpos);
                let dw_lower = doc.lower_token(dpos);
                let wmk = does_word_match(query_word_lower, dw_lower, dw_raw, allow_prefix);
                match wmk {
                    WordMatchKind::Exact => Some(WordMatch::exact(query_word, dpos)),
                    WordMatchKind::Prefix => Some(WordMatch::prefix(query_word, dpos)),
                    WordMatchKind::SubwordPrefix => {
                        Some(WordMatch::subword_prefix(query_word, dpos))
                    }
                    WordMatchKind::InfixSubstring => {
                        Some(WordMatch::infix_substring(query_word, dpos))
                    }
                    WordMatchKind::Fuzzy(dist) => Some(WordMatch::fuzzy(
                        query_word,
                        dpos,
                        dist,
                        classify_fuzzy_typo(query_word_lower, dw_lower, dist),
                    )),
                    WordMatchKind::Subsequence(gaps) => {
                        Some(WordMatch::subsequence(query_word, dpos, gaps))
                    }
                    WordMatchKind::None => None,
                }
            })
            .collect(),
        PreparedDocument::LargeFast(_) => {
            let mut candidates = Vec::new();
            document.for_each_fast_token(|dpos, doc_token| {
                if let Some(candidate) = classify_fast_match_candidate(
                    query_word,
                    query_word_lower,
                    doc_token,
                    dpos,
                    allow_prefix,
                ) {
                    candidates.push(candidate);
                }
                true
            });
            candidates
        }
    };

    let raw_candidate_count = candidates.len();
    (trim_match_candidates(candidates), raw_candidate_count)
}

fn classify_fast_match_candidate(
    query_word: &str,
    query_word_lower: &str,
    document_token: &str,
    doc_word_pos: usize,
    allow_prefix: bool,
) -> Option<WordMatch> {
    match does_word_match_fast_raw(query_word_lower, document_token, allow_prefix) {
        WordMatchKind::Exact => Some(WordMatch::exact(query_word, doc_word_pos)),
        WordMatchKind::Prefix => Some(WordMatch::prefix(query_word, doc_word_pos)),
        WordMatchKind::None => None,
        WordMatchKind::SubwordPrefix
        | WordMatchKind::InfixSubstring
        | WordMatchKind::Fuzzy(_)
        | WordMatchKind::Subsequence(_) => None,
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

fn compute_prefix_preference_score_case_insensitive(
    document: &PreparedDocument<'_>,
    prefix_preference: Option<PrefixPreferenceQuery<'_>>,
) -> u8 {
    match prefix_preference {
        Some(PrefixPreferenceQuery {
            raw_query_lower, ..
        }) if document.starts_with_case_insensitive(raw_query_lower) => 3,
        Some(PrefixPreferenceQuery {
            raw_query_lower, ..
        }) if document.contains_case_insensitive(raw_query_lower) => 2,
        Some(PrefixPreferenceQuery {
            stripped_query_lower,
            ..
        }) if document.starts_with_case_insensitive(stripped_query_lower) => 1,
        _ => 0,
    }
}

fn starts_with_ignore_ascii_case(content: &str, needle_lower: &str) -> bool {
    if !needle_lower.is_ascii() {
        return false;
    }

    let bytes = content.as_bytes();
    let needle = needle_lower.as_bytes();
    bytes.len() >= needle.len() && bytes[..needle.len()].eq_ignore_ascii_case(needle)
}

fn contains_ignore_ascii_case(content: &str, needle_lower: &str) -> bool {
    if needle_lower.is_empty() {
        return true;
    }
    if !needle_lower.is_ascii() {
        return false;
    }

    let haystack = content.as_bytes();
    let needle = needle_lower.as_bytes();
    if needle.len() > haystack.len() {
        return false;
    }

    let first_lower = needle[0];
    let first_upper = first_lower.to_ascii_uppercase();
    let last_start = haystack.len() - needle.len();

    for start in 0..=last_start {
        let first = haystack[start];
        if (first == first_lower || first == first_upper)
            && haystack[start..start + needle.len()].eq_ignore_ascii_case(needle)
        {
            return true;
        }
    }

    false
}

/// Compute explicit exactness signals for the matched query terms.
fn compute_exactness_signals(
    document: &PreparedDocument<'_>,
    full_query_lower: Option<&str>,
    word_matches: &[WordMatch],
) -> ExactnessSignals {
    let matched: Vec<&WordMatch> = word_matches
        .iter()
        .filter(|m| !matches!(m.state, WordMatchState::Unmatched))
        .collect();
    if matched.is_empty() {
        return ExactnessSignals::default();
    }

    let full_query = full_query_lower.unwrap_or("");

    let all_matched = word_matches
        .iter()
        .all(|m| !matches!(m.state, WordMatchState::Unmatched));
    let content_prefix =
        !full_query.is_empty() && document.starts_with_case_insensitive(full_query);
    let query_substring = !full_query.is_empty() && document.contains_case_insensitive(full_query);
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
#[cfg(test)]
fn compute_exactness(content: &str, query_words: &[&str], word_matches: &[WordMatch]) -> u8 {
    let document = prepare_document_for_ranking(content);
    let full_query_lower = (!query_words.is_empty()).then(|| query_words.join(" ").to_lowercase());
    compute_exactness_signals(&document, full_query_lower.as_deref(), word_matches)
        .band()
        .score()
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
        let document = prepare_document_for_ranking(content);
        let query_words_lower_owned: Vec<String> =
            query_words.iter().map(|word| word.to_lowercase()).collect();
        let query_words_lower: Vec<&str> =
            query_words_lower_owned.iter().map(String::as_str).collect();
        let joined_query_lower =
            (!query_words.is_empty()).then(|| query_words.join(" ").to_lowercase());

        compute_bucket_score(&ScoringContext {
            document: &document,
            query_words,
            query_words_lower: &query_words_lower,
            joined_query_lower: joined_query_lower.as_deref(),
            last_word_is_prefix,
            prefix_preference,
            timestamp,
            bm25_score: bm25,
            now,
        })
    }

    fn dwm(query_word: &str, doc_word: &str, allow_prefix: bool) -> WordMatchKind {
        does_word_match(
            &query_word.to_lowercase(),
            &doc_word.to_lowercase(),
            doc_word,
            allow_prefix,
        )
    }

    fn match_words(
        query_words: &[&str],
        doc_words: &[&str],
        last_word_is_prefix: bool,
    ) -> Vec<WordMatch> {
        let content = doc_words.join(" ");
        let document = prepare_document_for_ranking(&content);
        let query_words_lower_owned: Vec<String> =
            query_words.iter().map(|word| word.to_lowercase()).collect();
        let query_words_lower: Vec<&str> =
            query_words_lower_owned.iter().map(String::as_str).collect();
        match_query_words(
            &document,
            query_words,
            &query_words_lower,
            last_word_is_prefix,
        )
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

    fn wm_subword_prefix(query_word: &str, doc_word_pos: usize) -> WordMatch {
        WordMatch::subword_prefix(query_word, doc_word_pos)
    }

    fn wm_infix(query_word: &str, doc_word_pos: usize) -> WordMatch {
        WordMatch::infix_substring(query_word, doc_word_pos)
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
        assert_eq!(dwm("hello", "hello", false), WordMatchKind::Exact);
    }

    #[test]
    fn test_does_word_match_prefix() {
        assert_eq!(dwm("cl", "clipkitty", true), WordMatchKind::Prefix);
        // Not allowed when allow_prefix=false
        assert_eq!(dwm("cl", "clipkitty", false), WordMatchKind::None);
        // Single char prefix not allowed (< 2 chars)
        assert_eq!(dwm("c", "clipkitty", true), WordMatchKind::None);
    }

    #[test]
    fn test_does_word_match_subword_prefix() {
        assert_eq!(
            dwm("code", "responseCode", false),
            WordMatchKind::SubwordPrefix
        );
        assert_eq!(
            dwm("server", "HTTPServer", false),
            WordMatchKind::SubwordPrefix
        );
    }

    #[test]
    fn test_does_word_match_infix_substring() {
        assert_eq!(dwm("port", "import", false), WordMatchKind::InfixSubstring);
        assert_eq!(dwm("auth", "oauth", false), WordMatchKind::InfixSubstring);
    }

    #[test]
    fn test_does_word_match_fuzzy() {
        // "riversde" (8 chars) -> max_dist 1
        assert_eq!(dwm("riversde", "riverside", false), WordMatchKind::Fuzzy(1));
        // "improt" (6 chars) -> max_dist 1, transposition counts as 1
        assert_eq!(dwm("improt", "import", false), WordMatchKind::Fuzzy(1));
        // Short word transpositions (3-4 chars)
        assert_eq!(dwm("teh", "the", false), WordMatchKind::Fuzzy(1));
        assert_eq!(dwm("form", "from", false), WordMatchKind::Fuzzy(1));
        assert_eq!(dwm("adn", "and", false), WordMatchKind::Fuzzy(1));
        // Short word substitution — also matches (same edit distance)
        assert_eq!(dwm("tha", "the", false), WordMatchKind::Fuzzy(1));
        // First-char mismatch penalty prevents false positives
        assert_eq!(dwm("bat", "cat", false), WordMatchKind::None);
        assert_eq!(dwm("rat", "cat", false), WordMatchKind::None);
        // 2-char words still get no fuzzy
        assert_eq!(dwm("te", "the", false), WordMatchKind::None);
    }

    #[test]
    fn test_does_word_match_subsequence() {
        // "helo" (4 chars) -> fuzzy wins: edit_distance("helo","hello")=1
        assert_eq!(dwm("helo", "hello", false), WordMatchKind::Fuzzy(1));
        // "impt" (4 chars) -> len diff 2 exceeds max_dist 1, falls to subsequence
        assert_eq!(dwm("impt", "import", false), WordMatchKind::Subsequence(1));
        // "cls" (3 chars) -> too short for both fuzzy and subsequence now
        assert_eq!(dwm("cls", "class", false), WordMatchKind::None);
        // Too short for subsequence (<= 3 chars)
        assert_eq!(dwm("ab", "abc", false), WordMatchKind::None);
        // Coverage too low: 3 chars vs 7 char target (43% < 50%)
        assert_eq!(dwm("abc", "abcdefg", false), WordMatchKind::None);
        // Fuzzy takes priority over subsequence when both could match
        // "imprt" (5 chars) has edit_distance 1 to "import", so fuzzy wins
        assert_eq!(dwm("imprt", "import", false), WordMatchKind::Fuzzy(1));
    }

    // ── match_query_words tests ──────────────────────────────────

    #[test]
    fn test_match_exact() {
        let doc_words = vec!["hello", "world"];
        let matches = match_words(&["hello"], &doc_words, false);
        assert_eq!(matches.len(), 1);
        assert!(matches!(matches[0].state, WordMatchState::Exact { .. }));
        assert_eq!(matches[0].edit_distance(), 0);
    }

    #[test]
    fn test_match_prefix_last_word() {
        let doc_words = vec!["clipkitty"];
        let matches = match_words(&["cl"], &doc_words, true);
        assert_eq!(matches.len(), 1);
        assert!(matches!(matches[0].state, WordMatchState::Prefix { .. }));
        assert_eq!(matches[0].edit_distance(), 0);
    }

    #[test]
    fn test_match_prefix_not_allowed_non_last() {
        let doc_words = vec!["clipkitty"];
        let matches = match_words(&["cl", "hello"], &doc_words, true);
        assert!(matches!(matches[0].state, WordMatchState::Unmatched));
    }

    #[test]
    fn test_match_fuzzy() {
        let doc_words = vec!["riverside", "park"];
        let matches = match_words(&["riversde"], &doc_words, false);
        assert!(matches!(matches[0].state, WordMatchState::Fuzzy { .. }));
        assert_eq!(matches[0].edit_distance(), 1);
    }

    #[test]
    fn test_match_fuzzy_short_word() {
        // "helo" (4 chars) matches "hello" via fuzzy (edit distance 1)
        let doc_words = vec!["hello"];
        let matches = match_words(&["helo"], &doc_words, false);
        assert!(matches!(matches[0].state, WordMatchState::Fuzzy { .. }));
        assert_eq!(matches[0].edit_distance(), 1);
    }

    #[test]
    fn test_match_transposition_short_word() {
        // "teh" (3 chars) matches "the" via fuzzy (transposition = 1 edit)
        let doc_words = vec!["the", "quick"];
        let matches = match_words(&["teh"], &doc_words, false);
        assert!(matches!(matches[0].state, WordMatchState::Fuzzy { .. }));
        assert_eq!(matches[0].edit_distance(), 1);
    }

    #[test]
    fn test_match_subword_prefix() {
        let doc_words = vec!["responseCode"];
        let matches = match_words(&["code"], &doc_words, false);
        assert!(matches!(
            matches[0].state,
            WordMatchState::SubwordPrefix { .. }
        ));
    }

    #[test]
    fn test_match_infix_substring() {
        let doc_words = vec!["import"];
        let matches = match_words(&["port"], &doc_words, false);
        assert!(matches!(
            matches[0].state,
            WordMatchState::InfixSubstring { .. }
        ));
    }

    #[test]
    fn test_match_multi_word() {
        let doc_words = vec!["hello", "beautiful", "world"];
        let matches = match_words(&["hello", "world"], &doc_words, false);
        assert!(!matches!(matches[0].state, WordMatchState::Unmatched));
        assert!(!matches!(matches[1].state, WordMatchState::Unmatched));
        assert_eq!(matches[0].doc_word_pos(), Some(0));
        assert_eq!(matches[1].doc_word_pos(), Some(2));
    }

    #[test]
    fn test_match_repeated_query_words_require_distinct_doc_occurrences() {
        let doc_words = vec!["hello", "world"];
        let matches = match_words(&["hello", "hello"], &doc_words, false);
        assert!(!matches!(matches[0].state, WordMatchState::Unmatched));
        assert!(
            matches!(matches[1].state, WordMatchState::Unmatched),
            "A repeated query token should not reuse the same document token"
        );
    }

    #[test]
    fn test_match_prefers_best_global_alignment_over_earliest_exact_occurrences() {
        let doc_words = vec!["alpha", "noise", "noise", "noise", "beta", "alpha", "beta"];
        let matches = match_words(&["alpha", "beta"], &doc_words, false);
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

    #[test]
    fn test_large_fast_single_word_prefers_exact_over_prefix() {
        let filler = "noise ".repeat((LARGE_DOC_THRESHOLD_BYTES / 6) + 32);
        let content = format!("{filler} errorlog {filler} error");
        let document = prepare_document_for_ranking(&content);
        assert!(document.is_fast_mode());

        let matches = match_query_words(&document, &["error"], &["error"], true);
        assert!(matches!(matches[0].state, WordMatchState::Exact { .. }));
    }

    #[test]
    fn test_large_fast_single_word_content_prefix_beats_later_exact_match() {
        let now = 1700000000i64;
        let filler = "noise ".repeat((LARGE_DOC_THRESHOLD_BYTES / 6) + 64);
        let content_prefix = format!("error {filler}");
        let later_exact = format!("{filler}error");

        assert!(prepare_document_for_ranking(&content_prefix).is_fast_mode());
        assert!(prepare_document_for_ranking(&later_exact).is_fast_mode());

        let prefix_score = score(
            &content_prefix,
            &["error"],
            false,
            None,
            now - 3600,
            1.0,
            now,
        );
        let later_score = score(&later_exact, &["error"], false, None, now - 3600, 1.0, now);

        assert!(
            prefix_score > later_score,
            "Large-doc fast mode should still reward a single-word content-prefix hit"
        );
    }

    #[test]
    fn test_large_fast_unicode_exact_match() {
        let filler = "данные ".repeat((LARGE_DOC_THRESHOLD_BYTES / "данные ".len()) + 32);
        let content = format!("{filler} ошибка {filler}");
        let document = prepare_document_for_ranking(&content);
        assert!(document.is_fast_mode());

        let matches = match_query_words(&document, &["ошибка"], &["ошибка"], false);
        assert!(matches!(matches[0].state, WordMatchState::Exact { .. }));
    }

    #[test]
    fn test_large_fast_unicode_last_word_prefix_match() {
        let filler = "данные ".repeat((LARGE_DOC_THRESHOLD_BYTES / "данные ".len()) + 32);
        let content = format!("{filler} ошибках {filler}");
        let document = prepare_document_for_ranking(&content);
        assert!(document.is_fast_mode());

        let matches = match_query_words(&document, &["ошиб"], &["ошиб"], true);
        assert!(matches!(matches[0].state, WordMatchState::Prefix { .. }));
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
        let last_hour = recency_bucket_last_hour_max_age_secs();
        let last_day = recency_bucket_last_day_max_age_secs();
        let last_week = recency_bucket_last_week_max_age_secs();
        let last_month = recency_bucket_last_month_max_age_secs();
        let last_quarter = recency_bucket_last_quarter_max_age_secs();

        assert_eq!(compute_recency_bucket(now, now), RecencyBucket::LastHour);
        assert_eq!(
            compute_recency_bucket(now - last_hour, now),
            RecencyBucket::LastHour
        );
        assert_eq!(
            compute_recency_bucket(now - (last_hour + 1), now),
            RecencyBucket::LastDay
        );
        assert_eq!(
            compute_recency_bucket(now - last_day, now),
            RecencyBucket::LastDay
        );
        assert_eq!(
            compute_recency_bucket(now - (last_day + 1), now),
            RecencyBucket::LastWeek
        );
        assert_eq!(
            compute_recency_bucket(now - last_week, now),
            RecencyBucket::LastWeek
        );
        assert_eq!(
            compute_recency_bucket(now - (last_week + 1), now),
            RecencyBucket::LastMonth
        );
        assert_eq!(
            compute_recency_bucket(now - last_month, now),
            RecencyBucket::LastMonth
        );
        assert_eq!(
            compute_recency_bucket(now - (last_month + 1), now),
            RecencyBucket::LastQuarter
        );
        assert_eq!(
            compute_recency_bucket(now - last_quarter, now),
            RecencyBucket::LastQuarter
        );
        assert_eq!(
            compute_recency_bucket(now - (last_quarter + 1), now),
            RecencyBucket::Stale
        );
    }

    #[test]
    fn test_match_class_score_uses_weighted_average_with_worst_case_clamp() {
        let mixed = vec![
            wm_exact("encyclopedia", 0),
            wm_subsequence("hello", 3, 2),
            wm_exact("documentation", 5),
        ];

        assert_eq!(
            compute_match_class_score(&mixed),
            TypoClass::Subsequence
                .match_class_score()
                .saturating_add(MATCH_CLASS_WORST_CASE_SLACK)
        );
    }

    #[test]
    fn test_common_transposition_keeps_more_match_weight_than_substitution() {
        let transposition = wm_fuzzy("teh", 0, 1, TypoClass::CommonTransposition);
        let substitution = wm_fuzzy("teh", 0, 1, TypoClass::Substitution);

        assert!(transposition.matched_weight() > substitution.matched_weight());
    }

    #[test]
    fn test_subword_prefix_keeps_more_match_weight_than_raw_infix() {
        let subword = wm_subword_prefix("code", 0);
        let infix = wm_infix("code", 0);

        assert!(subword.matched_weight() > infix.matched_weight());
        assert!(subword.match_class_score() > infix.match_class_score());
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
    fn test_word_prefix_beats_moderately_newer_infix_substring() {
        let now = 1700000000i64;
        let older_word_prefix = score("portal notes", &["port"], true, None, now - 600, 1.0, now);
        let newer_infix = score("import notes", &["port"], true, None, now - 180, 1.0, now);
        assert!(
            older_word_prefix > newer_infix,
            "Across a moderate age gap, word-prefix should beat a newer raw infix substring"
        );
    }

    #[test]
    fn test_subword_prefix_beats_moderately_newer_infix_substring() {
        let now = 1700000000i64;
        let older_subword = score("responseCode", &["code"], true, None, now - 600, 1.0, now);
        let newer_infix = score("barcode", &["code"], true, None, now - 180, 1.0, now);
        assert!(
            older_subword > newer_infix,
            "Across a moderate age gap, subword-prefix should beat a newer raw infix substring"
        );
    }

    #[test]
    fn test_recent_infix_substring_beats_ancient_word_prefix() {
        let now = 1700000000i64;
        let ancient_word_prefix = score(
            "portal notes",
            &["port"],
            true,
            None,
            now - 60 * 86400,
            1.0,
            now,
        );
        let recent_infix = score("import notes", &["port"], true, None, now - 180, 1.0, now);
        assert!(
            recent_infix > ancient_word_prefix,
            "Across a massive age gap, recency should still beat the stronger word-prefix match"
        );
    }

    #[test]
    fn test_infix_substring_beats_moderately_newer_typo_match() {
        let now = 1700000000i64;
        let older_infix = score("import config", &["port"], true, None, now - 600, 1.0, now);
        let newer_typo = score("pory config", &["port"], true, None, now - 180, 1.0, now);
        assert!(
            older_infix > newer_typo,
            "Across a moderate age gap, zero-edit infix substring should beat a newer typo match"
        );
    }

    #[test]
    fn test_light_typo_beats_moderately_newer_infix_substring() {
        let now = 1700000000i64;
        let older_light_typo = score("the", &["teh"], true, None, now - 600, 1.0, now);
        let newer_infix = score("import config", &["port"], true, None, now - 180, 1.0, now);
        assert!(
            older_light_typo > newer_infix,
            "Across a moderate age gap, a common transposition should beat a newer raw infix substring"
        );
    }

    #[test]
    fn test_repeated_char_typo_beats_moderately_newer_infix_substring() {
        let now = 1700000000i64;
        let older_repeated_char = score("hello", &["helllo"], true, None, now - 600, 1.0, now);
        let newer_infix = score("import config", &["port"], true, None, now - 180, 1.0, now);
        assert!(
            older_repeated_char > newer_infix,
            "Across a moderate age gap, a repeated-char typo should beat a newer raw infix substring"
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
        assert_eq!(s.quality_tier, QualityTier::ContentPrefix);
        assert_eq!(s.words_matched_weight(), 50); // 5² + 5² = 50
        assert_eq!(s.recency_score, 255); // just now
        assert_eq!(quality_detail_typo_score(s.quality_detail), 255);
        assert!(quality_detail_structure(s.quality_detail) > StructureDetail::default());
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
