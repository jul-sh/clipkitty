//! Tantivy Indexer for ClipKitty
//!
//! Two-phase search: trigram recall (Phase 1) + Milli-style bucket re-ranking (Phase 2).
//! For queries under 3 characters, returns empty (handled by search.rs streaming fallback).

use crate::candidate::SearchCandidate;
use crate::ranking::compute_bucket_score;
use crate::search::{RECENCY_BOOST_MAX, RECENCY_HALF_LIFE_SECS};
use chrono::Utc;
use parking_lot::RwLock;
use std::path::Path;
use tantivy::collector::TopDocs;
use tantivy::directory::MmapDirectory;
use tantivy::query::{BooleanQuery, BoostQuery, FuzzyTermQuery, Occur, PhraseQuery, TermQuery};
use tantivy::schema::*;
use tantivy::tokenizer::{NgramTokenizer, TextAnalyzer, TokenFilter, TokenStream, Tokenizer};
use tantivy::{DocId, Index, IndexReader, IndexWriter, ReloadPolicy, Score, Term};
use thiserror::Error;

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

/// Tantivy-based indexer with trigram tokenization
pub struct Indexer {
    index: Index,
    writer: RwLock<IndexWriter>,
    reader: RwLock<IndexReader>,
    schema: Schema,
    id_field: Field,
    content_field: Field,
    content_words_field: Field,
}

