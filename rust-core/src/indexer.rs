//! Tantivy Indexer for ClipKitty
//!
//! Provides full-text search with trigram (ngram) tokenization for efficient fuzzy matching.
//! For queries under 3 characters, returns empty (handled by search.rs streaming fallback).

use crate::search::{RECENCY_BOOST_MAX, RECENCY_HALF_LIFE_SECS};
use chrono::Utc;
use parking_lot::RwLock;
use std::path::Path;
use tantivy::collector::TopDocs;
use tantivy::directory::MmapDirectory;
use tantivy::query::{BooleanQuery, BoostQuery, Occur, PhraseQuery, TermQuery};
use tantivy::schema::*;
use tantivy::tokenizer::{NgramTokenizer, TextAnalyzer};
use tantivy::{DocId, Index, IndexReader, IndexWriter, ReloadPolicy, Score, Term};
use thiserror::Error;

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

/// A search candidate from Tantivy (before fuzzy re-ranking)
#[derive(Debug, Clone)]
pub struct SearchCandidate {
    pub id: i64,
    pub content: String,
    pub timestamp: i64,
    /// Blended score (BM25 + recency) from Tantivy's tweak_score
    pub tantivy_score: f32,
}

/// Tantivy-based indexer with trigram tokenization
pub struct Indexer {
    index: Index,
    writer: RwLock<IndexWriter>,
    reader: RwLock<IndexReader>,
    schema: Schema,
    id_field: Field,
    content_field: Field,
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

    /// Register the trigram tokenizer with the index
    fn register_tokenizer(index: &Index) {
        let tokenizer = TextAnalyzer::builder(NgramTokenizer::new(3, 3, false).unwrap())
            .filter(tantivy::tokenizer::LowerCaser)
            .build();
        index.tokenizers().register("trigram", tokenizer);
    }

