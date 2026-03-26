//! Tantivy Indexer for ClipKitty
//!
//! Two-phase search: trigram recall (Phase 1) + Milli-style bucket re-ranking (Phase 2).
//! For queries under 3 characters, returns empty (handled by search.rs streaming fallback).

use crate::candidate::{
    ChunkMatchContext, SearchCandidate, SearchMatchContext, WholeItemMatchContext,
};
#[cfg(not(feature = "perf-log"))]
use crate::ranking::compute_bucket_score;
#[cfg(feature = "perf-log")]
use crate::ranking::{
    compute_bucket_score_with_perf, RankingPerfBreakdown, LARGE_DOC_THRESHOLD_BYTES,
};
use crate::ranking::{prepare_document_for_ranking, PrefixPreferenceQuery, ScoringContext};
use crate::search::{self, SearchQuery};
pub(crate) use crate::search_admission::CHUNK_PARENT_THRESHOLD_BYTES;
use crate::search_admission::{
    PhaseOneAdmissionPolicy, PhaseOneBlendedScore, PhaseTwoHead, PROXIMITY_BOOST_SCALE,
    WORD_MATCH_SIGNAL,
};
use chrono::Utc;
use tokio_util::sync::CancellationToken;

/// Index version - bump this when schema changes to trigger automatic rebuild.
/// History: v3 = initial trigram, v4 = content_words WithFreqsAndPositions
pub const INDEX_VERSION: &str = "v5";

const CHUNK_TARGET_BYTES: usize = 16 * 1024;
const CHUNK_OVERLAP_BYTES: usize = 2 * 1024;
const CHUNK_BOUNDARY_SLACK_BYTES: usize = 1024;
const RAW_RECALL_BATCHES: [usize; 5] = [256, 512, 1024, 2048, 4096];
use parking_lot::RwLock;
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::path::Path;
#[cfg(test)]
use tantivy::collector::TopDocs;
use tantivy::collector::{Collector, SegmentCollector, TopNComputer};
use tantivy::directory::MmapDirectory;
use tantivy::query::{
    BooleanQuery, BoostQuery, ConstScoreQuery, FuzzyTermQuery, Occur, PhrasePrefixQuery,
    PhraseQuery, TermQuery,
};
use tantivy::schema::*;
use tantivy::tokenizer::{NgramTokenizer, TextAnalyzer, TokenFilter, TokenStream, Tokenizer};
use tantivy::{
    DocAddress, DocId, Index, IndexReader, IndexWriter, ReloadPolicy, Score, SegmentReader, Term,
};
use thiserror::Error;

#[derive(Debug, Clone, Copy)]
struct ChunkSlice {
    index: u32,
    start: usize,
    end: usize,
}

/// Token filter that assigns incrementing positions to tokens.
/// NgramTokenizer sets all positions to 0, which breaks PhraseQuery.
/// This filter fixes that so PhraseQuery can match contiguous ngrams.
#[derive(Clone)]
struct IncrementPositionFilter;

impl TokenFilter for IncrementPositionFilter {
    type Tokenizer<T: Tokenizer> = IncrementPositionFilterWrapper<T>;

    fn transform<T: Tokenizer>(self, tokenizer: T) -> Self::Tokenizer<T> {
        IncrementPositionFilterWrapper(tokenizer)
    }
}

#[derive(Clone)]
struct IncrementPositionFilterWrapper<T>(T);

impl<T: Tokenizer> Tokenizer for IncrementPositionFilterWrapper<T> {
    type TokenStream<'a> = IncrementPositionTokenStream<T::TokenStream<'a>>;

    fn token_stream<'a>(&'a mut self, text: &'a str) -> Self::TokenStream<'a> {
        IncrementPositionTokenStream {
            inner: self.0.token_stream(text),
            position: 0,
        }
    }
}

struct IncrementPositionTokenStream<T> {
    inner: T,
    position: usize,
}

impl<T: TokenStream> TokenStream for IncrementPositionTokenStream<T> {
    fn advance(&mut self) -> bool {
        if self.inner.advance() {
            self.inner.token_mut().position = self.position;
            self.position += 1;
            true
        } else {
            false
        }
    }

    fn token(&self) -> &tantivy::tokenizer::Token {
        self.inner.token()
    }

    fn token_mut(&mut self) -> &mut tantivy::tokenizer::Token {
        self.inner.token_mut()
    }
}

