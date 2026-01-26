//! Tantivy Indexer for ClipKitty
//!
//! Provides full-text search with trigram (ngram) tokenization for efficient fuzzy matching.
//! Uses Manual reload policy for immediate visibility after commits.

use parking_lot::RwLock;
use std::path::Path;
use tantivy::collector::TopDocs;
use tantivy::directory::MmapDirectory;
use tantivy::query::{BooleanQuery, Occur, TermQuery};
use tantivy::schema::*;
use tantivy::tokenizer::{NgramTokenizer, TextAnalyzer};
use tantivy::{Index, IndexReader, IndexWriter, ReloadPolicy, Term};
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

        // Try to open existing index or create new
        let index = Index::open_or_create(dir, schema.clone())?;

        // Register trigram tokenizer
        Self::register_tokenizer(&index);

        let writer = index.writer(50_000_000)?; // 50MB buffer
        let reader = index
            .reader_builder()
            .reload_policy(ReloadPolicy::Manual)
            .try_into()?;

        let id_field = schema.get_field("id").unwrap();
        let content_field = schema.get_field("content").unwrap();

        Ok(Self {
            index,
            writer: RwLock::new(writer),
            reader: RwLock::new(reader),
            schema,
            id_field,
            content_field,
        })
    }

    /// Create an in-memory indexer (for testing)
    pub fn new_in_memory() -> IndexerResult<Self> {
        let schema = Self::build_schema();
        let index = Index::create_in_ram(schema.clone());

        // Register trigram tokenizer
        Self::register_tokenizer(&index);

        let writer = index.writer(15_000_000)?; // 15MB buffer for tests
        let reader = index
            .reader_builder()
            .reload_policy(ReloadPolicy::Manual)
            .try_into()?;

        let id_field = schema.get_field("id").unwrap();
        let content_field = schema.get_field("content").unwrap();

        Ok(Self {
            index,
            writer: RwLock::new(writer),
            reader: RwLock::new(reader),
            schema,
            id_field,
            content_field,
        })
    }

    /// Build the schema with trigram tokenization on content field
    fn build_schema() -> Schema {
        let mut schema_builder = Schema::builder();

        // ID field - stored, fast access, and indexed for deletion
        schema_builder.add_i64_field("id", STORED | FAST | INDEXED);

        // Content field with trigram tokenization
        let text_field_indexing = TextFieldIndexing::default()
            .set_tokenizer("trigram")
            .set_index_option(IndexRecordOption::WithFreqsAndPositions);
        let text_options = TextOptions::default()
            .set_indexing_options(text_field_indexing)
            .set_stored();
        schema_builder.add_text_field("content", text_options);

        // Timestamp for sorting
        schema_builder.add_i64_field("timestamp", FAST);

        schema_builder.build()
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

    /// Commit pending changes and reload reader
    pub fn commit(&self) -> IndexerResult<()> {
        {
            let mut writer = self.writer.write();
            writer.commit()?;
        }
        // Reload reader to see new commits
        self.reader.write().reload()?;
        Ok(())
    }

    /// Delete a document by ID
    pub fn delete_document(&self, id: i64) -> IndexerResult<()> {
        let writer = self.writer.write();
        let id_term = tantivy::Term::from_field_i64(self.id_field, id);
        writer.delete_term(id_term);
        Ok(())
    }

    /// Search for documents matching the query
    /// Returns candidates for fuzzy re-ranking
    pub fn search(&self, query: &str) -> IndexerResult<Vec<SearchCandidate>> {
        let reader = self.reader.read();
        let searcher = reader.searcher();

        // Tokenize query using the same trigram tokenizer and build query directly
        // This bypasses the query parser entirely, treating all input as literal text
        let mut tokenizer = self.index.tokenizers().get("trigram").unwrap();
        let mut token_stream = tokenizer.token_stream(query);
        let mut terms = Vec::new();
        while let Some(token) = token_stream.next() {
            terms.push(Term::from_field_text(self.content_field, &token.text));
        }

        // Query too short for trigrams - return empty (minimum 3 chars required)
        if terms.is_empty() {
            return Ok(Vec::new());
        }

        // Build OR query from all trigram terms
        let subqueries: Vec<_> = terms
            .into_iter()
            .map(|term| {
                let q: Box<dyn tantivy::query::Query> =
                    Box::new(TermQuery::new(term, IndexRecordOption::WithFreqs));
                (Occur::Should, q)
            })
            .collect();
        let tantivy_query = BooleanQuery::new(subqueries);

        // Get top 5000 candidates (will be re-ranked by fuzzy matcher)
        let top_docs = searcher.search(&tantivy_query, &TopDocs::with_limit(5000))?;

        let mut candidates = Vec::with_capacity(top_docs.len());

        for (_score, doc_address) in top_docs {
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
                .get_first(self.schema.get_field("timestamp").unwrap())
                .and_then(|v| v.as_i64())
                .unwrap_or(0);

            candidates.push(SearchCandidate { id, content, timestamp });
        }

        Ok(candidates)
    }

    /// Clear all documents from the index
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
        let reader = self.reader.read();
        reader.searcher().num_docs()
    }
}

// Thread safety for UniFFI
unsafe impl Send for Indexer {}
unsafe impl Sync for Indexer {}

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
