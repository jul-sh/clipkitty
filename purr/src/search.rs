//! Search Engine — ranking, indexing, and search
//!
//! Consolidates the search pipeline:
//! - **Ranking**: Milli-style bucket ranking with lexicographic tuple scoring
//! - **Indexer**: Tantivy trigram indexing with phrase-boost scoring
//! - **Search**: Trigram retrieval, short-query fallback, highlighting, and snippets

use std::path::Path;

use chrono::Utc;
use parking_lot::RwLock;
use tantivy::collector::TopDocs;
use tantivy::directory::MmapDirectory;
use tantivy::query::{BooleanQuery, BoostQuery, Occur, PhraseQuery, TermQuery};
use tantivy::schema::*;
use tantivy::tokenizer::{NgramTokenizer, TextAnalyzer, TokenFilter, TokenStream, Tokenizer};
use tantivy::{DocId, Index, IndexReader, IndexWriter, ReloadPolicy, Score, Term};
use thiserror::Error;
use tokio_util::sync::CancellationToken;

use crate::database::StoredItem;
use crate::interface::{
    HighlightKind, HighlightRange, ItemMatch, MatchData,
};

// ─────────────────────────────────────────────────────────────────────────────
// RANKING — Milli-style bucket ranking
// ─────────────────────────────────────────────────────────────────────────────

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
struct BucketScore {
    words_matched: u8,
    typo_score: u8,
    recency_tier: u8,
    proximity_score: u16,
    exactness_score: u8,
    bm25_quantized: u16,
    recency: i64,
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
fn compute_bucket_score(
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
enum WordMatchKind {
    None,
    Exact,
    Prefix,
    Fuzzy(u8),
    Subsequence(u8),
}

/// Check if a query word matches a document word using the same criteria
/// as ranking: exact -> prefix (if allowed, >= 2 chars) -> fuzzy (edit distance)
/// -> subsequence (abbreviation). Both inputs must already be lowercased.
fn does_word_match(qw_lower: &str, dw_lower: &str, allow_prefix: bool) -> WordMatchKind {
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
fn edit_distance_bounded(a: &str, b: &str, max_dist: u8) -> Option<u8> {
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

// ─────────────────────────────────────────────────────────────────────────────
// INDEXER — Tantivy trigram indexing
// ─────────────────────────────────────────────────────────────────────────────

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
pub(crate) enum IndexerError {
    #[error("Tantivy error: {0}")]
    Tantivy(#[from] tantivy::TantivyError),
    #[error("Directory error: {0}")]
    Directory(#[from] tantivy::directory::error::OpenDirectoryError),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}

pub(crate) type IndexerResult<T> = Result<T, IndexerError>;

/// A search candidate from Tantivy (before bucket re-ranking)
#[derive(Debug, Clone)]
struct SearchCandidate {
    id: i64,
    content: String,
    timestamp: i64,
    /// Blended score (BM25 + recency) from Tantivy's tweak_score
    tantivy_score: f32,
}

/// Tantivy-based indexer with trigram tokenization
pub(crate) struct Indexer {
    index: Index,
    writer: RwLock<IndexWriter>,
    reader: RwLock<IndexReader>,
    schema: Schema,
    id_field: Field,
    content_field: Field,
}

impl Indexer {
    /// Create a new indexer at the given path
    pub(crate) fn new(path: &Path) -> IndexerResult<Self> {
        std::fs::create_dir_all(path)?;
        let dir = MmapDirectory::open(path)?;
        let schema = Self::build_schema();
        let index = Index::open_or_create(dir, schema.clone())?;
        Self::register_tokenizer(&index);

        let writer = index.writer(50_000_000)?;
        let reader = index.reader_builder().reload_policy(ReloadPolicy::Manual).try_into()?;

        Ok(Self::from_parts(index, writer, reader, schema))
    }

    /// Create an in-memory indexer (for testing)
    #[cfg(test)]
    pub(crate) fn new_in_memory() -> IndexerResult<Self> {
        let schema = Self::build_schema();
        let index = Index::create_in_ram(schema.clone());
        Self::register_tokenizer(&index);

        let writer = index.writer(15_000_000)?;
        let reader = index.reader_builder().reload_policy(ReloadPolicy::Manual).try_into()?;

        Ok(Self::from_parts(index, writer, reader, schema))
    }

    fn from_parts(index: Index, writer: IndexWriter, reader: IndexReader, schema: Schema) -> Self {
        Self {
            id_field: schema.get_field("id").unwrap(),
            content_field: schema.get_field("content").unwrap(),
            schema,
            index,
            writer: RwLock::new(writer),
            reader: RwLock::new(reader),
        }
    }

    fn build_schema() -> Schema {
        let mut builder = Schema::builder();
        builder.add_i64_field("id", STORED | FAST | INDEXED);

        // Content field with trigram tokenization
        let text_field_indexing = TextFieldIndexing::default()
            .set_tokenizer("trigram")
            .set_index_option(IndexRecordOption::WithFreqsAndPositions);
        let text_options = TextOptions::default()
            .set_indexing_options(text_field_indexing)
            .set_stored();
        builder.add_text_field("content", text_options);

        builder.add_i64_field("timestamp", STORED | FAST);
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

    /// Add or update a document in the index
    pub(crate) fn add_document(&self, id: i64, content: &str, timestamp: i64) -> IndexerResult<()> {
        let writer = self.writer.read();

        // Delete existing document with same ID (upsert semantics)
        let id_term = tantivy::Term::from_field_i64(self.id_field, id);
        writer.delete_term(id_term);

        // Add new document
        let mut doc = tantivy::TantivyDocument::default();
        doc.add_i64(self.id_field, id);
        doc.add_text(self.content_field, content);
        doc.add_i64(self.schema.get_field("timestamp").unwrap(), timestamp);

        writer.add_document(doc)?;

        Ok(())
    }

    pub(crate) fn commit(&self) -> IndexerResult<()> {
        self.writer.write().commit()?;
        self.reader.write().reload()?;
        Ok(())
    }

    pub(crate) fn delete_document(&self, id: i64) -> IndexerResult<()> {
        let writer = self.writer.read();
        let id_term = tantivy::Term::from_field_i64(self.id_field, id);
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
    fn transposition_trigrams(&self, words: &[&str], seen: &mut std::collections::HashSet<Term>) -> Vec<Term> {
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

    /// Two-phase search: trigram recall (Phase 1) + bucket re-ranking (Phase 2).
    fn search(&self, query: &str, limit: usize) -> IndexerResult<Vec<SearchCandidate>> {
        #[cfg(feature = "perf-log")]
        let t0 = std::time::Instant::now();
        let candidates = self.trigram_recall(query, limit)?;
        #[cfg(feature = "perf-log")]
        let t1 = std::time::Instant::now();

        if candidates.is_empty() || query.split_whitespace().count() == 0 {
            #[cfg(feature = "perf-log")]
            eprintln!("[perf] phase1={:.1}ms candidates=0", (t1 - t0).as_secs_f64() * 1000.0);
            return Ok(candidates);
        }

        // Phase 2: Bucket re-ranking
        let query_words_owned = tokenize_words(query);
        let query_words: Vec<&str> = query_words_owned.iter().map(|(_, _, w)| w.as_str()).collect();
        let last_word_is_prefix = query.ends_with(|c: char| c.is_alphanumeric());
        let now = Utc::now().timestamp();

        let mut scored: Vec<(BucketScore, usize)> = candidates
            .iter()
            .enumerate()
            .map(|(i, c)| {
                let bucket = compute_bucket_score(
                    &c.content,
                    &query_words,
                    last_word_is_prefix,
                    c.timestamp,
                    c.tantivy_score,
                    now,
                );
                (bucket, i)
            })
            .collect();

        scored.sort_unstable_by(|a, b| b.0.cmp(&a.0));
        scored.truncate(limit);

        #[cfg(feature = "perf-log")]
        {
            let t2 = std::time::Instant::now();
            eprintln!(
                "[perf] phase1={:.1}ms phase2={:.1}ms candidates={}",
                (t1 - t0).as_secs_f64() * 1000.0,
                (t2 - t1).as_secs_f64() * 1000.0,
                scored.len(),
            );
        }

        let mut candidate_slots: Vec<Option<SearchCandidate>> =
            candidates.into_iter().map(Some).collect();

        Ok(scored
            .into_iter()
            .filter_map(|(_score, i)| candidate_slots[i].take())
            .collect())
    }

    /// Phase 1: Trigram recall using Tantivy BM25.
    ///
    /// Builds an OR query from trigram terms with a min_match threshold.
    /// For long queries (4+ words), only per-word trigrams are used (skipping
    /// cross-word boundary trigrams) to reduce posting list evaluations.
    fn trigram_recall(&self, query: &str, limit: usize) -> IndexerResult<Vec<SearchCandidate>> {
        let reader = self.reader.read();
        let searcher = reader.searcher();

        // Query too short for trigrams — return empty vec (caller handles fallback)
        let has_trigrams = query.split_whitespace().any(|w| w.len() >= 3)
            || query.trim().len() >= 3;
        if !has_trigrams {
            return Ok(Vec::new());
        }

        let final_query = self.build_trigram_query(query);

        // Use tweak_score to blend BM25 with recency at collection time.
        let timestamp_field = self.schema.get_field("timestamp").unwrap();
        let now = Utc::now().timestamp();

        let top_collector = TopDocs::with_limit(limit)
            .tweak_score(move |segment_reader: &tantivy::SegmentReader| {
                let ts_reader = segment_reader
                    .fast_fields()
                    .i64("timestamp")
                    .expect("timestamp fast field");
                move |doc: DocId, score: Score| {
                    let timestamp = ts_reader.first(doc).unwrap_or(0);
                    let base = (score as f64).max(0.001);
                    let age_secs = (now - timestamp).max(0) as f64;
                    let recency = (-age_secs * 2.0_f64.ln() / RECENCY_HALF_LIFE_SECS).exp();
                    base * (1.0 + RECENCY_BOOST_MAX * recency)
                }
            });

        let top_docs = searcher.search(final_query.as_ref(), &top_collector)?;

        let mut candidates = Vec::with_capacity(top_docs.len());
        for (blended_score, doc_address) in top_docs {
            let doc: tantivy::TantivyDocument = searcher.doc(doc_address)?;
            let id = doc
                .get_first(self.id_field)
                .and_then(|v| v.as_i64())
                .unwrap_or(0);

            let content = doc
                .get_first(self.content_field)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            let timestamp = doc
                .get_first(timestamp_field)
                .and_then(|v| v.as_i64())
                .unwrap_or(0);

            candidates.push(SearchCandidate {
                id,
                content,
                timestamp,
                tantivy_score: blended_score as f32,
            });
        }

        Ok(candidates)
    }

    /// Build a trigram query with phrase boosts for contiguity scoring.
    ///
    /// Base query: OR of trigram terms with min_match threshold.
    /// Phrase boosts: PhraseQuery per word (2x), per word-pair (3x), full query (5x).
    /// These boost documents where query words appear as contiguous substrings,
    /// improving candidate quality in the top-2000 results fed to Phase 2.
    ///
    /// For long queries (4+ words), only per-word trigrams are used in the base
    /// query (skipping cross-word boundary trigrams like "lo " from "hello world")
    /// to reduce posting list evaluations.
    fn build_trigram_query(&self, query: &str) -> Box<dyn tantivy::query::Query> {
        let words: Vec<&str> = query.split_whitespace().collect();
        let is_long_query = words.len() >= 4;

        let (terms, mut seen) = if is_long_query {
            // Long query: per-word trigrams only (skip cross-word boundary trigrams)
            let mut all_terms = Vec::new();
            let mut seen = std::collections::HashSet::new();
            for word in &words {
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
            return Box::new(BooleanQuery::new(Vec::new()));
        }

        // Compute min_match from original term count BEFORE adding variants.
        // Transposition variants can only help recall, never raise the threshold.
        let num_terms = terms.len();

        // Add trigrams from transposition variants of short words (3-4 chars)
        let variant_terms = self.transposition_trigrams(&words, &mut seen);

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
                (num_terms + 1) / 2
            };
            recall_query.set_minimum_number_should_match(min_match);
        }

        // Phrase boosts: score documents higher when query words appear as
        // contiguous substrings. This improves candidate quality in the top-2000.
        let mut phrase_boosts: Vec<(Occur, Box<dyn tantivy::query::Query>)> = Vec::new();

        // Per-word phrase boost (2x): each word's trigrams must be contiguous
        for word in &words {
            if word.len() < 3 {
                continue;
            }
            let word_terms = self.trigram_terms(word);
            if word_terms.len() >= 2 {
                let phrase = PhraseQuery::new(word_terms);
                let boosted: Box<dyn tantivy::query::Query> =
                    Box::new(BoostQuery::new(Box::new(phrase), 2.0));
                phrase_boosts.push((Occur::Should, boosted));
            }
        }

        // Word-pair proximity boost (3x) — skip for long queries to limit cost
        if words.len() >= 2 && !is_long_query {
            for pair in words.windows(2) {
                if pair[0].len() < 2 || pair[1].len() < 2 {
                    continue;
                }
                let pair_str = format!("{} {}", pair[0], pair[1]);
                let pair_terms = self.trigram_terms(&pair_str);
                if pair_terms.len() >= 2 {
                    let phrase = PhraseQuery::new(pair_terms);
                    let boosted: Box<dyn tantivy::query::Query> =
                        Box::new(BoostQuery::new(Box::new(phrase), 3.0));
                    phrase_boosts.push((Occur::Should, boosted));
                }
            }
        }

        // Full-query exactness boost (5x) — skip for long queries
        if words.len() >= 2 && !is_long_query {
            let full_terms = self.trigram_terms(query);
            if full_terms.len() >= 2 {
                let phrase = PhraseQuery::new(full_terms);
                let boosted: Box<dyn tantivy::query::Query> =
                    Box::new(BoostQuery::new(Box::new(phrase), 5.0));
                phrase_boosts.push((Occur::Should, boosted));
            }
        }

        if phrase_boosts.is_empty() {
            Box::new(recall_query)
        } else {
            let mut outer: Vec<(Occur, Box<dyn tantivy::query::Query>)> = Vec::new();
            outer.push((Occur::Must, Box::new(recall_query)));
            outer.extend(phrase_boosts);
            Box::new(BooleanQuery::new(outer))
        }
    }

    pub(crate) fn clear(&self) -> IndexerResult<()> {
        let mut writer = self.writer.write();
        writer.delete_all_documents()?;
        writer.commit()?;
        drop(writer);
        self.reader.write().reload()?;
        Ok(())
    }

    /// Get the number of documents in the index
    pub(crate) fn num_docs(&self) -> u64 {
        self.reader.read().searcher().num_docs()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SEARCH — Trigram retrieval, highlighting, snippets, tokenization
// ─────────────────────────────────────────────────────────────────────────────

/// Maximum results to return from search.
pub(crate) const MAX_RESULTS: usize = 2000;

pub(crate) const MIN_TRIGRAM_QUERY_LEN: usize = 3;

/// Maximum recency boost multiplier for Phase 1 trigram recall.
/// 0.5 = up to 50% boost for brand new items, ensuring recent items make the candidate set.
const RECENCY_BOOST_MAX: f64 = 0.5;
/// Half-life for recency decay: 3 days (stronger recency bias than 7-day default)
const RECENCY_HALF_LIFE_SECS: f64 = 3.0 * 24.0 * 60.0 * 60.0;

/// Boost factor for prefix matches in short query scoring
const PREFIX_MATCH_BOOST: f64 = 2.0;

/// Boost for entries where highlighted chars cover most of the document.
const COVERAGE_BOOST_MAX: f64 = 3.0;
const COVERAGE_BOOST_THRESHOLD: f64 = 0.4;

/// Boost for matches starting in the first N characters of content.
const POSITION_BOOST_MAX: f64 = 1.5;
const POSITION_BOOST_MIN: f64 = 1.1;
const POSITION_BOOST_WINDOW: usize = 50;

/// Context chars to include before/after match in snippet
pub(crate) const SNIPPET_CONTEXT_CHARS: usize = 200;

#[derive(Debug, Clone)]
pub(crate) struct FuzzyMatch {
    pub(crate) id: i64,
    pub(crate) score: f64,
    pub(crate) highlight_ranges: Vec<HighlightRange>,
    pub(crate) timestamp: i64,
    pub(crate) content: String,
    /// Whether this was a prefix match (for short query scoring)
    pub(crate) is_prefix_match: bool,
}

/// Search using Tantivy with bucket re-ranking for trigram queries (>= 3 chars).
/// Phase 1 (trigram recall) and Phase 2 (bucket re-ranking) happen inside indexer.search().
/// This function handles highlighting via rayon parallelism with cancellation support.
pub(crate) fn search_trigram(indexer: &Indexer, query: &str, token: &CancellationToken) -> IndexerResult<Vec<FuzzyMatch>> {
        if query.trim().is_empty() {
            return Ok(Vec::new());
        }
        let trimmed = query.trim_start();
        let query_words_owned = tokenize_words(trimmed.trim_end());
        let query_words: Vec<&str> = query_words_owned.iter().map(|(_, _, w)| w.as_str()).collect();
        let last_word_is_prefix = trimmed.trim_end().ends_with(|c: char| c.is_alphanumeric());

        // Bucket-ranked candidates from two-phase search
        #[cfg(feature = "perf-log")]
        let t0 = std::time::Instant::now();
        let candidates = indexer.search(trimmed.trim_end(), MAX_RESULTS)?;
        #[cfg(feature = "perf-log")]
        let num_candidates = candidates.len();

        // Assign rank before parallelizing so we can restore bucket order after
        let ranked: Vec<(usize, SearchCandidate)> = candidates.into_iter().enumerate().collect();

        #[cfg(feature = "perf-log")]
        let t1 = std::time::Instant::now();
        use rayon::prelude::*;
        let mut sorted: Vec<FuzzyMatch> = ranked
            .into_par_iter()
            .take_any_while(|_| !token.is_cancelled())
            .map(|(rank, c)| {
                let mut m = highlight_candidate(c.id, &c.content, c.timestamp, c.tantivy_score, &query_words, last_word_is_prefix);
                // Preserve bucket ranking order: score = inverse rank so sort is stable
                m.score = (MAX_RESULTS - rank) as f64;
                m
            })
            .filter(|m| !m.highlight_ranges.is_empty())
            .collect();

        // par_iter + take_any_while doesn't preserve order — restore bucket ranking
        sorted.sort_unstable_by(|a, b| b.score.total_cmp(&a.score));

        #[cfg(feature = "perf-log")]
        {
            let t2 = std::time::Instant::now();
            eprintln!(
                "[perf] indexer_total={:.1}ms highlight={:.1}ms candidates={} highlighted={}",
                (t1 - t0).as_secs_f64() * 1000.0,
                (t2 - t1).as_secs_f64() * 1000.0,
                num_candidates,
                sorted.len(),
            );
        }

    Ok(sorted)
}

/// Score candidates for short queries (< 3 chars)
/// Uses recency as primary metric with prefix match boost
pub(crate) fn score_short_query_batch(
    candidates: impl Iterator<Item = (i64, String, i64, bool)> + Send, // (id, content, timestamp, is_prefix)
    query: &str,
    token: &CancellationToken,
) -> Vec<FuzzyMatch> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Vec::new();
        }

        let query_lower = trimmed.to_lowercase();
        let now = Utc::now().timestamp();

        use rayon::prelude::*;
        let query_len = query_lower.len();
        let mut results: Vec<FuzzyMatch> = candidates
            .par_bridge()
            .take_any_while(|_| !token.is_cancelled())
            .filter_map(|(id, content, timestamp, is_prefix_match)| {
                let content_lower = content.to_lowercase();

                // Find ALL match positions for highlighting (not just the first)
                let positions: Vec<usize> = content_lower
                    .match_indices(&query_lower)
                    .map(|(pos, _)| pos)
                    .collect();
                if positions.is_empty() {
                    return None;
                }

                let highlight_ranges: Vec<HighlightRange> = positions.iter()
                    .map(|&pos| HighlightRange {
                        start: pos as u64,
                        end: (pos + query_len) as u64,
                        kind: HighlightKind::Exact,
                    })
                    .collect();

                // Score based on recency with prefix boost
                let base_score = 1000.0_f64;
                let mut score = if is_prefix_match {
                    base_score * PREFIX_MATCH_BOOST
                } else {
                    base_score
                };

                // Word-boundary boost: prefer "hi there" over "within" for query "hi"
                let chars: Vec<char> = content_lower.chars().collect();
                let has_word_boundary_match = positions.iter().any(|&pos| {
                    let at_start = pos == 0 || !chars.get(pos - 1).map_or(false, |c| c.is_alphanumeric());
                    let at_end = pos + query_len >= chars.len()
                        || !chars.get(pos + query_len).map_or(false, |c| c.is_alphanumeric());
                    at_start && at_end
                });
                if has_word_boundary_match {
                    score *= PREFIX_MATCH_BOOST;
                }

                // Coverage boost
                let content_char_len = chars.len().max(1);
                let matched_char_count: u64 = highlight_ranges.iter().map(|r| r.end - r.start).sum();
                let coverage = matched_char_count as f64 / content_char_len as f64;
                if coverage > COVERAGE_BOOST_THRESHOLD {
                    let t = (coverage - COVERAGE_BOOST_THRESHOLD) / (1.0 - COVERAGE_BOOST_THRESHOLD);
                    score *= 1.0 + (COVERAGE_BOOST_MAX - 1.0) * t;
                }

                // Position boost for matches near the start
                if positions[0] < POSITION_BOOST_WINDOW {
                    let t = 1.0 - (positions[0] as f64 / POSITION_BOOST_WINDOW as f64);
                    let boost = POSITION_BOOST_MIN + (POSITION_BOOST_MAX - POSITION_BOOST_MIN) * t;
                    score *= boost;
                }

                Some(FuzzyMatch {
                    id,
                    score,
                    highlight_ranges,
                    timestamp,
                    content,
                    is_prefix_match,
                })
            })
            .collect();

        // Sort by blended score (recency primary, prefix boost)
        results.sort_unstable_by(|a, b| {
            let score_a = recency_weighted_score(a.score, a.timestamp, now, a.is_prefix_match);
            let score_b = recency_weighted_score(b.score, b.timestamp, now, b.is_prefix_match);
            score_b.total_cmp(&score_a).then_with(|| b.timestamp.cmp(&a.timestamp))
        });

    results.truncate(MAX_RESULTS);
    results
}

/// Map a `WordMatchKind` from ranking to a `HighlightKind` for the UI.
fn word_match_to_highlight_kind(wmk: WordMatchKind) -> HighlightKind {
    match wmk {
        WordMatchKind::Exact => HighlightKind::Exact,
        WordMatchKind::Prefix => HighlightKind::Prefix,
        WordMatchKind::Fuzzy(_) => HighlightKind::Fuzzy,
        WordMatchKind::Subsequence(_) => HighlightKind::Subsequence,
        WordMatchKind::None => HighlightKind::Exact, // unreachable in practice
    }
}

/// Highlight a candidate using the same word-matching criteria as ranking
/// (exact, prefix, fuzzy edit-distance) via `does_word_match`. This ensures
/// what's highlighted matches what's ranked in Phase 2 bucket scoring.
fn highlight_candidate(
        id: i64,
        content: &str,
        timestamp: i64,
        tantivy_score: f32,
        query_words: &[&str],
        last_word_is_prefix: bool,
    ) -> FuzzyMatch {
        let content_lower = content.to_lowercase();
        let mut word_highlights: Vec<(usize, usize, HighlightKind)> = Vec::new();
        let mut matched_query_words = vec![false; query_words.len()];

        let query_lower: Vec<String> = query_words.iter().map(|w| w.to_lowercase()).collect();
        let last_qi = query_lower.len().saturating_sub(1);

        let doc_words = tokenize_words(&content_lower);

        for (char_start, char_end, doc_word) in &doc_words {
            for (qi, qw) in query_lower.iter().enumerate() {
                let allow_prefix = qi == last_qi && last_word_is_prefix;
                let wmk = does_word_match(qw, doc_word, allow_prefix);
                if wmk != WordMatchKind::None {
                    matched_query_words[qi] = true;
                    word_highlights.push((*char_start, *char_end, word_match_to_highlight_kind(wmk)));
                    break; // Don't double-highlight from multiple query words
                }
            }
        }

        // Sort by start position
        word_highlights.sort_unstable_by_key(|&(s, _, _)| s);

        // Bridge gaps between adjacent highlighted ranges where intervening chars are all
        // non-whitespace punctuation or ranges are directly adjacent (e.g. "://" in URLs,
        // "." in domains, "/" in paths). Inherit the first range's kind.
        let content_chars: Vec<char> = content.chars().collect();
        let mut bridged: Vec<(usize, usize, HighlightKind)> = Vec::with_capacity(word_highlights.len());
        for wh in &word_highlights {
            if let Some(last) = bridged.last_mut() {
                let gap_start = last.1;
                let gap_end = wh.0;
                if gap_start <= gap_end
                    && gap_end <= content_chars.len()
                    && (gap_start == gap_end
                        || content_chars[gap_start..gap_end]
                            .iter()
                            .all(|c: &char| !c.is_alphanumeric() && !c.is_whitespace()))
                {
                    // Merge into previous range, inheriting its kind
                    last.1 = wh.1;
                    continue;
                }
            }
            bridged.push(*wh);
        }

        // Convert to HighlightRange
        let highlight_ranges: Vec<HighlightRange> = bridged
            .iter()
            .map(|&(s, e, k)| HighlightRange { start: s as u64, end: e as u64, kind: k })
            .collect();

        // Start with tantivy score for display scoring (coverage/position boosts)
        let mut score = tantivy_score as f64;

        if !highlight_ranges.is_empty() {
            let content_char_len = content.chars().count().max(1);
            let matched_char_count: usize = highlight_ranges.iter().map(|r| (r.end - r.start) as usize).sum();

            // Coverage boost based on unique query words matched
            let unique_matched = matched_query_words.iter().filter(|&&m| m).count();
            let query_coverage = unique_matched as f64 / query_words.len().max(1) as f64;
            let content_coverage = matched_char_count as f64 / content_char_len as f64;
            let coverage = query_coverage.min(content_coverage);
            if coverage > COVERAGE_BOOST_THRESHOLD {
                let t = (coverage - COVERAGE_BOOST_THRESHOLD) / (1.0 - COVERAGE_BOOST_THRESHOLD);
                score *= 1.0 + (COVERAGE_BOOST_MAX - 1.0) * t;
            }

            // Position boost
            let first_match_pos = highlight_ranges[0].start as usize;
            if first_match_pos < POSITION_BOOST_WINDOW {
                let t = 1.0 - (first_match_pos as f64 / POSITION_BOOST_WINDOW as f64);
                let boost = POSITION_BOOST_MIN + (POSITION_BOOST_MAX - POSITION_BOOST_MIN) * t;
                score *= boost;
            }
        }

    FuzzyMatch {
        id,
        score,
        highlight_ranges,
        timestamp,
        content: content.to_string(),
        is_prefix_match: false,
    }
}

/// Convert matched indices to highlight ranges with a specified kind
#[cfg(test)]
fn indices_to_ranges_with_kind(indices: &[u32], kind: HighlightKind) -> Vec<HighlightRange> {
    if indices.is_empty() { return Vec::new(); }

    let mut sorted = indices.to_vec();
    sorted.sort_unstable();
    sorted.dedup();

    sorted[1..].iter().fold(vec![(sorted[0], sorted[0] + 1)], |mut acc, &idx| {
        let last = acc.last_mut().unwrap();
        if idx == last.1 { last.1 = idx + 1; } else { acc.push((idx, idx + 1)); }
        acc
    }).into_iter().map(|(start, end)| HighlightRange { start: start as u64, end: end as u64, kind }).collect()
}

/// Convert matched indices to highlight ranges (defaults to Exact kind)
#[cfg(test)]
fn indices_to_ranges(indices: &[u32]) -> Vec<HighlightRange> {
    indices_to_ranges_with_kind(indices, HighlightKind::Exact)
}

/// Find the highlight in the densest cluster of highlights using a sliding window.
fn find_densest_highlight(highlights: &[HighlightRange], window_size: u64) -> Option<usize> {
    if highlights.is_empty() {
        return None;
    }
    if highlights.len() == 1 {
        return Some(0);
    }

    let mut indexed: Vec<(usize, &HighlightRange)> = highlights.iter().enumerate().collect();
    indexed.sort_by_key(|(_, h)| h.start);

    let mut left = 0;
    let mut best_left = 0;
    let mut best_coverage = 0u64;
    let mut current_coverage = 0u64;

    for right in 0..indexed.len() {
        while indexed[left].1.start + window_size <= indexed[right].1.start {
            current_coverage -= indexed[left].1.end - indexed[left].1.start;
            left += 1;
        }
        current_coverage += indexed[right].1.end - indexed[right].1.start;

        if current_coverage > best_coverage {
            best_coverage = current_coverage;
            best_left = left;
        }
    }

    Some(indexed[best_left].0)
}

/// Generate a generous text snippet around the densest cluster of highlights.
pub(crate) fn generate_snippet(content: &str, highlights: &[HighlightRange], max_len: usize) -> (String, Vec<HighlightRange>, u64) {
    let content_char_len = content.chars().count();

    if highlights.is_empty() {
        let preview = normalize_snippet(content, 0, content_char_len, max_len);
        return (preview, Vec::new(), 0);
    }

    let density_window = SNIPPET_CONTEXT_CHARS as u64;
    let center_idx = find_densest_highlight(highlights, density_window).unwrap_or(0);
    let center_highlight = &highlights[center_idx];
    let match_start_char = center_highlight.start as usize;
    let match_end_char = center_highlight.end as usize;

    let line_number = content
        .chars()
        .take(match_start_char.min(content_char_len))
        .filter(|&c| c == '\n')
        .count() as u64
        + 1;

    let match_char_len = match_end_char.saturating_sub(match_start_char);
    let remaining_space = max_len.saturating_sub(match_char_len);

    let context_before = (remaining_space / 2).min(SNIPPET_CONTEXT_CHARS).min(match_start_char);
    let context_after = (remaining_space - context_before).min(content_char_len.saturating_sub(match_end_char));

    let mut snippet_start_char = match_start_char - context_before;
    let snippet_end_char = (match_end_char + context_after).min(content_char_len);

    if snippet_start_char > 0 {
        let search_start_char = snippet_start_char.saturating_sub(10);
        let search_range: String = content
            .chars()
            .skip(search_start_char)
            .take(snippet_start_char - search_start_char)
            .collect();
        if let Some(space_pos) = search_range.rfind(char::is_whitespace) {
            if search_range.is_char_boundary(space_pos) {
                let char_offset = search_range[..space_pos].chars().count();
                let new_start = search_start_char + char_offset + 1;
                if new_start <= match_start_char.saturating_sub(context_before) {
                    snippet_start_char = new_start;
                }
            }
        }
    }

    let ellipsis_reserve = (if snippet_start_char > 0 { 1 } else { 0 })
        + (if snippet_end_char < content_char_len { 1 } else { 0 });
    let effective_max_len = max_len.saturating_sub(ellipsis_reserve);
    let (normalized_snippet, pos_map) = normalize_snippet_with_mapping(content, snippet_start_char, snippet_end_char, effective_max_len);

    let truncated_from_start = snippet_start_char > 0;
    let truncated_from_end = snippet_end_char < content_char_len;

    let prefix_offset = if truncated_from_start { 1 } else { 0 };
    let mut final_snippet = if truncated_from_start {
        format!("\u{2026}{}", normalized_snippet)
    } else {
        normalized_snippet.clone()
    };
    if truncated_from_end {
        final_snippet.push('\u{2026}');
    }

    let adjusted_highlights: Vec<HighlightRange> = highlights
        .iter()
        .filter_map(|h| {
            let orig_start = (h.start as usize).checked_sub(snippet_start_char)?;
            let orig_end = (h.end as usize).saturating_sub(snippet_start_char);

            let norm_start = map_position(orig_start, &pos_map)?;
            let norm_end = map_position(orig_end, &pos_map).unwrap_or(normalized_snippet.len());

            if norm_start < normalized_snippet.len() {
                Some(HighlightRange {
                    start: (norm_start + prefix_offset) as u64,
                    end: (norm_end.min(normalized_snippet.len()) + prefix_offset) as u64,
                    kind: h.kind,
                })
            } else {
                None
            }
        })
        .collect();

    (final_snippet, adjusted_highlights, line_number)
}

impl From<&FuzzyMatch> for MatchData {
    fn from(fuzzy_match: &FuzzyMatch) -> Self {
        let full_content_highlights = fuzzy_match.highlight_ranges.clone();
        let max_len = SNIPPET_CONTEXT_CHARS * 2;
        let (text, adjusted_highlights, line_number) = generate_snippet(
            &fuzzy_match.content,
            &full_content_highlights,
            max_len,
        );

        let densest_highlight_start = find_densest_highlight(&full_content_highlights, SNIPPET_CONTEXT_CHARS as u64)
            .map(|idx| full_content_highlights[idx].start)
            .unwrap_or(0);

        MatchData {
            text,
            highlights: adjusted_highlights,
            line_number,
            full_content_highlights,
            densest_highlight_start,
        }
    }
}

/// Create ItemMatch from StoredItem and FuzzyMatch
pub(crate) fn create_item_match(item: &StoredItem, fuzzy_match: &FuzzyMatch) -> ItemMatch {
    ItemMatch {
        item_metadata: item.into(),
        match_data: fuzzy_match.into(),
    }
}

/// Tokenize text into tokens with char offsets.
/// Produces both alphanumeric word tokens and non-whitespace punctuation tokens.
/// Whitespace is skipped (acts as a separator).
/// Punctuation tokens allow matching symbols like "://", ".", "/" in URLs/paths.
fn tokenize_words(content: &str) -> Vec<(usize, usize, String)> {
    let chars: Vec<char> = content.chars().collect();
    let mut tokens = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i].is_whitespace() {
            i += 1;
            continue;
        }
        let start = i;
        if chars[i].is_alphanumeric() {
            while i < chars.len() && chars[i].is_alphanumeric() {
                i += 1;
            }
        } else {
            while i < chars.len() && !chars[i].is_alphanumeric() && !chars[i].is_whitespace() {
                i += 1;
            }
        }
        let token: String = chars[start..i].iter().collect();
        tokens.push((start, i, token));
    }
    tokens
}

/// Whether a token from `tokenize_words` is an alphanumeric word (vs punctuation).
/// Tokens are homogeneous runs — either all alphanumeric or all punctuation —
/// so checking the first character is sufficient.
fn is_word_token(token: &str) -> bool {
    token.starts_with(|c: char| c.is_alphanumeric())
}

/// Combine a base relevance score with exponential recency decay and prefix boost.
fn recency_weighted_score(fuzzy_score: f64, timestamp: i64, now: i64, is_prefix_match: bool) -> f64 {
    let base_score = fuzzy_score;

    let age_secs = (now - timestamp).max(0) as f64;
    let recency_factor = (-age_secs * 2.0_f64.ln() / RECENCY_HALF_LIFE_SECS).exp();

    let prefix_boost = if is_prefix_match { PREFIX_MATCH_BOOST } else { 1.0 };

    base_score * prefix_boost * (1.0 + RECENCY_BOOST_MAX * recency_factor)
}

fn normalize_snippet_with_mapping(content: &str, start: usize, end: usize, max_chars: usize) -> (String, Vec<usize>) {
    if end <= start {
        return (String::new(), vec![0]);
    }

    let mut result = String::with_capacity(max_chars);
    let mut pos_map = Vec::with_capacity(end - start + 1);
    let mut last_was_space = false;
    let mut norm_idx = 0;

    for ch in content.chars().skip(start).take(end - start) {
        pos_map.push(norm_idx);

        if norm_idx >= max_chars {
            continue;
        }

        let ch = match ch {
            '\n' | '\t' | '\r' => ' ',
            c => c,
        };

        if ch == ' ' {
            if last_was_space {
                continue;
            }
            last_was_space = true;
        } else {
            last_was_space = false;
        }

        result.push(ch);
        norm_idx += 1;
    }

    pos_map.push(norm_idx);

    if result.ends_with(' ') {
        result.pop();
    }

    (result, pos_map)
}

fn map_position(orig_pos: usize, pos_map: &[usize]) -> Option<usize> {
    pos_map.get(orig_pos).copied()
}

fn normalize_snippet(content: &str, start: usize, end: usize, max_chars: usize) -> String {
    normalize_snippet_with_mapping(content, start, end, max_chars).0
}

/// Generate a preview from content (no highlights, starts from beginning)
pub(crate) fn generate_preview(content: &str, max_chars: usize) -> String {
    let trimmed = content.trim_start();
    let (preview, _, _) = generate_snippet(trimmed, &[], max_chars);
    preview
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── Ranking tests ───────────────────────────────────────────────

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
    fn test_subsequence_one_skip() {
        assert_eq!(subsequence_match("helo", "hello"), Some(1));
    }

    #[test]
    fn test_subsequence_contiguous() {
        assert_eq!(subsequence_match("hell", "hello"), Some(0));
    }

    #[test]
    fn test_subsequence_with_gaps() {
        assert_eq!(subsequence_match("impt", "import"), Some(1));
    }

    #[test]
    fn test_subsequence_too_short() {
        assert_eq!(subsequence_match("ab", "abc"), None);
    }

    #[test]
    fn test_subsequence_low_coverage() {
        assert_eq!(subsequence_match("abc", "abcdefg"), None);
    }

    #[test]
    fn test_subsequence_not_found() {
        assert_eq!(subsequence_match("xyz", "hello"), None);
    }

    #[test]
    fn test_subsequence_equal_length() {
        assert_eq!(subsequence_match("abc", "abc"), None);
    }

    #[test]
    fn test_subsequence_first_char_must_match() {
        assert_eq!(subsequence_match("url", "curl"), None);
        assert_eq!(subsequence_match("port", "import"), None);
    }

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

    #[test]
    fn test_does_word_match_exact() {
        assert_eq!(does_word_match("hello", "hello", false), WordMatchKind::Exact);
    }

    #[test]
    fn test_does_word_match_prefix() {
        assert_eq!(does_word_match("cl", "clipkitty", true), WordMatchKind::Prefix);
        assert_eq!(does_word_match("cl", "clipkitty", false), WordMatchKind::None);
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
        assert_eq!(does_word_match("impt", "import", false), WordMatchKind::Subsequence(1));
        assert_eq!(does_word_match("cls", "class", false), WordMatchKind::Subsequence(1));
        assert_eq!(does_word_match("ab", "abc", false), WordMatchKind::None);
        assert_eq!(does_word_match("abc", "abcdefg", false), WordMatchKind::None);
        assert_eq!(does_word_match("imprt", "import", false), WordMatchKind::Fuzzy(1));
    }

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
    fn test_match_subsequence_short_word() {
        // "helo" (4 chars) now matches via fuzzy (edit_distance=1) since max_edit_distance(4)=1
        let doc_words = vec!["hello"];
        let matches = match_query_words(&["helo"], &doc_words, false);
        assert!(matches[0].matched);
        assert_eq!(matches[0].edit_dist, 1);
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

    #[test]
    fn test_recency_tier_last_hour() {
        let now = 1700000000i64;
        assert_eq!(compute_recency_tier(now - 1800, now), 3);
    }

    #[test]
    fn test_recency_tier_last_day() {
        let now = 1700000000i64;
        assert_eq!(compute_recency_tier(now - 7200, now), 2);
    }

    #[test]
    fn test_recency_tier_last_week() {
        let now = 1700000000i64;
        assert_eq!(compute_recency_tier(now - 259200, now), 1);
    }

    #[test]
    fn test_recency_tier_older() {
        let now = 1700000000i64;
        assert_eq!(compute_recency_tier(now - 864000, now), 0);
    }

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
        let recent = compute_bucket_score(
            "hello world and other things between", &["hello", "world"], false, now - 1800, 1.0, now,
        );
        let old = compute_bucket_score(
            "hello world", &["hello", "world"], false, now - 864000, 1.0, now,
        );
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
        assert_eq!(score.exactness_score, 3);
        assert_eq!(score.bm25_quantized, 5);
    }

    // ── Indexer tests ───────────────────────────────────────────────

    #[test]
    fn test_phrase_query_works_with_position_fix() {
        let indexer = Indexer::new_in_memory().unwrap();
        indexer.add_document(1, "hello world", 1000).unwrap();
        indexer.add_document(2, "shell output log", 1000).unwrap();
        indexer.commit().unwrap();

        let reader = indexer.reader.read();
        let searcher = reader.searcher();

        let phrase_terms = indexer.trigram_terms("hello");
        let phrase_q = tantivy::query::PhraseQuery::new(phrase_terms);
        let results = searcher.search(&phrase_q, &TopDocs::with_limit(10)).unwrap();
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

        indexer.add_document(1, "Updated content", 2000).unwrap();
        indexer.commit().unwrap();
        assert_eq!(indexer.num_docs(), 1);
    }

    #[test]
    fn test_clear() {
        let indexer = Indexer::new_in_memory().unwrap();

        for i in 0..10 {
            indexer.add_document(i, &format!("Item {}", i), i * 1000).unwrap();
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
        indexer.add_document(1, "the quick brown fox", 1000).unwrap();
        indexer.add_document(2, "a slow red dog", 1000).unwrap();
        indexer.commit().unwrap();

        let results = indexer.search("teh", 10).unwrap();
        let ids: Vec<i64> = results.iter().map(|c| c.id).collect();
        assert!(ids.contains(&1), "transposition 'teh' should recall doc with 'the', got {:?}", ids);
        assert!(!ids.contains(&2));
    }

    #[test]
    fn test_transposition_recall_multi_word() {
        // "form react" where "form" is a transposition of "from"
        let indexer = Indexer::new_in_memory().unwrap();
        indexer.add_document(1, "import Button from react", 1000).unwrap();
        indexer.add_document(2, "html form element submit", 1000).unwrap();
        indexer.commit().unwrap();

        let results = indexer.search("form react", 10).unwrap();
        let ids: Vec<i64> = results.iter().map(|c| c.id).collect();
        // Doc 1 should be recalled: "from" matches via transposition, "react" matches exact
        assert!(ids.contains(&1), "'form react' should recall doc with 'from react', got {:?}", ids);
    }

    #[test]
    fn test_transposition_trigrams_dedup() {
        // Variant trigrams that duplicate originals shouldn't cause issues
        let indexer = Indexer::new_in_memory().unwrap();
        indexer.add_document(1, "and also other things", 1000).unwrap();
        indexer.commit().unwrap();

        // "adn" transpositions: "dan", "and" — "and" trigram already exists in doc
        let results = indexer.search("adn", 10).unwrap();
        let ids: Vec<i64> = results.iter().map(|c| c.id).collect();
        assert!(ids.contains(&1), "'adn' should recall doc with 'and', got {:?}", ids);
    }

    // ── Search tests ────────────────────────────────────────────────

    #[test]
    fn test_indices_to_ranges() {
        let indices = vec![0, 1, 2, 5, 6, 10];
        let ranges = indices_to_ranges(&indices);
        assert_eq!(ranges.len(), 3);
        assert_eq!(ranges[0], HighlightRange { start: 0, end: 3, kind: HighlightKind::Exact });
        assert_eq!(ranges[1], HighlightRange { start: 5, end: 7, kind: HighlightKind::Exact });
        assert_eq!(ranges[2], HighlightRange { start: 10, end: 11, kind: HighlightKind::Exact });
    }

    /// Helper: create a HighlightRange with Exact kind (for tests that don't care about kind)
    fn hr(start: u64, end: u64) -> HighlightRange {
        HighlightRange { start, end, kind: HighlightKind::Exact }
    }

    #[test]
    fn test_generate_snippet_basic() {
        let content = "This is a long text with some interesting content that we want to highlight";
        let highlights = vec![hr(28, 39)];
        let (snippet, adj_highlights, _line) = super::generate_snippet(content, &highlights, 50);
        assert!(snippet.contains("interesting"));
        assert!(!adj_highlights.is_empty());
    }

    #[test]
    fn test_snippet_contains_match_mid_content() {
        let content = "The quick brown fox jumps over the lazy dog and runs away fast";
        let highlights = vec![hr(35, 39)];
        let (snippet, adj_highlights, _) = super::generate_snippet(content, &highlights, 30);
        assert!(snippet.contains("lazy"), "Snippet should contain the match");
        assert!(!adj_highlights.is_empty());
        let h = &adj_highlights[0];
        let highlighted: String = snippet.chars()
            .skip(h.start as usize)
            .take((h.end - h.start) as usize)
            .collect();
        assert_eq!(highlighted, "lazy");
    }

    #[test]
    fn test_snippet_match_at_start() {
        let content = "Hello world";
        let highlights = vec![hr(0, 5)];
        let (snippet, adj_highlights, _) = super::generate_snippet(content, &highlights, 50);
        assert_eq!(adj_highlights[0].start, 0, "Highlight should start at 0");
        assert_eq!(snippet, "Hello world");
    }

    #[test]
    fn test_snippet_normalizes_whitespace() {
        let content = "Line one\n\nLine two";
        let highlights = vec![hr(0, 4)];
        let (snippet, adj_highlights, _) = super::generate_snippet(content, &highlights, 50);
        assert!(!snippet.contains('\n'));
        assert!(!snippet.contains("  "));
        let h = &adj_highlights[0];
        let highlighted: String = snippet.chars()
            .skip(h.start as usize)
            .take((h.end - h.start) as usize)
            .collect();
        assert_eq!(highlighted, "Line");
    }

    #[test]
    fn test_snippet_highlight_adjustment_long_content() {
        let content = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaTARGET text here";
        let highlights = vec![hr(46, 52)];
        let (snippet, adj_highlights, _) = super::generate_snippet(content, &highlights, 30);
        assert!(snippet.contains("TARGET"));
        let h = &adj_highlights[0];
        let highlighted: String = snippet.chars()
            .skip(h.start as usize)
            .take((h.end - h.start) as usize)
            .collect();
        assert_eq!(highlighted, "TARGET");
    }

    #[test]
    fn test_snippet_very_long_content() {
        let long_prefix = "a".repeat(100);
        let long_suffix = "z".repeat(100);
        let content = format!("{}MATCH{}", long_prefix, long_suffix);
        let highlights = vec![hr(100, 105)];
        let (snippet, adj_highlights, _) = super::generate_snippet(&content, &highlights, 30);
        assert!(snippet.contains("MATCH"));
        let h = &adj_highlights[0];
        let highlighted: String = snippet.chars()
            .skip(h.start as usize)
            .take((h.end - h.start) as usize)
            .collect();
        assert_eq!(highlighted, "MATCH");
    }

    #[test]
    fn test_recency_weighted_score() {
        let now = 1700000000i64;
        let recent = recency_weighted_score(1000.0, now, now, false);
        let old = recency_weighted_score(1000.0, now - 86400 * 30, now, false);
        assert!(recent > old, "Recent items should score higher with same quality");
        let prefix = recency_weighted_score(1000.0, now, now, true);
        let non_prefix = recency_weighted_score(1000.0, now, now, false);
        assert!(prefix > non_prefix, "Prefix matches should score higher");
    }

    #[test]
    fn test_snippet_utf8_multibyte_chars() {
        let content = "Hello \u{4f60}\u{597d} world \u{1f30d} test";
        let highlights = vec![hr(6, 8)];
        let (snippet, adj_highlights, _) = super::generate_snippet(content, &highlights, 50);
        assert!(snippet.contains("\u{4f60}\u{597d}"));
        assert!(!adj_highlights.is_empty());
        let h = &adj_highlights[0];
        let highlighted: String = snippet.chars()
            .skip(h.start as usize)
            .take((h.end - h.start) as usize)
            .collect();
        assert_eq!(highlighted, "\u{4f60}\u{597d}");
    }

    #[test]
    fn test_tokenize_words() {
        let words = tokenize_words("hello world");
        assert_eq!(words, vec![(0, 5, "hello".into()), (6, 11, "world".into())]);

        let words = tokenize_words("urlparser.parse(input)");
        assert_eq!(words, vec![
            (0, 9, "urlparser".into()),
            (9, 10, ".".into()),
            (10, 15, "parse".into()),
            (15, 16, "(".into()),
            (16, 21, "input".into()),
            (21, 22, ")".into()),
        ]);

        let words = tokenize_words("one--two...three");
        assert_eq!(words, vec![
            (0, 3, "one".into()),
            (3, 5, "--".into()),
            (5, 8, "two".into()),
            (8, 11, "...".into()),
            (11, 16, "three".into()),
        ]);

        let words = tokenize_words("https://github.com");
        assert_eq!(words, vec![
            (0, 5, "https".into()),
            (5, 8, "://".into()),
            (8, 14, "github".into()),
            (14, 15, ".".into()),
            (15, 18, "com".into()),
        ]);
    }

    fn highlighted_words(content: &str, query_words: &[&str]) -> Vec<String> {
        let fm = super::highlight_candidate(1, content, 1000, 1.0, query_words, false);
        let chars: Vec<char> = content.chars().collect();
        fm.highlight_ranges.iter().map(|r| {
            chars[r.start as usize..r.end as usize].iter().collect()
        }).collect()
    }

    #[test]
    fn test_highlight_exact_match() {
        let words = highlighted_words("hello world", &["hello"]);
        assert_eq!(words, vec!["hello"]);
    }

    #[test]
    fn test_highlight_typo_match() {
        let words = highlighted_words("Visit Riverside Park today", &["riversde"]);
        assert_eq!(words, vec!["Riverside"]);
    }

    #[test]
    fn test_highlight_prefix_match() {
        let fm = super::highlight_candidate(1, "Run testing suite now", 1000, 1.0, &["test"], true);
        let chars: Vec<char> = "Run testing suite now".chars().collect();
        let words: Vec<String> = fm.highlight_ranges.iter().map(|r| {
            chars[r.start as usize..r.end as usize].iter().collect()
        }).collect();
        assert_eq!(words, vec!["testing"]);
    }

    #[test]
    fn test_highlight_subsequence_short_word() {
        let words = highlighted_words("hello world", &["helo"]);
        assert_eq!(words, vec!["hello"]);
    }

    #[test]
    fn test_highlight_no_match_short_word() {
        let words = highlighted_words("hello world", &["hx"]);
        assert!(words.is_empty());
    }

    #[test]
    fn test_highlight_multi_word() {
        let words = highlighted_words("hello beautiful world", &["hello", "world"]);
        assert_eq!(words, vec!["hello", "world"]);
    }

    #[test]
    fn test_highlight_short_exact_word() {
        let words = highlighted_words("hi there highway", &["hi"]);
        assert_eq!(words, vec!["hi"]);
    }

    #[test]
    fn test_highlight_multiple_occurrences() {
        let words = highlighted_words("hello world hello again", &["hello"]);
        assert_eq!(words, vec!["hello", "hello"]);
    }

    #[test]
    fn test_highlight_no_match() {
        let words = highlighted_words("hello world", &["xyz"]);
        assert!(words.is_empty());
    }

    #[test]
    fn test_highlight_url_query_bridges_punctuation() {
        let words = highlighted_words("https://github.com/user/repo", &["http", "github"]);
        assert_eq!(words, vec!["https://github"]);
    }

    #[test]
    fn test_highlight_url_query_tokenized_from_raw() {
        let query = "http://github";
        let query_words_owned = tokenize_words(query);
        let query_words: Vec<&str> = query_words_owned.iter().map(|(_, _, w)| w.as_str()).collect();
        assert_eq!(query_words, vec!["http", "://", "github"]);

        let fm = highlight_candidate(1, "https://github.com/user/repo", 1000, 1.0, &query_words, false);
        let chars: Vec<char> = "https://github.com/user/repo".chars().collect();
        let words: Vec<String> = fm.highlight_ranges.iter().map(|r| {
            chars[r.start as usize..r.end as usize].iter().collect()
        }).collect();
        assert_eq!(words, vec!["https://github"]);
    }

    #[test]
    fn test_highlight_does_not_bridge_whitespace_gaps() {
        let words = highlighted_words("hello beautiful world", &["hello", "world"]);
        assert_eq!(words, vec!["hello", "world"]);
    }

    #[test]
    fn test_highlight_bridges_dots_in_domain() {
        let words = highlighted_words("https://github.com", &["github", "com"]);
        assert_eq!(words, vec!["github.com"]);
    }

    #[test]
    fn test_find_densest_highlight_empty() {
        assert_eq!(find_densest_highlight(&[], 500), None);
    }

    #[test]
    fn test_find_densest_highlight_single() {
        let highlights = vec![hr(50, 55)];
        assert_eq!(super::find_densest_highlight(&highlights, 500), Some(0));
    }

    #[test]
    fn test_find_densest_highlight_picks_denser_cluster() {
        let highlights = vec![
            hr(0, 5),
            hr(1000, 1005),
            hr(1050, 1055),
            hr(1100, 1105),
        ];
        let idx = find_densest_highlight(&highlights, 500).unwrap();
        assert_eq!(highlights[idx].start, 1000);
    }

    #[test]
    fn test_snippet_centers_on_densest_cluster() {
        let mut content = "a".repeat(10);
        content.push_str("LONE");
        content.push_str(&"b".repeat(986));
        content.push_str("DENSE1");
        content.push_str("xx");
        content.push_str("DENSE2");
        content.push_str("yy");
        content.push_str("DENSE3");
        content.push_str(&"c".repeat(100));

        let highlights = vec![
            hr(10, 14),
            hr(1000, 1006),
            hr(1008, 1014),
            hr(1016, 1022),
        ];

        let (snippet, _, _) = generate_snippet(&content, &highlights, 100);
        assert!(snippet.contains("DENSE1"), "Snippet should center on densest cluster, got: {}", snippet);
        assert!(snippet.contains("DENSE2"));
    }

    const NIX_BUILD_ERROR: &str = "\
    'path:./hosts/default'
  \u{2192} 'path:/Users/julsh/git/dotfiles/nix/hosts/local?lastModified=1770783424&narHash=sha256-I8uZtr2R0rm1z9UzZNkj/ofk%2B2mSNp7ElUS67Bhj7js%3D' (2026-02-11)
error: Cannot build '/nix/store/dsq2qkgpgq6nysisychilwx9gwpcg1i1-inetutils-2.7.drv'.
       Reason: builder failed with exit code 2.
       Output paths:
         /nix/store/n9yl2hqsljax4gabc7c1qbxbkb0j6l55-inetutils-2.7
         /nix/store/pk6z47v44zjv29y37rxdy8b6nszh8x8f-inetutils-2.7-apparmor
       Last 25 log lines:
       > openat-die.c:31:18: note: expanded from macro '_'
       >    31 | #define _(msgid) dgettext (GNULIB_TEXT_DOMAIN, msgid)
       >       |                  ^
       > ./gettext.h:127:39: note: expanded from macro 'dgettext'
       >   127 | #  define dgettext(Domainname, Msgid) ((void) (Domainname), gettext (Msgid))
       >       |                                       ^
       > ./error.h:506:39: note: expanded from macro 'error'
       >   506 |       __gl_error_call (error, status, __VA_ARGS__)
       >       |                                       ^
       > ./error.h:446:51: note: expanded from macro '__gl_error_call'
       >   446 |          __gl_error_call1 (function, __errstatus, __VA_ARGS__); \\
       >       |                                                   ^
       > ./error.h:431:26: note: expanded from macro '__gl_error_call1'
       >   431 |     ((function) (status, __VA_ARGS__), \\
       >       |                          ^
       > 4 errors generated.
       > make[4]: *** [Makefile:6332: libgnu_a-openat-die.o] Error 1
       > make[4]: Leaving directory '/nix/var/nix/builds/nix-55927-395412078/inetutils-2.7/lib'
       > make[3]: *** [Makefile:8385: all-recursive] Error 1
       > make[3]: Leaving directory '/nix/var/nix/builds/nix-55927-395412078/inetutils-2.7/lib'
       > make[2]: *** [Makefile:3747: all] Error 2
       > make[2]: Leaving directory '/nix/var/nix/builds/nix-55927-395412078/inetutils-2.7/lib'
       > make[1]: *** [Makefile:2630: all-recursive] Error 1
       > make[1]: Leaving directory '/nix/var/nix/builds/nix-55927-395412078/inetutils-2.7'
       > make: *** [Makefile:2567: all] Error 2
       For full logs, run:
         nix-store -l /nix/store/dsq2qkgpgq6nysisychilwx9gwpcg1i1-inetutils-2.7.drv
error: Cannot build '/nix/store/djv08y006z7jk69j2q9fq5f1ch195i4s-home-manager.drv'.
       Reason: 1 dependency failed.
       Output paths:
         /nix/store/67pn4ck72akj3bz7d131wdcz6w4gb5qb-home-manager
error: Build failed due to failed dependency";

    fn build_query_words(query: &str) -> Vec<String> {
        query.to_lowercase().split_whitespace().map(|s| s.to_string()).collect()
    }

    #[test]
    fn test_densest_highlight_prefers_exact_query_match_over_scattered_repeats() {
        let query_words_owned = build_query_words("error: build failed due to dependency");
        let query_words: Vec<&str> = query_words_owned.iter().map(|s| s.as_str()).collect();
        let fm = highlight_candidate(1, NIX_BUILD_ERROR, 1000, 1.0, &query_words, false);

        let densest_idx = find_densest_highlight(&fm.highlight_ranges, SNIPPET_CONTEXT_CHARS as u64).unwrap();
        let densest_start = fm.highlight_ranges[densest_idx].start as usize;

        let final_block = "error: Cannot build '/nix/store/djv08y006z7jk69j2q9fq5f1ch195i4s-home-manager.drv'.";
        let final_block_byte_pos = NIX_BUILD_ERROR.rfind(final_block).unwrap();
        let final_block_char_pos = NIX_BUILD_ERROR[..final_block_byte_pos].chars().count();

        assert!(
            densest_start >= final_block_char_pos,
            "Densest highlight at char {} should be in final error block (char {}+). \
             Points to: {:?}",
            densest_start,
            final_block_char_pos,
            NIX_BUILD_ERROR.chars().skip(densest_start).take(60).collect::<String>()
        );
    }

    #[test]
    fn test_snippet_centers_on_exact_query_match_not_scattered_repeats() {
        let query_words_owned = build_query_words("error: build failed due to dependency");
        let query_words: Vec<&str> = query_words_owned.iter().map(|s| s.as_str()).collect();
        let fm = highlight_candidate(1, NIX_BUILD_ERROR, 1000, 1.0, &query_words, false);

        let (snippet, _, _) = generate_snippet(NIX_BUILD_ERROR, &fm.highlight_ranges, SNIPPET_CONTEXT_CHARS * 2);

        assert!(
            snippet.contains("Build failed due to failed dependency"),
            "Snippet should center on the near-exact match line, got: {}",
            snippet
        );
    }

    // ── HighlightKind verification tests ──────────────────────────

    #[test]
    fn test_highlight_match_kind_exact() {
        let fm = highlight_candidate(1, "hello world", 1000, 1.0, &["hello"], false);
        assert_eq!(fm.highlight_ranges.len(), 1);
        assert_eq!(fm.highlight_ranges[0].kind, HighlightKind::Exact);
    }

    #[test]
    fn test_highlight_match_kind_prefix() {
        let fm = highlight_candidate(1, "Run testing suite now", 1000, 1.0, &["test"], true);
        assert_eq!(fm.highlight_ranges.len(), 1);
        assert_eq!(fm.highlight_ranges[0].kind, HighlightKind::Prefix);
    }

    #[test]
    fn test_highlight_match_kind_fuzzy() {
        // "riversde" matches "riverside" via fuzzy edit distance
        let fm = highlight_candidate(1, "Visit Riverside Park today", 1000, 1.0, &["riversde"], false);
        assert_eq!(fm.highlight_ranges.len(), 1);
        assert_eq!(fm.highlight_ranges[0].kind, HighlightKind::Fuzzy);
    }

    #[test]
    fn test_highlight_match_kind_subsequence() {
        // "impt" matches "import" via subsequence (length diff 2 exceeds max_edit_distance)
        let fm = highlight_candidate(1, "import React from react", 1000, 1.0, &["impt"], false);
        assert_eq!(fm.highlight_ranges.len(), 1);
        assert_eq!(fm.highlight_ranges[0].kind, HighlightKind::Subsequence);
    }
}