    /// Add or update a document in the index
    pub fn add_document(&self, id: i64, content: &str, timestamp: i64) -> IndexerResult<()> {
        let writer = self.writer.write();

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

    pub fn commit(&self) -> IndexerResult<()> {
        self.writer.write().commit()?;
        self.reader.write().reload()?;
        Ok(())
    }

    pub fn delete_document(&self, id: i64) -> IndexerResult<()> {
        let writer = self.writer.write();
        let id_term = tantivy::Term::from_field_i64(self.id_field, id);
        writer.delete_term(id_term);
        Ok(())
    }

    pub fn search(&self, query: &str, limit: usize) -> IndexerResult<Vec<SearchCandidate>> {
        let reader = self.reader.read();
        let searcher = reader.searcher();

        // Tokenize query using the same trigram tokenizer
        let mut tokenizer = self.index.tokenizers().get("trigram").unwrap();
        let mut token_stream = tokenizer.token_stream(query);
        let mut terms = Vec::new();
        while let Some(token) = token_stream.next() {
            terms.push(Term::from_field_text(self.content_field, &token.text));
        }

        // Query too short for trigrams - return empty (minimum 3 chars required)
        // search.rs handles <3 char queries via streaming fallback
        if terms.is_empty() {
            return Ok(Vec::new());
        }

        let num_terms = terms.len();

        // Build OR query from all trigram terms
        let subqueries: Vec<_> = terms
            .into_iter()
            .map(|term| {
                let q: Box<dyn tantivy::query::Query> =
                    Box::new(TermQuery::new(term, IndexRecordOption::WithFreqs));
                (Occur::Should, q)
            })
            .collect();
        let mut tantivy_query = BooleanQuery::new(subqueries);

        // For queries with 7+ trigrams (~9+ chars), require most trigrams to match.
        // This filters "soup" matches at the index level - documents that only
        // contain scattered trigrams (like long texts with common English word
        // overlaps) are never fetched.
        //
        // Short queries (< 7 trigrams) skip this filter entirely to preserve
        // typo tolerance for shorter searches.
        if num_terms >= 7 {
            // Use 4/5 for long queries (20+ trigrams) where common-word overlap
            // in long documents can produce false matches, 2/3 for medium queries.
            let ratio = if num_terms >= 20 { 4 * num_terms / 5 } else { num_terms * 2 / 3 };
            let min_match = ratio.max(5);
            tantivy_query.set_minimum_number_should_match(min_match);
        }

        // Build phrase-boost queries for contiguity-aware scoring.
        // For each query word >= 4 chars, create a PhraseQuery from its trigrams
        // and wrap it in a BoostQuery. Documents with contiguous word matches
        // get naturally higher BM25 + phrase scores.
        let words: Vec<&str> = query.split_whitespace().collect();
        let mut phrase_boosts: Vec<(Occur, Box<dyn tantivy::query::Query>)> = Vec::new();

        for word in &words {
            if word.len() < 3 {
                continue;
            }
            let mut word_tokenizer = self.index.tokenizers().get("trigram").unwrap();
            let mut word_stream = word_tokenizer.token_stream(word);
            let mut word_terms = Vec::new();
            while let Some(token) = word_stream.next() {
                word_terms.push(Term::from_field_text(self.content_field, &token.text));
            }
            if word_terms.len() >= 2 {
                let phrase = PhraseQuery::new(word_terms);
                let boosted: Box<dyn tantivy::query::Query> =
                    Box::new(BoostQuery::new(Box::new(phrase), 2.0));
                phrase_boosts.push((Occur::Should, boosted));
            }
        }

        // Word-pair proximity boosts: for consecutive query word pairs,
        // tokenize "word1 word2" together. Cross-boundary trigrams form a
        // PhraseQuery that fires only when the words are adjacent.
        if words.len() >= 2 {
            for pair in words.windows(2) {
                if pair[0].len() < 2 || pair[1].len() < 2 {
                    continue;
                }
                let pair_str = format!("{} {}", pair[0], pair[1]);
                let mut pair_tokenizer = self.index.tokenizers().get("trigram").unwrap();
                let mut pair_stream = pair_tokenizer.token_stream(&pair_str);
                let mut pair_terms = Vec::new();
                while let Some(token) = pair_stream.next() {
                    pair_terms.push(Term::from_field_text(self.content_field, &token.text));
                }
                if pair_terms.len() >= 2 {
                    let phrase = PhraseQuery::new(pair_terms);
                    let boosted: Box<dyn tantivy::query::Query> =
                        Box::new(BoostQuery::new(Box::new(phrase), 3.0));
                    phrase_boosts.push((Occur::Should, boosted));
                }
            }
        }

        // Full-query exactness boost: tokenize the entire multi-word query
        // into trigrams. PhraseQuery rewards documents containing the full
        // query as a contiguous phrase.
        if words.len() >= 2 {
            let mut full_tokenizer = self.index.tokenizers().get("trigram").unwrap();
            let mut full_stream = full_tokenizer.token_stream(query);
            let mut full_terms = Vec::new();
            while let Some(token) = full_stream.next() {
                full_terms.push(Term::from_field_text(self.content_field, &token.text));
            }
            if full_terms.len() >= 2 {
                let phrase = PhraseQuery::new(full_terms);
                let boosted: Box<dyn tantivy::query::Query> =
                    Box::new(BoostQuery::new(Box::new(phrase), 5.0));
                phrase_boosts.push((Occur::Should, boosted));
            }
        }

        // Combine recall query (MUST) with phrase boosts (SHOULD)
        let final_query: Box<dyn tantivy::query::Query> = if phrase_boosts.is_empty() {
            Box::new(tantivy_query)
        } else {
            let mut outer_parts: Vec<(Occur, Box<dyn tantivy::query::Query>)> = Vec::new();
            outer_parts.push((Occur::Must, Box::new(tantivy_query)));
            outer_parts.extend(phrase_boosts);
            Box::new(BooleanQuery::new(outer_parts))
        };

        // Use tweak_score to blend BM25 with recency at collection time.
        // Tantivy's top-K heap works on the final blended score, so we get
        // the true top results without a separate sort step.
        let timestamp_field = self.schema.get_field("timestamp").unwrap();
        let now = Utc::now().timestamp();

        let collector = TopDocs::with_limit(limit)
            .tweak_score(move |segment_reader: &tantivy::SegmentReader| {
                let ts_reader = segment_reader
                    .fast_fields()
                    .i64("timestamp")
                    .expect("timestamp fast field");
                move |doc: DocId, score: Score| {
                    let timestamp = ts_reader.first(doc).unwrap_or(0);
                    // Quantize BM25 coarsely so minor doc-length differences
                    // are treated as ties, letting recency break them.
                    let base = ((score as u32).max(1) * 1000) as f64;
                    let age_secs = (now - timestamp).max(0) as f64;
                    let recency = (-age_secs * 2.0_f64.ln() / RECENCY_HALF_LIFE_SECS).exp();
                    base * (1.0 + RECENCY_BOOST_MAX * recency)
                }
            });

        let top_docs = searcher.search(final_query.as_ref(), &collector)?;

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

}