/// Error type for indexer operations
#[derive(Error, Debug)]
pub enum IndexerError {
    #[error("Tantivy error: {0}")]
    Tantivy(#[from] tantivy::TantivyError),
    #[error("Directory error: {0}")]
    Directory(#[from] tantivy::directory::error::OpenDirectoryError),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}

pub type IndexerResult<T> = Result<T, IndexerError>;

#[derive(Debug, Clone)]
struct OwnedPrefixPreferenceQuery {
    raw_query_lower: String,
    stripped_query_lower: String,
}

impl OwnedPrefixPreferenceQuery {
    fn as_borrowed(&self) -> PrefixPreferenceQuery<'_> {
        PrefixPreferenceQuery {
            raw_query_lower: &self.raw_query_lower,
            stripped_query_lower: &self.stripped_query_lower,
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct PhaseTwoQuery<'a> {
    query_words: &'a [&'a str],
    query_words_lower: &'a [&'a str],
    joined_query_lower: Option<&'a str>,
    last_word_is_prefix: bool,
    prefix_preference: Option<PrefixPreferenceQuery<'a>>,
}

#[derive(Debug, Clone)]
struct WordFieldPlan {
    words: Vec<String>,
    last_word_is_prefix: bool,
    signal_min_chars: usize,
}

#[derive(Debug, Clone)]
enum PhaseOneQueryPlan {
    Trigram {
        recall: TrigramRecallPlan,
        word_field: WordFieldPlan,
    },
    WordSequence {
        recall: WordSequenceRecallPlan,
        word_field: WordFieldPlan,
    },
}

impl PhaseOneQueryPlan {
    fn word_field(&self) -> &WordFieldPlan {
        match self {
            Self::Trigram { word_field, .. } | Self::WordSequence { word_field, .. } => word_field,
        }
    }
}

#[derive(Debug, Clone)]
enum TrigramRecallPlan {
    FullString { query: String, words: Vec<String> },
    PerWord { query: String, words: Vec<String> },
}

#[derive(Debug, Clone)]
struct WordSequenceRecallPlan {
    words: Vec<String>,
    pair_min_match: usize,
    last_word_is_prefix: bool,
}

#[derive(Debug, Clone)]
struct OwnedPhaseTwoQuery {
    query_words: Vec<String>,
    query_words_lower: Vec<String>,
    joined_query_lower: Option<String>,
    last_word_is_prefix: bool,
    prefix_preference: Option<OwnedPrefixPreferenceQuery>,
}

#[cfg(feature = "perf-log")]
#[derive(Debug, Default, Clone, Copy)]
struct PhaseTwoCandidatePerf {
    doc_bytes: usize,
    prep_ns: u64,
    ranking: RankingPerfBreakdown,
}

#[cfg(feature = "perf-log")]
#[derive(Debug, Default, Clone, Copy)]
struct PhaseTwoPerfTotals {
    candidates_seen: usize,
    matched_candidates: usize,
    large_doc_candidates: usize,
    total_doc_bytes: usize,
    total_doc_words: usize,
    total_query_words: usize,
    total_raw_candidate_count: usize,
    total_trimmed_candidate_count: usize,
    prep_ns: u64,
    match_query_words_ns: u64,
    collect_candidates_ns: u64,
    alignment_ns: u64,
    quality_signals_ns: u64,
    exactness_ns: u64,
}

#[cfg(feature = "perf-log")]
impl PhaseTwoPerfTotals {
    fn record(&mut self, perf: PhaseTwoCandidatePerf, matched: bool) {
        self.candidates_seen += 1;
        self.matched_candidates += usize::from(matched);
        self.large_doc_candidates += usize::from(perf.doc_bytes > LARGE_DOC_THRESHOLD_BYTES);
        self.total_doc_bytes += perf.doc_bytes;
        self.total_doc_words += perf.ranking.doc_word_count;
        self.total_query_words += perf.ranking.query_word_count;
        self.total_raw_candidate_count += perf.ranking.raw_candidate_count;
        self.total_trimmed_candidate_count += perf.ranking.trimmed_candidate_count;
        self.prep_ns += perf.prep_ns;
        self.match_query_words_ns += perf.ranking.match_query_words_ns;
        self.collect_candidates_ns += perf.ranking.collect_candidates_ns;
        self.alignment_ns += perf.ranking.alignment_ns;
        self.quality_signals_ns += perf.ranking.quality_signals_ns;
        self.exactness_ns += perf.ranking.exactness_ns;
    }

    fn merge(&mut self, other: Self) {
        self.candidates_seen += other.candidates_seen;
        self.matched_candidates += other.matched_candidates;
        self.large_doc_candidates += other.large_doc_candidates;
        self.total_doc_bytes += other.total_doc_bytes;
        self.total_doc_words += other.total_doc_words;
        self.total_query_words += other.total_query_words;
        self.total_raw_candidate_count += other.total_raw_candidate_count;
        self.total_trimmed_candidate_count += other.total_trimmed_candidate_count;
        self.prep_ns += other.prep_ns;
        self.match_query_words_ns += other.match_query_words_ns;
        self.collect_candidates_ns += other.collect_candidates_ns;
        self.alignment_ns += other.alignment_ns;
        self.quality_signals_ns += other.quality_signals_ns;
        self.exactness_ns += other.exactness_ns;
    }
}

fn prepare_phase_two_query(query: &SearchQuery, recall_text: &str) -> OwnedPhaseTwoQuery {
    let query_words = crate::search::tokenize_words(recall_text)
        .into_iter()
        .map(|(_, _, word)| word)
        .collect::<Vec<_>>();
    let query_words_lower = query_words.iter().map(|word| word.to_lowercase()).collect();
    let joined_query_lower =
        (!query_words.is_empty()).then(|| query_words.join(" ").to_lowercase());
    let last_word_is_prefix = recall_text.ends_with(|c: char| c.is_alphanumeric());
    let prefix_preference = match query {
        SearchQuery::Plain { .. } => None,
        SearchQuery::PreferPrefix {
            raw_text,
            stripped_text,
        } => Some(OwnedPrefixPreferenceQuery {
            raw_query_lower: raw_text.to_lowercase(),
            stripped_query_lower: stripped_text.to_lowercase(),
        }),
    };

    OwnedPhaseTwoQuery {
        query_words,
        query_words_lower,
        joined_query_lower,
        last_word_is_prefix,
        prefix_preference,
    }
}

fn previous_char_boundary(content: &str, mut index: usize) -> usize {
    while index > 0 && !content.is_char_boundary(index) {
        index -= 1;
    }
    index
}

fn next_char_boundary(content: &str, mut index: usize) -> usize {
    while index < content.len() && !content.is_char_boundary(index) {
        index += 1;
    }
    index.min(content.len())
}

fn normalized_slice_bounds(
    content: &str,
    search_start: usize,
    search_end: usize,
) -> Option<(usize, usize)> {
    let start = next_char_boundary(content, search_start.min(content.len()));
    let end = previous_char_boundary(content, search_end.min(content.len()));
    (start < end).then_some((start, end))
}

fn snapped_boundary_after(
    content: &str,
    search_start: usize,
    search_end: usize,
    preferred: usize,
) -> Option<usize> {
    let (search_start, search_end) = normalized_slice_bounds(content, search_start, search_end)?;
    let mut last_before = None;
    let mut first_after = None;
    for (offset, ch) in content[search_start..search_end].char_indices() {
        if !ch.is_whitespace() {
            continue;
        }
        let boundary = search_start + offset + ch.len_utf8();
        if boundary >= preferred {
            first_after = Some(boundary);
            break;
        }
        last_before = Some(boundary);
    }
    first_after.or(last_before)
}

fn snapped_boundary_before(
    content: &str,
    search_start: usize,
    search_end: usize,
    preferred: usize,
) -> Option<usize> {
    let (search_start, search_end) = normalized_slice_bounds(content, search_start, search_end)?;
    let mut last_before = None;
    let mut first_after = None;
    for (offset, ch) in content[search_start..search_end].char_indices() {
        if !ch.is_whitespace() {
            continue;
        }
        let boundary = search_start + offset + ch.len_utf8();
        if boundary <= preferred {
            last_before = Some(boundary);
        } else {
            first_after = Some(boundary);
            break;
        }
    }
    last_before.or(first_after)
}

fn snap_chunk_end(content: &str, start: usize, preferred_end: usize) -> usize {
    let min_end = next_char_boundary(content, start.saturating_add(1)).min(content.len());
    let preferred_end = previous_char_boundary(content, preferred_end.min(content.len()));
    if preferred_end <= min_end {
        return min_end;
    }
    let search_start = preferred_end
        .saturating_sub(CHUNK_BOUNDARY_SLACK_BYTES)
        .max(min_end);
    let search_end = next_char_boundary(
        content,
        (preferred_end + CHUNK_BOUNDARY_SLACK_BYTES).min(content.len()),
    );
    snapped_boundary_after(content, search_start, search_end, preferred_end)
        .unwrap_or(preferred_end)
        .max(min_end)
        .min(content.len())
}

fn snap_chunk_start(content: &str, preferred_start: usize, chunk_end: usize) -> usize {
    let chunk_end = previous_char_boundary(content, chunk_end.min(content.len()));
    if chunk_end <= 1 {
        return 0;
    }
    let max_start = previous_char_boundary(content, chunk_end.saturating_sub(1));
    let preferred_start = previous_char_boundary(content, preferred_start.min(max_start));
    let search_start = preferred_start.saturating_sub(CHUNK_BOUNDARY_SLACK_BYTES);
    let search_end = next_char_boundary(
        content,
        (preferred_start + CHUNK_BOUNDARY_SLACK_BYTES)
            .min(max_start)
            .min(content.len()),
    );
    snapped_boundary_before(content, search_start, search_end, preferred_start)
        .unwrap_or(preferred_start)
        .min(max_start)
}

fn chunk_slices(content: &str) -> Vec<ChunkSlice> {
    if content.len() <= CHUNK_PARENT_THRESHOLD_BYTES {
        return Vec::new();
    }

    let mut chunks = Vec::new();
    let mut start = 0usize;
    let mut index = 0u32;

    while start < content.len() {
        let preferred_end = (start + CHUNK_TARGET_BYTES).min(content.len());
        let end = if preferred_end == content.len() {
            content.len()
        } else {
            let preferred_end = previous_char_boundary(content, preferred_end);
            snap_chunk_end(content, start, preferred_end.max(start.saturating_add(1)))
        };

        chunks.push(ChunkSlice { index, start, end });
        index += 1;

        if end >= content.len() {
            break;
        }

        let preferred_start =
            previous_char_boundary(content, end.saturating_sub(CHUNK_OVERLAP_BYTES));
        let next_start = next_char_boundary(
            content,
            snap_chunk_start(content, preferred_start, end).max(start.saturating_add(1)),
        );
        if next_start <= start || next_start >= end {
            start = end;
        } else {
            start = next_start;
        }
    }

    chunks
}

#[cfg(not(feature = "perf-log"))]
fn score_phase_two_candidate(
    candidate: &SearchCandidate,
    phase_two_query: PhaseTwoQuery<'_>,
    now: i64,
) -> PhaseTwoCandidateScore {
    let content = candidate.content();
    let document = prepare_document_for_ranking(content);

    let bucket = compute_bucket_score(&ScoringContext {
        document: &document,
        query_words: phase_two_query.query_words,
        query_words_lower: phase_two_query.query_words_lower,
        joined_query_lower: phase_two_query.joined_query_lower,
        last_word_is_prefix: phase_two_query.last_word_is_prefix,
        prefix_preference: phase_two_query.prefix_preference,
        timestamp: candidate.timestamp,
        bm25_remainder: candidate.phase_one_score.bm25_remainder,
        now,
    });

    PhaseTwoCandidateScore {
        bucket: (bucket.words_matched_weight() > 0).then_some(bucket),
    }
}

#[cfg(feature = "perf-log")]
fn score_phase_two_candidate(
    candidate: &SearchCandidate,
    phase_two_query: PhaseTwoQuery<'_>,
    now: i64,
) -> PhaseTwoCandidateScore {
    let prep_start = std::time::Instant::now();
    let content = candidate.content();
    let document = prepare_document_for_ranking(content);
    let prep_ns = prep_start.elapsed().as_nanos() as u64;

    let (bucket, ranking) = compute_bucket_score_with_perf(&ScoringContext {
        document: &document,
        query_words: phase_two_query.query_words,
        query_words_lower: phase_two_query.query_words_lower,
        joined_query_lower: phase_two_query.joined_query_lower,
        last_word_is_prefix: phase_two_query.last_word_is_prefix,
        prefix_preference: phase_two_query.prefix_preference,
        timestamp: candidate.timestamp,
        bm25_remainder: candidate.phase_one_score.bm25_remainder,
        now,
    });

    PhaseTwoCandidateScore {
        bucket: (bucket.words_matched_weight() > 0).then_some(bucket),
        perf: PhaseTwoCandidatePerf {
            doc_bytes: content.len(),
            prep_ns,
            ranking,
        },
    }
}

struct PhaseTwoCandidateScore {
    bucket: Option<crate::ranking::BucketScore>,
    #[cfg(feature = "perf-log")]
    perf: PhaseTwoCandidatePerf,
}

struct PhaseTwoRun {
    scored: Vec<(crate::ranking::BucketScore, usize)>,
    #[cfg(feature = "perf-log")]
    perf: PhaseTwoPerfTotals,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct CollapsedDocAddress {
    item_id: i64,
    doc_address: DocAddress,
}

impl Eq for CollapsedDocAddress {}

impl Ord for CollapsedDocAddress {
    fn cmp(&self, other: &Self) -> Ordering {
        self.doc_address
            .cmp(&other.doc_address)
            .then_with(|| self.item_id.cmp(&other.item_id))
    }
}

impl PartialOrd for CollapsedDocAddress {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[derive(Debug, Clone, Copy)]
struct CollapsedDocHit {
    score: PhaseOneBlendedScore,
    address: CollapsedDocAddress,
}

struct CollapsedTopDocs {
    limit: usize,
    now: i64,
}

// Collect the best Phase 1 hit per parent item within a segment so large-document
// chunks are collapsed before we materialize stored docs or build the Phase 2 head.
struct CollapsedTopDocsSegmentCollector {
    segment_ord: u32,
    item_id_reader: tantivy::fastfield::Column<i64>,
    timestamp_reader: tantivy::fastfield::Column<i64>,
    parent_len_reader: tantivy::fastfield::Column<i64>,
    now: i64,
    docs_by_item: HashMap<i64, CollapsedDocHit>,
}

impl CollapsedTopDocsSegmentCollector {
    fn new(segment_ord: u32, segment_reader: &SegmentReader, now: i64) -> tantivy::Result<Self> {
        Ok(Self {
            segment_ord,
            item_id_reader: segment_reader
                .fast_fields()
                .i64("item_id")
                .expect("item_id fast field"),
            timestamp_reader: segment_reader
                .fast_fields()
                .i64("timestamp")
                .expect("timestamp fast field"),
            parent_len_reader: segment_reader
                .fast_fields()
                .i64("parent_len")
                .expect("parent_len fast field"),
            now,
            docs_by_item: HashMap::new(),
        })
    }
}

impl SegmentCollector for CollapsedTopDocsSegmentCollector {
    type Fruit = Vec<CollapsedDocHit>;

    fn collect(&mut self, doc: DocId, score: Score) {
        let item_id = self.item_id_reader.first(doc).unwrap_or(0);
        let timestamp = self.timestamp_reader.first(doc).unwrap_or(0);
        let parent_len = self.parent_len_reader.first(doc).unwrap_or(0).max(0) as usize;
        let blended = PhaseOneBlendedScore::decode(score, timestamp, parent_len, self.now);
        let hit = CollapsedDocHit {
            score: blended,
            address: CollapsedDocAddress {
                item_id,
                doc_address: DocAddress::new(self.segment_ord, doc),
            },
        };
        match self.docs_by_item.get(&item_id) {
            Some(existing) if !collapsed_hit_is_better(&hit, existing) => {}
            _ => {
                self.docs_by_item.insert(item_id, hit);
            }
        }
    }

    fn harvest(self) -> Self::Fruit {
        self.docs_by_item.into_values().collect()
    }
}

/// Phase 1 result carrying the structured blended score and doc address.
struct PhaseOneHit {
    score: PhaseOneBlendedScore,
    doc_address: DocAddress,
}

impl Collector for CollapsedTopDocs {
    type Fruit = Vec<PhaseOneHit>;
    type Child = CollapsedTopDocsSegmentCollector;

    fn for_segment(
        &self,
        segment_local_id: u32,
        segment: &SegmentReader,
    ) -> tantivy::Result<Self::Child> {
        CollapsedTopDocsSegmentCollector::new(segment_local_id, segment, self.now)
    }

    fn requires_scoring(&self) -> bool {
        true
    }

    fn merge_fruits(
        &self,
        segment_fruits: Vec<<Self::Child as SegmentCollector>::Fruit>,
    ) -> tantivy::Result<Self::Fruit> {
        let mut best_by_item: HashMap<i64, CollapsedDocHit> = HashMap::new();
        for segment_hits in segment_fruits {
            for hit in segment_hits {
                match best_by_item.get(&hit.address.item_id) {
                    Some(existing) if !collapsed_hit_is_better(&hit, existing) => {}
                    _ => {
                        best_by_item.insert(hit.address.item_id, hit);
                    }
                }
            }
        }

        let mut top_docs: TopNComputer<PhaseOneBlendedScore, CollapsedDocAddress> =
            TopNComputer::new(self.limit);
        for hit in best_by_item.into_values() {
            top_docs.push(hit.score, hit.address);
        }

        Ok(top_docs
            .into_sorted_vec()
            .into_iter()
            .map(|doc| PhaseOneHit {
                score: doc.feature,
                doc_address: doc.doc.doc_address,
            })
            .collect())
    }
}

fn collapsed_hit_is_better(candidate: &CollapsedDocHit, current: &CollapsedDocHit) -> bool {
    candidate.score > current.score
        || (candidate.score == current.score && candidate.address < current.address)
}

fn run_phase_two_head(
    head: PhaseTwoHead,
    candidates: &[SearchCandidate],
    phase_two_query: PhaseTwoQuery<'_>,
    now: i64,
    token: &CancellationToken,
) -> Result<PhaseTwoRun, IndexerError> {
    use rayon::prelude::*;

    const CANCELLATION_CHECK_CHUNK_SIZE: usize = 32;

    let head_candidates: Vec<(usize, SearchCandidate)> = head
        .into_indices()
        .into_iter()
        .map(|index| (index, candidates[index].clone()))
        .collect();

    let chunk_results: Vec<PhaseTwoRun> = head_candidates
        .par_chunks(CANCELLATION_CHECK_CHUNK_SIZE)
        .enumerate()
        .map(|(_chunk_index, chunk)| {
            let mut scored = Vec::with_capacity(chunk.len());
            #[cfg(feature = "perf-log")]
            let mut perf = PhaseTwoPerfTotals::default();

            for (_offset, candidate) in chunk.iter().enumerate() {
                if token.is_cancelled() {
                    break;
                }
                #[cfg(test)]
                test_support::on_phase_two_candidate(
                    _chunk_index * CANCELLATION_CHECK_CHUNK_SIZE + _offset,
                );
                let outcome = score_phase_two_candidate(&candidate.1, phase_two_query, now);
                #[cfg(feature = "perf-log")]
                perf.record(outcome.perf, outcome.bucket.is_some());
                if let Some(bucket) = outcome.bucket {
                    scored.push((bucket, candidate.0));
                }
            }

            PhaseTwoRun {
                scored,
                #[cfg(feature = "perf-log")]
                perf,
            }
        })
        .collect();

    if token.is_cancelled() {
        return Err(IndexerError::Tantivy(tantivy::TantivyError::InternalError(
            "search cancelled".into(),
        )));
    }

    let mut scored = Vec::new();
    #[cfg(feature = "perf-log")]
    let mut perf = PhaseTwoPerfTotals::default();

    for mut chunk_result in chunk_results {
        scored.append(&mut chunk_result.scored);
        #[cfg(feature = "perf-log")]
        perf.merge(chunk_result.perf);
    }

    Ok(PhaseTwoRun {
        scored,
        #[cfg(feature = "perf-log")]
        perf,
    })
}

/// Tantivy-based indexer with trigram tokenization
pub struct Indexer {
    index: Index,
    writer: RwLock<IndexWriter>,
    reader: RwLock<IndexReader>,
    item_id_field: Field,
    content_field: Field,
    content_words_field: Field,
    timestamp_field: Field,
    parent_len_field: Field,
    chunk_index_field: Field,
    chunk_start_field: Field,
    chunk_end_field: Field,
}

#[cfg(test)]
pub(crate) mod test_support {
    use once_cell::sync::Lazy;
    use parking_lot::Mutex;
    use std::sync::Arc;

    #[derive(Default, Clone)]
    pub(crate) struct SearchTestHooks {
        pub(crate) before_phase_two: Option<Arc<dyn Fn() + Send + Sync>>,
        pub(crate) on_phase_two_candidate: Option<Arc<dyn Fn(usize) + Send + Sync>>,
    }

    static HOOKS: Lazy<Mutex<SearchTestHooks>> =
        Lazy::new(|| Mutex::new(SearchTestHooks::default()));
    pub(crate) static HOOK_TEST_LOCK: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));

    pub(crate) struct SearchTestHookGuard;

    impl Drop for SearchTestHookGuard {
        fn drop(&mut self) {
            *HOOKS.lock() = SearchTestHooks::default();
        }
    }

    pub(crate) fn install_search_hooks(hooks: SearchTestHooks) -> SearchTestHookGuard {
        *HOOKS.lock() = hooks;
        SearchTestHookGuard
    }

    pub(crate) fn before_phase_two() {
        let callback = HOOKS.lock().before_phase_two.clone();
        if let Some(callback) = callback {
            callback();
        }
    }

    pub(crate) fn on_phase_two_candidate(index: usize) {
        let callback = HOOKS.lock().on_phase_two_candidate.clone();
        if let Some(callback) = callback {
            callback(index);
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum IndexInspection {
    Missing,
    RebuildRequired,
    Ready { doc_count: u64 },
}

impl Indexer {
    pub(crate) fn inspect(path: &Path) -> IndexerResult<IndexInspection> {
        if !path.exists() {
            return Ok(IndexInspection::Missing);
        }

        let dir = MmapDirectory::open(path)?;
        let index = match Index::open(dir) {
            Ok(index) => index,
            Err(_) => return Ok(IndexInspection::RebuildRequired),
        };

        if index.schema() != Self::build_schema() {
            return Ok(IndexInspection::RebuildRequired);
        }

        let reader = index
            .reader_builder()
            .reload_policy(ReloadPolicy::Manual)
            .try_into()?;

        Ok(IndexInspection::Ready {
            doc_count: reader.searcher().num_docs(),
        })
    }

    /// Create a new indexer at the given path.
    /// Automatically detects schema mismatches and rebuilds the index if needed.
    pub fn new(path: &Path) -> IndexerResult<Self> {
        if matches!(Self::inspect(path)?, IndexInspection::RebuildRequired) {
            std::fs::remove_dir_all(path)?;
        }

        let schema = Self::build_schema();
        std::fs::create_dir_all(path)?;
        let dir = MmapDirectory::open(path)?;
        let index = Index::open_or_create(dir, schema.clone())?;
        Self::register_tokenizer(&index);

        let writer = index.writer(50_000_000)?;
        let reader = index
            .reader_builder()
            .reload_policy(ReloadPolicy::Manual)
            .try_into()?;

        Ok(Self::from_parts(index, writer, reader, schema))
    }

    /// Create an in-memory indexer (for testing)
    #[cfg(test)]
    pub fn new_in_memory() -> IndexerResult<Self> {
        let schema = Self::build_schema();
        let index = Index::create_in_ram(schema.clone());
        Self::register_tokenizer(&index);

        let writer = index.writer(15_000_000)?;
        let reader = index
            .reader_builder()
            .reload_policy(ReloadPolicy::Manual)
            .try_into()?;

        Ok(Self::from_parts(index, writer, reader, schema))
    }

    fn from_parts(index: Index, writer: IndexWriter, reader: IndexReader, schema: Schema) -> Self {
        Self {
            item_id_field: schema.get_field("item_id").unwrap(),
            content_field: schema.get_field("content").unwrap(),
            content_words_field: schema.get_field("content_words").unwrap(),
            timestamp_field: schema.get_field("timestamp").unwrap(),
            parent_len_field: schema.get_field("parent_len").unwrap(),
            chunk_index_field: schema.get_field("chunk_index").unwrap(),
            chunk_start_field: schema.get_field("chunk_start").unwrap(),
            chunk_end_field: schema.get_field("chunk_end").unwrap(),
            index,
            writer: RwLock::new(writer),
            reader: RwLock::new(reader),
        }
    }

    fn build_schema() -> Schema {
        let mut builder = Schema::builder();
        builder.add_i64_field("item_id", STORED | FAST | INDEXED);

        // Content field with trigram tokenization
        let text_field_indexing = TextFieldIndexing::default()
            .set_tokenizer("trigram")
            .set_index_option(IndexRecordOption::WithFreqsAndPositions);
        let text_options = TextOptions::default()
            .set_indexing_options(text_field_indexing)
            .set_stored();
        builder.add_text_field("content", text_options);

        // Word-tokenized field for exact word matching and proximity queries.
        // Uses WithFreqsAndPositions to enable PhraseQuery with slop.
        let word_field_indexing = TextFieldIndexing::default()
            .set_tokenizer("default")
            .set_index_option(IndexRecordOption::WithFreqsAndPositions);
        let word_options = TextOptions::default().set_indexing_options(word_field_indexing);
        builder.add_text_field("content_words", word_options);

        builder.add_i64_field("timestamp", STORED | FAST);
        builder.add_i64_field("parent_len", STORED | FAST);
        builder.add_i64_field("chunk_index", STORED);
        builder.add_i64_field("chunk_start", STORED);
        builder.add_i64_field("chunk_end", STORED);
        builder.build()
    }

    /// Register the trigram tokenizer with the index.
    /// NgramTokenizer assigns position=0 to all tokens, breaking PhraseQuery.
    /// IncrementPositionFilter fixes this by assigning incrementing positions.
    fn register_tokenizer(index: &Index) {
        let tokenizer = TextAnalyzer::builder(NgramTokenizer::new(3, 3, false).unwrap())
            .filter(tantivy::tokenizer::LowerCaser)
            .filter(IncrementPositionFilter)
            .build();
        index.tokenizers().register("trigram", tokenizer);
    }

    fn add_search_unit_document(
        &self,
        writer: &IndexWriter,
        item_id: i64,
        content: &str,
        timestamp: i64,
        parent_len: usize,
        chunk: Option<ChunkSlice>,
    ) -> IndexerResult<()> {
        let mut doc = tantivy::TantivyDocument::default();
        doc.add_i64(self.item_id_field, item_id);
        doc.add_text(self.content_field, content);
        doc.add_text(self.content_words_field, content);
        doc.add_i64(self.timestamp_field, timestamp);
        doc.add_i64(self.parent_len_field, parent_len as i64);
        doc.add_i64(
            self.chunk_index_field,
            chunk.map(|chunk| chunk.index as i64).unwrap_or(-1),
        );
        doc.add_i64(
            self.chunk_start_field,
            chunk.map(|chunk| chunk.start as i64).unwrap_or(0),
        );
        doc.add_i64(
            self.chunk_end_field,
            chunk
                .map(|chunk| chunk.end as i64)
                .unwrap_or(parent_len as i64),
        );
        writer.add_document(doc)?;
        Ok(())
    }

    /// Add or update a document in the index
    pub fn add_document(&self, id: i64, content: &str, timestamp: i64) -> IndexerResult<()> {
        let writer = self.writer.read();
        let parent_len = content.len();

        // Delete existing document with same ID (upsert semantics)
        let id_term = tantivy::Term::from_field_i64(self.item_id_field, id);
        writer.delete_term(id_term);

        if parent_len > CHUNK_PARENT_THRESHOLD_BYTES {
            for chunk in chunk_slices(content) {
                self.add_search_unit_document(
                    &writer,
                    id,
                    &content[chunk.start..chunk.end],
                    timestamp,
                    parent_len,
                    Some(chunk),
                )?;
            }
        } else {
            self.add_search_unit_document(&writer, id, content, timestamp, parent_len, None)?;
        }

        Ok(())
    }

    pub fn commit(&self) -> IndexerResult<()> {
        self.writer.write().commit()?;
        self.reader.write().reload()?;
        Ok(())
    }

    pub fn delete_document(&self, id: i64) -> IndexerResult<()> {
        let writer = self.writer.read();
        let id_term = tantivy::Term::from_field_i64(self.item_id_field, id);
        writer.delete_term(id_term);
        Ok(())
    }

    /// Tokenize text using the trigram tokenizer and return terms for the content field.
    fn trigram_terms(&self, text: &str) -> Vec<Term> {
        let mut tokenizer = self.index.tokenizers().get("trigram").unwrap();
        let mut stream = tokenizer.token_stream(text);
        let mut terms = Vec::new();
        while let Some(token) = stream.next() {
            terms.push(Term::from_field_text(self.content_field, &token.text));
        }
        terms
    }

    /// Generate trigram terms from transposition variants of short words (3-4 chars).
    /// Returns only novel terms not already in `seen`.
    fn transposition_trigrams(
        &self,
        words: &[&str],
        seen: &mut std::collections::HashSet<Term>,
    ) -> Vec<Term> {
        let mut extra = Vec::new();
        for word in words {
            if word.len() >= 3 && word.len() <= 4 {
                let chars: Vec<char> = word.chars().collect();
                for i in 0..chars.len() - 1 {
                    let mut v = chars.clone();
                    v.swap(i, i + 1);
                    let variant: String = v.into_iter().collect();
                    if variant == *word {
                        continue;
                    }
                    for term in self.trigram_terms(&variant) {
                        if seen.insert(term.clone()) {
                            extra.push(term);
                        }
                    }
                }
            }
        }
        extra
    }

    /// Two-phase search: indexed recall (Phase 1) + bucket re-ranking (Phase 2).
    /// Phase 1 gets a broad candidate set from Tantivy; Phase 2 applies the
    /// stricter bucket-ranking policy used by the rest of the search stack.
    pub fn search(&self, query: &str, limit: usize) -> IndexerResult<Vec<SearchCandidate>> {
        let parsed = SearchQuery::parse(query);
        self.search_parsed(&parsed, limit, &CancellationToken::new())
    }

    pub(crate) fn search_parsed(
        &self,
        query: &SearchQuery,
        limit: usize,
        token: &CancellationToken,
    ) -> IndexerResult<Vec<SearchCandidate>> {
        #[cfg(feature = "perf-log")]
        let t0 = std::time::Instant::now();
        let recall_text = query.recall_text();
        let phase_one_plan = self.plan_phase_one_query(recall_text);
        let candidates = self.phase_one_recall(&phase_one_plan, limit)?;
        #[cfg(feature = "perf-log")]
        let t1 = std::time::Instant::now();

        if candidates.is_empty() || recall_text.split_whitespace().count() == 0 {
            #[cfg(feature = "perf-log")]
            eprintln!(
                "[perf] phase1={:.1}ms candidates=0",
                (t1 - t0).as_secs_f64() * 1000.0
            );
            return Ok(candidates);
        }

        // Phase 2: Bucket re-ranking (parallelized — compute_bucket_score is a pure function)
        if token.is_cancelled() {
            return Err(IndexerError::Tantivy(tantivy::TantivyError::InternalError(
                "search cancelled".into(),
            )));
        }
        #[cfg(test)]
        test_support::before_phase_two();
        let phase_two_query_owned = prepare_phase_two_query(query, recall_text);
        let query_words: Vec<&str> = phase_two_query_owned
            .query_words
            .iter()
            .map(String::as_str)
            .collect();
        let query_words_lower: Vec<&str> = phase_two_query_owned
            .query_words_lower
            .iter()
            .map(String::as_str)
            .collect();
        let phase_two_query = PhaseTwoQuery {
            query_words: &query_words,
            query_words_lower: &query_words_lower,
            joined_query_lower: phase_two_query_owned.joined_query_lower.as_deref(),
            last_word_is_prefix: phase_two_query_owned.last_word_is_prefix,
            prefix_preference: phase_two_query_owned
                .prefix_preference
                .as_ref()
                .map(OwnedPrefixPreferenceQuery::as_borrowed),
        };
        let now = Utc::now().timestamp();
        let phase_two_head = PhaseOneAdmissionPolicy::select_phase_two_head(&candidates);
        let PhaseTwoRun {
            mut scored,
            #[cfg(feature = "perf-log")]
                perf: phase_two_perf,
        } = run_phase_two_head(phase_two_head, &candidates, phase_two_query, now, token)?;

        scored.sort_unstable_by(|a, b| b.0.cmp(&a.0));
        let scored_indices: HashSet<usize> = scored.iter().map(|(_, index)| *index).collect();

        #[cfg(feature = "perf-log")]
        {
            let t2 = std::time::Instant::now();
            eprintln!(
                "[perf] phase1={:.1}ms phase2={:.1}ms candidates={}",
                (t1 - t0).as_secs_f64() * 1000.0,
                (t2 - t1).as_secs_f64() * 1000.0,
                scored.len(),
            );
            if phase_two_perf.candidates_seen > 0 {
                let candidates_seen = phase_two_perf.candidates_seen as f64;
                let query_words_total = phase_two_perf.total_query_words.max(1) as f64;
                eprintln!(
                    "[perf] phase2_breakdown seen={} matched={} large_docs={} avg_doc_bytes={:.0} avg_doc_words={:.1} prep_sum={:.1}ms match_sum={:.1}ms collect_sum={:.1}ms align_sum={:.1}ms quality_sum={:.1}ms exactness_sum={:.1}ms raw_matches_per_query_word={:.2} trimmed_matches_per_query_word={:.2}",
                    phase_two_perf.candidates_seen,
                    phase_two_perf.matched_candidates,
                    phase_two_perf.large_doc_candidates,
                    phase_two_perf.total_doc_bytes as f64 / candidates_seen,
                    phase_two_perf.total_doc_words as f64 / candidates_seen,
                    phase_two_perf.prep_ns as f64 / 1_000_000.0,
                    phase_two_perf.match_query_words_ns as f64 / 1_000_000.0,
                    phase_two_perf.collect_candidates_ns as f64 / 1_000_000.0,
                    phase_two_perf.alignment_ns as f64 / 1_000_000.0,
                    phase_two_perf.quality_signals_ns as f64 / 1_000_000.0,
                    phase_two_perf.exactness_ns as f64 / 1_000_000.0,
                    phase_two_perf.total_raw_candidate_count as f64 / query_words_total,
                    phase_two_perf.total_trimmed_candidate_count as f64 / query_words_total,
                );
            }
        }

        let mut candidate_slots: Vec<Option<SearchCandidate>> =
            candidates.into_iter().map(Some).collect();
        for &(_, index) in &scored {
            if let Some(candidate) = candidate_slots[index].as_mut() {
                candidate.set_scoring_phase(crate::candidate::ScoringPhase::PhaseTwoScored);
            }
        }
        let mut ordered = Vec::new();
        ordered.extend(
            scored
                .into_iter()
                .filter_map(|(_, index)| candidate_slots[index].take()),
        );
        // Tail: unscored candidates that didn't go through Phase 2.
        // Require at least 40% of query words to have word-level matches;
        // pure trigram coincidences without sufficient word overlap are noise.
        let word_field = phase_one_plan.word_field();
        let query_word_count = word_field
            .words
            .iter()
            .filter(|word| word.chars().count() >= word_field.signal_min_chars)
            .count() as u32;
        let min_word_matches = if query_word_count > 0 {
            (query_word_count * 2 / 5).max(1) // 40%, at least 1
        } else {
            0
        };
        ordered.extend(
            candidate_slots
                .into_iter()
                .enumerate()
                .filter(|(index, _)| !scored_indices.contains(index))
                .filter_map(|(_, candidate)| candidate)
                .filter(|candidate| candidate.word_match_count() >= min_word_matches),
        );
        ordered.truncate(limit);

        Ok(ordered)
    }

    fn candidate_from_doc(
        &self,
        doc: &tantivy::TantivyDocument,
        phase_one_score: PhaseOneBlendedScore,
    ) -> SearchCandidate {
        let item_id = doc
            .get_first(self.item_id_field)
            .and_then(|value| value.as_i64())
            .unwrap_or(0);
        let timestamp = doc
            .get_first(self.timestamp_field)
            .and_then(|value| value.as_i64())
            .unwrap_or(0);
        let parent_len = doc
            .get_first(self.parent_len_field)
            .and_then(|value| value.as_i64())
            .unwrap_or(0)
            .max(0) as usize;
        let content: std::sync::Arc<str> = doc
            .get_first(self.content_field)
            .and_then(|value| value.as_str())
            .unwrap_or("")
            .to_string()
            .into();
        let chunk_index = doc
            .get_first(self.chunk_index_field)
            .and_then(|value| value.as_i64())
            .unwrap_or(-1);

        let match_context = if chunk_index >= 0 {
            let chunk_start = doc
                .get_first(self.chunk_start_field)
                .and_then(|value| value.as_i64())
                .unwrap_or(0)
                .max(0) as usize;
            let chunk_end = doc
                .get_first(self.chunk_end_field)
                .and_then(|value| value.as_i64())
                .unwrap_or(parent_len as i64)
                .max(0) as usize;
            SearchMatchContext::Chunk(ChunkMatchContext::new(
                content,
                parent_len,
                chunk_index as u32,
                chunk_start,
                chunk_end,
            ))
        } else {
            SearchMatchContext::WholeItem(WholeItemMatchContext::new(content, parent_len))
        };

        SearchCandidate::new(item_id, timestamp, phase_one_score, match_context)
    }

    /// Phase 1: indexed recall over whole items and chunks.
    ///
    /// Depending on the query shape, recall uses either:
    /// - trigram BM25 over the raw content field, or
    /// - adjacent word-sequence phrases over `content_words`
    ///
    /// Retrieves unit hits in increasing batches, then collapses them to one
    /// candidate per parent item before Phase 2.
    fn phase_one_recall(
        &self,
        plan: &PhaseOneQueryPlan,
        _limit: usize,
    ) -> IndexerResult<Vec<SearchCandidate>> {
        let reader = self.reader.read();
        let searcher = reader.searcher();
        let final_query = self.build_phase_one_query(plan);
        let now = Utc::now().timestamp();
        let mut collapsed = Vec::new();

        for raw_limit in RAW_RECALL_BATCHES {
            let top_collector = CollapsedTopDocs {
                limit: raw_limit,
                now,
            };

            let top_docs = searcher.search(final_query.as_ref(), &top_collector)?;
            let last_score = top_docs.last().map(|hit| hit.score);
            let top_doc_count = top_docs.len();
            let mut batch_collapsed = Vec::with_capacity(top_doc_count);
            for hit in top_docs {
                let doc: tantivy::TantivyDocument = searcher.doc(hit.doc_address)?;
                batch_collapsed.push(self.candidate_from_doc(&doc, hit.score));
            }

            collapsed = batch_collapsed;
            if top_doc_count < raw_limit
                || PhaseOneAdmissionPolicy::should_stop_recall(&collapsed, last_score)
            {
                break;
            }
        }

        Ok(collapsed)
    }

    fn plan_phase_one_query(&self, query: &str) -> PhaseOneQueryPlan {
        let word_field_words = search::tokenize_words(query)
            .into_iter()
            .map(|(_, _, word)| word)
            .filter(|word| search::is_word_token(word))
            .collect::<Vec<_>>();
        let last_word_is_prefix = query.ends_with(|c: char| c.is_alphanumeric());

        if let Some(recall) =
            Self::plan_word_sequence_recall(&word_field_words, last_word_is_prefix)
        {
            return PhaseOneQueryPlan::WordSequence {
                recall,
                word_field: WordFieldPlan {
                    words: word_field_words,
                    last_word_is_prefix,
                    signal_min_chars: 1,
                },
            };
        }

        let words = query
            .split_whitespace()
            .map(|word| word.to_string())
            .collect::<Vec<_>>();
        let recall = if words.len() >= 4 && self.has_per_word_trigrams(&words) {
            TrigramRecallPlan::PerWord {
                query: query.to_string(),
                words,
            }
        } else {
            TrigramRecallPlan::FullString {
                query: query.to_string(),
                words,
            }
        };

        PhaseOneQueryPlan::Trigram {
            recall,
            word_field: WordFieldPlan {
                words: word_field_words,
                last_word_is_prefix,
                signal_min_chars: 2,
            },
        }
    }

    fn plan_word_sequence_recall(
        words: &[String],
        last_word_is_prefix: bool,
    ) -> Option<WordSequenceRecallPlan> {
        if words.len() < 2 {
            return None;
        }

        let trigrammable_words = words
            .iter()
            .filter(|word| word.chars().count() >= search::MIN_TRIGRAM_QUERY_LEN)
            .count();
        let has_no_trigrammable_words = trigrammable_words == 0;
        let lacks_long_query_coverage =
            words.len() >= 4 && (trigrammable_words < 2 || trigrammable_words * 2 < words.len());

        if !has_no_trigrammable_words && !lacks_long_query_coverage {
            return None;
        }

        let pair_count = words.len() - 1;
        let pair_min_match = match pair_count {
            0 => return None,
            1 | 2 => pair_count,
            _ => (pair_count * 2).div_ceil(3).max(2),
        };

        Some(WordSequenceRecallPlan {
            words: words.to_vec(),
            pair_min_match,
            last_word_is_prefix,
        })
    }

    fn has_per_word_trigrams(&self, words: &[String]) -> bool {
        words
            .iter()
            .any(|word| !self.trigram_terms(word).is_empty())
    }

    /// Build FuzzyTermQuery clauses on the word-tokenized field.
    /// For each query word with 3+ chars, creates a Levenshtein DFA query
    /// that catches substitutions, insertions, and deletions that trigrams miss.
    ///
    /// Only active for queries with 1-3 words. For 4+ word queries, the
    /// correctly-typed words provide enough trigrams for the trigram pathway;
    /// adding fuzzy clauses would recall scattered common-word matches.
    fn build_fuzzy_word_clauses(
        &self,
        words: &[String],
        last_word_is_prefix: bool,
    ) -> Vec<Box<dyn tantivy::query::Query>> {
        if words.len() >= 4 {
            return Vec::new();
        }

        let mut clauses = Vec::new();
        for (i, word) in words.iter().enumerate() {
            let len = word.chars().count();
            if len < 3 {
                continue;
            }
            let distance = crate::ranking::max_edit_distance(len);
            if distance == 0 {
                continue;
            }
            let term = Term::from_field_text(self.content_words_field, &word.to_lowercase());
            let is_last = i == words.len() - 1;
            let q: Box<dyn tantivy::query::Query> = if is_last && last_word_is_prefix {
                Box::new(FuzzyTermQuery::new_prefix(term, distance, true))
            } else {
                Box::new(FuzzyTermQuery::new(term, distance, true))
            };
            clauses.push(q);
        }
        clauses
    }

    fn build_trailing_prefix_query(
        &self,
        words: &[String],
        last_word_is_prefix: bool,
    ) -> Option<PhrasePrefixQuery> {
        if !last_word_is_prefix || words.len() < 2 {
            return None;
        }

        let terms = words
            .iter()
            .map(|word| Term::from_field_text(self.content_words_field, &word.to_lowercase()))
            .collect();

        Some(PhrasePrefixQuery::new(terms))
    }

    /// Build word-level boost clauses for exact word matching and proximity.
    ///
    /// Uses exact word TermQuery boosts + proximity PhraseQuery boosts.
    /// The boosts are scaled so that proximity differences become meaningful
    /// tiebreakers within the same recency bucket.
    ///
    /// Boost scale:
    /// - Exact word match: 2.0x (approximates words_matched_weight)
    /// - Word proximity (slop=3): PROXIMITY_BOOST_SCALE (encodes proximity tier)
    ///
    /// The PROXIMITY_BOOST_SCALE creates distinct score bands that tweak_score
    /// can decode and convert to an additive proximity tier.
    fn build_word_boosts(
        &self,
        word_field: &WordFieldPlan,
    ) -> Vec<(Occur, Box<dyn tantivy::query::Query>)> {
        let mut boosts: Vec<(Occur, Box<dyn tantivy::query::Query>)> = Vec::new();

        // Exact word TermQuery boosts (2.0x) — match words at word boundaries
        // This helps approximate Phase 2's words_matched_weight priority.
        for word in &word_field.words {
            if word.chars().count() < word_field.signal_min_chars {
                continue;
            }
            let term = Term::from_field_text(self.content_words_field, &word.to_lowercase());
            let term_q = TermQuery::new(term, IndexRecordOption::Basic);
            let boosted: Box<dyn tantivy::query::Query> =
                Box::new(BoostQuery::new(Box::new(term_q), 2.0));
            boosts.push((Occur::Should, boosted));
        }

        // Word proximity PhraseQuery with slop=3 (allows 3 intervening words).
        // Uses a large boost to create score bands that tweak_score decodes.
        if word_field.words.len() >= 2 {
            let terms: Vec<Term> = word_field
                .words
                .iter()
                .filter(|word| word.chars().count() >= word_field.signal_min_chars)
                .map(|w| Term::from_field_text(self.content_words_field, &w.to_lowercase()))
                .collect();
            if terms.len() >= 2 {
                let phrase_q = PhraseQuery::new_with_offset_and_slop(
                    terms.into_iter().enumerate().collect(),
                    3, // slop: allow up to 3 intervening words
                );
                let boosted: Box<dyn tantivy::query::Query> =
                    Box::new(BoostQuery::new(Box::new(phrase_q), PROXIMITY_BOOST_SCALE));
                boosts.push((Occur::Should, boosted));
            }
        }

        if let Some(prefix_query) =
            self.build_trailing_prefix_query(&word_field.words, word_field.last_word_is_prefix)
        {
            let boosted: Box<dyn tantivy::query::Query> = Box::new(BoostQuery::new(
                Box::new(prefix_query),
                PROXIMITY_BOOST_SCALE,
            ));
            boosts.push((Occur::Should, boosted));
        }

        boosts
    }

    /// Encode word-match count into the Tantivy score.
    ///
    /// Each query word meeting the plan's minimum length gets a `ConstScoreQuery`
    /// that adds
    /// [`WORD_MATCH_SIGNAL`] when that word appears in `content_words`.
    /// The count is recovered by [`PhaseOneBlendedScore::decode`] as
    /// `floor(raw_score / WORD_MATCH_SIGNAL)`.
    fn encode_word_match_signals(
        words: &[String],
        content_words_field: Field,
        min_chars: usize,
    ) -> Vec<(Occur, Box<dyn tantivy::query::Query>)> {
        words
            .iter()
            .filter(|word| word.chars().count() >= min_chars)
            .map(|word| {
                let term = Term::from_field_text(content_words_field, &word.to_lowercase());
                let term_q = TermQuery::new(term, IndexRecordOption::Basic);
                let signal = ConstScoreQuery::new(Box::new(term_q), WORD_MATCH_SIGNAL);
                (
                    Occur::Should,
                    Box::new(signal) as Box<dyn tantivy::query::Query>,
                )
            })
            .collect()
    }

    /// Build the Phase 1 Tantivy query for the current recall plan.
    ///
    fn build_phase_one_query(&self, plan: &PhaseOneQueryPlan) -> Box<dyn tantivy::query::Query> {
        let recall: Box<dyn tantivy::query::Query> = match plan {
            PhaseOneQueryPlan::Trigram { recall, word_field } => {
                self.build_trigram_recall_query(recall, word_field)
            }
            PhaseOneQueryPlan::WordSequence { recall, .. } => {
                self.build_word_sequence_recall_query(recall)
            }
        };

        let word_field = plan.word_field();
        let all_boosts = self.build_word_boosts(word_field);

        if all_boosts.is_empty() {
            recall
        } else {
            let mut outer: Vec<(Occur, Box<dyn tantivy::query::Query>)> = Vec::new();
            outer.push((Occur::Must, recall));
            outer.extend(all_boosts);
            outer.extend(Self::encode_word_match_signals(
                &word_field.words,
                self.content_words_field,
                word_field.signal_min_chars,
            ));
            Box::new(BooleanQuery::new(outer))
        }
    }

    fn build_word_sequence_recall_query(
        &self,
        recall: &WordSequenceRecallPlan,
    ) -> Box<dyn tantivy::query::Query> {
        let pair_queries: Vec<(Occur, Box<dyn tantivy::query::Query>)> = recall
            .words
            .windows(2)
            .enumerate()
            .map(|(index, words)| {
                let pair_terms = words
                    .iter()
                    .map(|word| {
                        Term::from_field_text(self.content_words_field, &word.to_lowercase())
                    })
                    .collect::<Vec<_>>();
                let is_last_pair = index + 1 == recall.words.len() - 1;
                let query: Box<dyn tantivy::query::Query> =
                    if is_last_pair && recall.last_word_is_prefix {
                        Box::new(PhrasePrefixQuery::new(pair_terms))
                    } else {
                        Box::new(PhraseQuery::new(pair_terms))
                    };
                (Occur::Should, query)
            })
            .collect();

        if pair_queries.len() == 1 {
            return pair_queries
                .into_iter()
                .next()
                .map(|(_, query)| query)
                .unwrap_or_else(|| Box::new(BooleanQuery::new(Vec::new())));
        }

        let mut sequence_query = BooleanQuery::new(pair_queries);
        sequence_query.set_minimum_number_should_match(recall.pair_min_match);
        Box::new(sequence_query)
    }

    fn build_trigram_recall_query(
        &self,
        recall: &TrigramRecallPlan,
        word_field: &WordFieldPlan,
    ) -> Box<dyn tantivy::query::Query> {
        let (query, words, is_long_query) = match recall {
            TrigramRecallPlan::FullString { query, words } => (query.as_str(), words, false),
            TrigramRecallPlan::PerWord { query, words } => (query.as_str(), words, true),
        };
        let word_refs = words.iter().map(String::as_str).collect::<Vec<_>>();
        let (terms, mut seen) = if is_long_query {
            // Long query: per-word trigrams only (skip cross-word boundary trigrams)
            let mut all_terms = Vec::new();
            let mut seen = std::collections::HashSet::new();
            for word in &word_refs {
                for term in self.trigram_terms(word) {
                    if seen.insert(term.clone()) {
                        all_terms.push(term);
                    }
                }
            }
            (all_terms, seen)
        } else {
            // Short query: full-string trigrams (includes cross-word boundaries)
            let terms = self.trigram_terms(query);
            let seen = terms.iter().cloned().collect();
            (terms, seen)
        };

        if terms.is_empty() {
            return self
                .build_trailing_prefix_query(&word_field.words, word_field.last_word_is_prefix)
                .map(|query| Box::new(query) as Box<dyn tantivy::query::Query>)
                .unwrap_or_else(|| Box::new(BooleanQuery::new(Vec::new())));
        }

        // Compute min_match from original term count BEFORE adding variants.
        // Transposition variants can only help recall, never raise the threshold.
        let num_terms = terms.len();

        // Add trigrams from transposition variants of short words (3-4 chars)
        let variant_terms = self.transposition_trigrams(&word_refs, &mut seen);

        let subqueries: Vec<_> = terms
            .into_iter()
            .chain(variant_terms)
            .map(|term| {
                let q: Box<dyn tantivy::query::Query> =
                    Box::new(TermQuery::new(term, IndexRecordOption::Basic));
                (Occur::Should, q)
            })
            .collect();
        let mut recall_query = BooleanQuery::new(subqueries);

        if num_terms >= 3 {
            let min_match = if is_long_query {
                // Per-word trigrams are individually meaningful (no cross-word
                // boundary noise like "lo " or " wo"), so common English words
                // match easily. Use a strict 4/5 threshold to reject scattered
                // coincidences.
                (4 * num_terms / 5).max(3)
            } else if num_terms >= 20 {
                4 * num_terms / 5
            } else if num_terms >= 7 {
                (num_terms * 2 / 3).max(5)
            } else {
                num_terms.div_ceil(2)
            };
            recall_query.set_minimum_number_should_match(min_match);
        }

        // Build the recall part: trigram OR fuzzy-word pathways
        let fuzzy_clauses =
            self.build_fuzzy_word_clauses(&word_field.words, word_field.last_word_is_prefix);
        let trailing_prefix_recall = self
            .build_trailing_prefix_query(&word_field.words, word_field.last_word_is_prefix)
            .map(|query| Box::new(query) as Box<dyn tantivy::query::Query>);
        if fuzzy_clauses.is_empty() && trailing_prefix_recall.is_none() {
            return Box::new(recall_query);
        }

        let mut recall_paths = vec![(
            Occur::Should,
            Box::new(recall_query) as Box<dyn tantivy::query::Query>,
        )];

        if !fuzzy_clauses.is_empty() {
            // Require at least half the fuzzy clauses to match. Since this
            // pathway is limited to 1-3 word queries, the threshold stays
            // tight enough to avoid scattered common-word matches.
            let n = fuzzy_clauses.len();
            let fuzzy_min = n.div_ceil(2);
            let fuzzy_subqueries: Vec<(Occur, Box<dyn tantivy::query::Query>)> = fuzzy_clauses
                .into_iter()
                .map(|query| (Occur::Should, query))
                .collect();
            let mut fuzzy_bool = BooleanQuery::new(fuzzy_subqueries);
            fuzzy_bool.set_minimum_number_should_match(fuzzy_min);
            recall_paths.push((
                Occur::Should,
                Box::new(fuzzy_bool) as Box<dyn tantivy::query::Query>,
            ));
        }

        if let Some(prefix_recall) = trailing_prefix_recall {
            recall_paths.push((Occur::Should, prefix_recall));
        }

        // OR: document passes if it matches any recall pathway.
        let mut combined = BooleanQuery::new(recall_paths);
        combined.set_minimum_number_should_match(1);
        Box::new(combined)
    }

    pub fn clear(&self) -> IndexerResult<()> {
        let mut writer = self.writer.write();
        writer.delete_all_documents()?;
        writer.commit()?;
        drop(writer);
        self.reader.write().reload()?;
        Ok(())
    }

    /// Get the number of documents in the index
    pub fn num_docs(&self) -> u64 {
        self.reader.read().searcher().num_docs()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn whole_candidate(id: i64, score: f32) -> SearchCandidate {
        SearchCandidate::new(
            id,
            0,
            PhaseOneBlendedScore::from_raw(score),
            SearchMatchContext::WholeItem(WholeItemMatchContext::new(
                std::sync::Arc::<str>::from("small match"),
                64,
            )),
        )
    }

    fn chunk_candidate(id: i64, score: f32, parent_len: usize) -> SearchCandidate {
        SearchCandidate::new(
            id,
            0,
            PhaseOneBlendedScore::from_raw(score),
            SearchMatchContext::Chunk(ChunkMatchContext::new(
                std::sync::Arc::<str>::from("chunk match"),
                parent_len,
                0,
                0,
                11,
            )),
        )
    }

    #[test]
    fn test_phrase_query_works_with_position_fix() {
        let indexer = Indexer::new_in_memory().unwrap();
        indexer.add_document(1, "hello world", 1000).unwrap();
        indexer.add_document(2, "shell output log", 1000).unwrap();
        indexer.commit().unwrap();

        let reader = indexer.reader.read();
        let searcher = reader.searcher();

        // PhraseQuery for "hello" should match doc 1 (contiguous "hello")
        // but NOT doc 2 (has "hel" from "shell" but not contiguous "hello")
        let phrase_terms = indexer.trigram_terms("hello");
        let phrase_q = tantivy::query::PhraseQuery::new(phrase_terms);
        let results = searcher
            .search(&phrase_q, &TopDocs::with_limit(10))
            .unwrap();
        assert_eq!(results.len(), 1, "PhraseQuery should find exactly 1 doc");
    }

    #[test]
    fn test_indexer_creation() {
        let indexer = Indexer::new_in_memory().unwrap();
        assert_eq!(indexer.num_docs(), 0);
    }

    #[test]
    fn test_delete_document() {
        let indexer = Indexer::new_in_memory().unwrap();

        indexer.add_document(1, "Hello World", 1000).unwrap();
        indexer.commit().unwrap();
        assert_eq!(indexer.num_docs(), 1);

        indexer.delete_document(1).unwrap();
        indexer.commit().unwrap();
        assert_eq!(indexer.num_docs(), 0);
    }

    #[test]
    fn test_upsert_semantics() {
        let indexer = Indexer::new_in_memory().unwrap();

        indexer.add_document(1, "Hello World", 1000).unwrap();
        indexer.commit().unwrap();
        assert_eq!(indexer.num_docs(), 1);

        // Update same ID - should replace, not duplicate
        indexer.add_document(1, "Updated content", 2000).unwrap();
        indexer.commit().unwrap();
        assert_eq!(indexer.num_docs(), 1);
    }

    #[test]
    fn test_clear() {
        let indexer = Indexer::new_in_memory().unwrap();

        for i in 0..10 {
            indexer
                .add_document(i, &format!("Item {}", i), i * 1000)
                .unwrap();
        }
        indexer.commit().unwrap();
        assert_eq!(indexer.num_docs(), 10);

        indexer.clear().unwrap();
        assert_eq!(indexer.num_docs(), 0);
    }

    #[test]
    fn test_transposition_recall_single_short_word() {
        // "teh" (transposition of "the") should recall a doc containing "the"
        let indexer = Indexer::new_in_memory().unwrap();
        indexer
            .add_document(1, "the quick brown fox", 1000)
            .unwrap();
        indexer.add_document(2, "a slow red dog", 1000).unwrap();
        indexer.commit().unwrap();

        let results = indexer.search("teh", 10).unwrap();
        let ids: Vec<i64> = results.iter().map(|c| c.id).collect();
        assert!(
            ids.contains(&1),
            "transposition 'teh' should recall doc with 'the', got {:?}",
            ids
        );
        assert!(!ids.contains(&2));
    }

    #[test]
    fn test_transposition_recall_multi_word() {
        // "form react" where "form" is a transposition of "from"
        let indexer = Indexer::new_in_memory().unwrap();
        indexer
            .add_document(1, "import Button from react", 1000)
            .unwrap();
        indexer
            .add_document(2, "html form element submit", 1000)
            .unwrap();
        indexer.commit().unwrap();

        let results = indexer.search("form react", 10).unwrap();
        let ids: Vec<i64> = results.iter().map(|c| c.id).collect();
        // Doc 1 should be recalled: "from" matches via transposition, "react" matches exact
        assert!(
            ids.contains(&1),
            "'form react' should recall doc with 'from react', got {:?}",
            ids
        );
    }

    #[test]
    fn test_transposition_trigrams_dedup() {
        // Variant trigrams that duplicate originals shouldn't cause issues
        let indexer = Indexer::new_in_memory().unwrap();
        indexer
            .add_document(1, "and also other things", 1000)
            .unwrap();
        indexer.commit().unwrap();

        // "adn" transpositions: "dan", "and" — "and" trigram already exists in doc
        let results = indexer.search("adn", 10).unwrap();
        let ids: Vec<i64> = results.iter().map(|c| c.id).collect();
        assert!(
            ids.contains(&1),
            "'adn' should recall doc with 'and', got {:?}",
            ids
        );
    }

    // ── Fuzzy word recall tests ─────────────────────────────────

    #[test]
    fn test_substitution_typo_recall() {
        // "tast" (substitution typo of "test") has zero trigram overlap:
        // tast → [tas, ast], test → [tes, est]. FuzzyTermQuery catches it.
        let indexer = Indexer::new_in_memory().unwrap();
        indexer.add_document(1, "run the test suite", 1000).unwrap();
        indexer.add_document(2, "a slow red dog", 1000).unwrap();
        indexer.commit().unwrap();

        let results = indexer.search("tast", 10).unwrap();
        let ids: Vec<i64> = results.iter().map(|c| c.id).collect();
        assert!(
            ids.contains(&1),
            "substitution 'tast' should recall doc with 'test', got {:?}",
            ids
        );
        assert!(!ids.contains(&2));
    }

    #[test]
    fn test_insertion_typo_recall() {
        // "tesst" (insertion typo of "test")
        let indexer = Indexer::new_in_memory().unwrap();
        indexer.add_document(1, "run the test suite", 1000).unwrap();
        indexer.add_document(2, "a slow red dog", 1000).unwrap();
        indexer.commit().unwrap();

        let results = indexer.search("tesst", 10).unwrap();
        let ids: Vec<i64> = results.iter().map(|c| c.id).collect();
        assert!(
            ids.contains(&1),
            "insertion 'tesst' should recall doc with 'test', got {:?}",
            ids
        );
        assert!(!ids.contains(&2));
    }

    #[test]
    fn test_deletion_typo_recall() {
        // "tst" (deletion typo of "test")
        let indexer = Indexer::new_in_memory().unwrap();
        indexer.add_document(1, "run the test suite", 1000).unwrap();
        indexer.add_document(2, "a slow red dog", 1000).unwrap();
        indexer.commit().unwrap();

        let results = indexer.search("tst", 10).unwrap();
        let ids: Vec<i64> = results.iter().map(|c| c.id).collect();
        assert!(
            ids.contains(&1),
            "deletion 'tst' should recall doc with 'test', got {:?}",
            ids
        );
    }

    #[test]
    fn test_fuzzy_word_multi_word_query() {
        // "quikc brown" — substitution typo in "quick"
        let indexer = Indexer::new_in_memory().unwrap();
        indexer
            .add_document(1, "the quick brown fox jumps", 1000)
            .unwrap();
        indexer
            .add_document(2, "a slow red dog sleeps", 1000)
            .unwrap();
        indexer.commit().unwrap();

        let results = indexer.search("quikc brown", 10).unwrap();
        let ids: Vec<i64> = results.iter().map(|c| c.id).collect();
        assert!(
            ids.contains(&1),
            "'quikc brown' should recall doc with 'quick brown', got {:?}",
            ids
        );
        assert!(!ids.contains(&2));
    }

    #[test]
    fn test_existing_trigram_recall_unchanged() {
        // Exact match still works through the trigram pathway
        let indexer = Indexer::new_in_memory().unwrap();
        indexer
            .add_document(1, "hello world greeting", 1000)
            .unwrap();
        indexer
            .add_document(2, "goodbye universe farewell", 1000)
            .unwrap();
        indexer.commit().unwrap();

        let results = indexer.search("hello", 10).unwrap();
        let ids: Vec<i64> = results.iter().map(|c| c.id).collect();
        assert!(
            ids.contains(&1),
            "exact 'hello' should recall doc 1, got {:?}",
            ids
        );
        assert!(!ids.contains(&2));
    }

    #[test]
    fn test_chunked_parent_collapses_to_single_candidate() {
        let indexer = Indexer::new_in_memory().unwrap();
        let repeated_marker = "needlechunk ";
        let content =
            repeated_marker.repeat((CHUNK_PARENT_THRESHOLD_BYTES / repeated_marker.len()) + 4096);
        indexer.add_document(1, &content, 1000).unwrap();
        indexer.commit().unwrap();

        let results = indexer.search("needlechunk", 20).unwrap();
        let ids: Vec<i64> = results.iter().map(|candidate| candidate.id).collect();
        assert_eq!(ids, vec![1], "chunk matches should collapse to one parent");
        assert!(matches!(
            results[0].match_context(),
            SearchMatchContext::Chunk(_)
        ));
    }

    #[test]
    fn test_chunk_slices_preserve_utf8_boundaries() {
        let multibyte = "\u{E0061}";
        let content = format!(
            "{}needle {}",
            format!("word{multibyte} ").repeat((CHUNK_PARENT_THRESHOLD_BYTES / 10) + 4096),
            multibyte
        );

        let slices = chunk_slices(&content);
        assert!(!slices.is_empty());
        for slice in slices {
            assert!(content.is_char_boundary(slice.start));
            assert!(content.is_char_boundary(slice.end));
            assert!(slice.start < slice.end);
        }
    }

    #[test]
    fn test_large_parent_stays_out_of_bounded_phase_two_head() {
        let mut candidates: Vec<SearchCandidate> = (0..70)
            .map(|i| whole_candidate(i, 1_000.0 - i as f32))
            .collect();
        candidates.push(chunk_candidate(
            999,
            900.0,
            CHUNK_PARENT_THRESHOLD_BYTES + 1,
        ));

        let head = PhaseOneAdmissionPolicy::select_phase_two_head(&candidates).into_indices();
        assert_eq!(head.len(), PhaseOneAdmissionPolicy::REGULAR_HEAD_LIMIT);
        assert!(
            head.iter().all(|&index| candidates[index].id != 999),
            "large parent should stay out of the bounded phase-two head when regular matches fill it"
        );
        assert!(head
            .iter()
            .all(|&index| !PhaseOneAdmissionPolicy::is_large_parent(
                candidates[index].parent_len()
            )));
    }

    #[test]
    fn test_large_parents_backfill_phase_two_when_regular_matches_are_sparse() {
        let candidates = vec![
            whole_candidate(1, 1_000.0),
            whole_candidate(2, 999.0),
            chunk_candidate(100, 998.0, CHUNK_PARENT_THRESHOLD_BYTES + 1),
            chunk_candidate(101, 997.0, CHUNK_PARENT_THRESHOLD_BYTES + 1),
            chunk_candidate(102, 996.0, CHUNK_PARENT_THRESHOLD_BYTES + 1),
        ];

        let head = PhaseOneAdmissionPolicy::select_phase_two_head(&candidates).into_indices();
        let head_ids: Vec<i64> = head.iter().map(|&index| candidates[index].id).collect();
        assert_eq!(head_ids.len(), 5);
        assert_eq!(head_ids, vec![1, 2, 100, 101, 102]);
    }

    // ── Short-word query recall bug ───────────────────────────────
    //
    // Query: "A a B b" (4 single-char words)
    // Item:  "A a B b C c D d E e F f G g H h I i J j K k L l M m N n O o P p Q q R r S s T t U u V v W w X x Y y Z z"
    //
    // Bug: 4 words triggers is_long_query, which generates per-word
    // trigrams. But every word is 1 char — too short for any trigram.
    // Result: zero trigrams → empty recall → item not found.
    //
    // Full-string trigrams would produce cross-word-boundary trigrams
    // like "a a", " a ", "a b" that match the document, but they're
    // skipped because is_long_query uses per-word-only mode.
    // Fuzzy clauses are also disabled for 4+ word queries.

    #[test]
    fn test_short_words_long_query_recall() {
        let indexer = Indexer::new_in_memory().unwrap();
        indexer
            .add_document(
                1,
                "A a B b C c D d E e F f G g H h I i J j K k L l M m N n O o P p Q q R r S s T t U u V v W w X x Y y Z z",
                1000,
            )
            .unwrap();
        indexer
            .add_document(2, "unrelated content here", 1000)
            .unwrap();
        indexer.commit().unwrap();

        let results = indexer.search("A a B b", 10).unwrap();
        let ids: Vec<i64> = results.iter().map(|c| c.id).collect();
        assert!(
            ids.contains(&1),
            "query 'A a B b' with all single-char words should recall the matching item, got {:?}",
            ids
        );
        assert!(!ids.contains(&2));
    }

    #[test]
    fn test_two_char_words_long_query_recall() {
        let indexer = Indexer::new_in_memory().unwrap();
        indexer.add_document(1, "ab cd ef gh ij kl", 1000).unwrap();
        indexer
            .add_document(2, "ab xx cd yy ef zz gh", 1000)
            .unwrap();
        indexer.commit().unwrap();

        let results = indexer.search("ab cd ef gh", 10).unwrap();
        let ids: Vec<i64> = results.iter().map(|candidate| candidate.id).collect();
        assert!(
            ids.contains(&1),
            "query 'ab cd ef gh' should recall the exact short-word sequence, got {:?}",
            ids
        );
        assert!(
            !ids.contains(&2),
            "query 'ab cd ef gh' should not recall scattered short words, got {:?}",
            ids
        );
    }

    #[test]
    fn test_word_sequence_recall_accepts_dense_clusters_with_gap() {
        let indexer = Indexer::new_in_memory().unwrap();
        indexer
            .add_document(
                1,
                "to be thinking carefully about the tradeoffs before deciding or not today",
                1000,
            )
            .unwrap();
        indexer
            .add_document(2, "to something be something else", 1000)
            .unwrap();
        indexer.commit().unwrap();

        let results = indexer.search("to be or not", 10).unwrap();
        let ids: Vec<i64> = results.iter().map(|candidate| candidate.id).collect();
        assert!(
            ids.contains(&1),
            "query 'to be or not' should recall dense short-word clusters with a gap, got {:?}",
            ids
        );
    }

    #[test]
    fn test_word_sequence_recall_rejects_scattered_short_words() {
        let indexer = Indexer::new_in_memory().unwrap();
        indexer
            .add_document(
                1,
                "to something be something unrelated or something not",
                1000,
            )
            .unwrap();
        indexer.commit().unwrap();

        let results = indexer.search("to be or not", 10).unwrap();
        let ids: Vec<i64> = results.iter().map(|candidate| candidate.id).collect();
        assert!(
            ids.is_empty(),
            "query 'to be or not' should not recall scattered short words without adjacent pairs, got {:?}",
            ids
        );
    }
}