impl Indexer {
    /// Create a new indexer at the given path
    pub fn new(path: &Path) -> IndexerResult<Self> {
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
    pub fn new_in_memory() -> IndexerResult<Self> {
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
            content_words_field: schema.get_field("content_words").unwrap(),
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

        // Word-tokenized field for FuzzyTermQuery recall (not stored — content lives on trigram field)
        let word_field_indexing = TextFieldIndexing::default()
            .set_tokenizer("default")
            .set_index_option(IndexRecordOption::Basic);
        let word_options = TextOptions::default().set_indexing_options(word_field_indexing);
        builder.add_text_field("content_words", word_options);

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
    pub fn add_document(&self, id: i64, content: &str, timestamp: i64) -> IndexerResult<()> {
        let writer = self.writer.read();

        // Delete existing document with same ID (upsert semantics)
        let id_term = tantivy::Term::from_field_i64(self.id_field, id);
        writer.delete_term(id_term);

        // Add new document
        let mut doc = tantivy::TantivyDocument::default();
        doc.add_i64(self.id_field, id);
        doc.add_text(self.content_field, content);
        doc.add_text(self.content_words_field, content);
        doc.add_i64(self.schema.get_field("timestamp").unwrap(), timestamp);

        writer.add_document(doc)?;

        Ok(())
    }

    pub fn commit(&self) -> IndexerResult<()> {
        self.writer.write().commit()?;
        self.reader.write().reload()?;
        Ok(())
    }

    pub fn delete_document(&self, id: i64) -> IndexerResult<()> {
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
    pub fn search(&self, query: &str, limit: usize) -> IndexerResult<Vec<SearchCandidate>> {
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

        // Phase 2: Bucket re-ranking (parallelized — compute_bucket_score is a pure function)
        let query_words_owned = crate::search::tokenize_words(query);
        let query_words: Vec<&str> = query_words_owned.iter().map(|(_, _, w)| w.as_str()).collect();
        let last_word_is_prefix = query.ends_with(|c: char| c.is_alphanumeric());
        let now = Utc::now().timestamp();

        use rayon::prelude::*;
        let mut scored: Vec<(crate::ranking::BucketScore, usize)> = candidates
            .par_iter()
            .enumerate()
            .map(|(i, c)| {
                let content_lower = c.content().to_lowercase();
                let doc_words = crate::search::tokenize_words(&content_lower);
                let doc_word_strs: Vec<&str> = doc_words.iter().map(|(_, _, w)| w.as_str()).collect();
                let bucket = compute_bucket_score(
                    &content_lower,
                    &doc_word_strs,
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
            .filter_map(|(_, i)| candidate_slots[i].take())
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

            candidates.push(SearchCandidate::new(id, content, timestamp, blended_score as f32));
        }

        Ok(candidates)
    }

    /// Build FuzzyTermQuery clauses on the word-tokenized field.
    /// For each query word with 3+ chars, creates a Levenshtein DFA query
    /// that catches substitutions, insertions, and deletions that trigrams miss.
    ///
    /// Only active for queries with 1-3 words. For 4+ word queries, the
    /// correctly-typed words provide enough trigrams for the trigram pathway;
    /// adding fuzzy clauses would recall scattered common-word matches.
    fn build_fuzzy_word_clauses(&self, query: &str) -> Vec<Box<dyn tantivy::query::Query>> {
        let words: Vec<&str> = query.split_whitespace().collect();
        if words.len() >= 4 {
            return Vec::new();
        }
        let last_word_is_prefix = query.ends_with(|c: char| c.is_alphanumeric());

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

        // Build the recall part: trigram OR fuzzy-word pathways
        let fuzzy_clauses = self.build_fuzzy_word_clauses(query);
        let recall: Box<dyn tantivy::query::Query> = if fuzzy_clauses.is_empty() {
            Box::new(recall_query)
        } else {
            // Require at least half the fuzzy clauses to match. Since this
            // pathway is limited to 1-3 word queries, the threshold stays
            // tight enough to avoid scattered common-word matches.
            let n = fuzzy_clauses.len();
            let fuzzy_min = (n + 1) / 2;
            let fuzzy_subqueries: Vec<(Occur, Box<dyn tantivy::query::Query>)> =
                fuzzy_clauses.into_iter().map(|q| (Occur::Should, q)).collect();
            let mut fuzzy_bool = BooleanQuery::new(fuzzy_subqueries);
            fuzzy_bool.set_minimum_number_should_match(fuzzy_min);

            // OR: document passes if it matches EITHER trigrams OR fuzzy words
            let mut combined = BooleanQuery::new(vec![
                (Occur::Should, Box::new(recall_query) as Box<dyn tantivy::query::Query>),
                (Occur::Should, Box::new(fuzzy_bool) as Box<dyn tantivy::query::Query>),
            ]);
            combined.set_minimum_number_should_match(1);
            Box::new(combined)
        };

        if phrase_boosts.is_empty() {
            recall
        } else {
            let mut outer: Vec<(Occur, Box<dyn tantivy::query::Query>)> = Vec::new();
            outer.push((Occur::Must, recall));
            outer.extend(phrase_boosts);
            Box::new(BooleanQuery::new(outer))
        }
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

        // Update same ID - should replace, not duplicate
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
        assert!(ids.contains(&1), "substitution 'tast' should recall doc with 'test', got {:?}", ids);
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
        assert!(ids.contains(&1), "insertion 'tesst' should recall doc with 'test', got {:?}", ids);
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
        assert!(ids.contains(&1), "deletion 'tst' should recall doc with 'test', got {:?}", ids);
    }

    #[test]
    fn test_fuzzy_word_multi_word_query() {
        // "quikc brown" — substitution typo in "quick"
        let indexer = Indexer::new_in_memory().unwrap();
        indexer.add_document(1, "the quick brown fox jumps", 1000).unwrap();
        indexer.add_document(2, "a slow red dog sleeps", 1000).unwrap();
        indexer.commit().unwrap();

        let results = indexer.search("quikc brown", 10).unwrap();
        let ids: Vec<i64> = results.iter().map(|c| c.id).collect();
        assert!(ids.contains(&1), "'quikc brown' should recall doc with 'quick brown', got {:?}", ids);
        assert!(!ids.contains(&2));
    }

    #[test]
    fn test_existing_trigram_recall_unchanged() {
        // Exact match still works through the trigram pathway
        let indexer = Indexer::new_in_memory().unwrap();
        indexer.add_document(1, "hello world greeting", 1000).unwrap();
        indexer.add_document(2, "goodbye universe farewell", 1000).unwrap();
        indexer.commit().unwrap();

        let results = indexer.search("hello", 10).unwrap();
        let ids: Vec<i64> = results.iter().map(|c| c.id).collect();
        assert!(ids.contains(&1), "exact 'hello' should recall doc 1, got {:?}", ids);
        assert!(!ids.contains(&2));
    }
}
