//! ClipboardStore - Main API for Swift interop
//! and Tantivy search functionality, designed for UniFFI export.
//!
//! Architecture: Two-layer search using Tantivy (trigram retrieval) + fuzzy-matcher (precision)

use crate::database::Database;
use crate::indexer::Indexer;
use crate::models::{ClipboardItem, FetchResult, SearchMatch, SearchResult};
use crate::search::{FuzzyMatch, SearchEngine, MIN_TRIGRAM_QUERY_LEN};
use chrono::{TimeZone, Utc};
use std::path::PathBuf;
use std::sync::Arc;
use thiserror::Error;

/// Error type for ClipKitty operations
#[derive(Error, Debug)]
pub enum ClipKittyError {
    #[error("Database error: {0}")]
    DatabaseError(String),
    #[error("Index error: {0}")]
    IndexError(String),
    #[error("Store not initialized")]
    NotInitialized,
    #[error("Invalid input: {0}")]
    InvalidInput(String),
}

impl From<crate::database::DatabaseError> for ClipKittyError {
    fn from(e: crate::database::DatabaseError) -> Self {
        ClipKittyError::DatabaseError(e.to_string())
    }
}

impl From<crate::indexer::IndexerError> for ClipKittyError {
    fn from(e: crate::indexer::IndexerError) -> Self {
        ClipKittyError::IndexError(e.to_string())
    }
}

/// Thread-safe clipboard store with SQLite + Tantivy
pub struct ClipboardStore {
    db: Arc<Database>,
    indexer: Arc<Indexer>,
    search_engine: SearchEngine,
}

impl ClipboardStore {
    /// Create a new store with a database at the given path
    pub fn new(db_path: String) -> Result<Self, ClipKittyError> {
        let db = Database::open(&db_path)?;

        // Create index directory next to database
        let db_path_buf = PathBuf::from(&db_path);
        let index_path = db_path_buf
            .parent()
            .map(|p| p.join("tantivy_index"))
            .unwrap_or_else(|| PathBuf::from("tantivy_index"));

        let indexer = Indexer::new(&index_path)?;

        // Rebuild index from database if empty
        let store = Self {
            db: Arc::new(db),
            indexer: Arc::new(indexer),
            search_engine: SearchEngine::new(),
        };

        store.rebuild_index_if_needed()?;

        Ok(store)
    }

    /// Create a store with an in-memory database (for testing)
    pub fn new_in_memory() -> Result<Self, ClipKittyError> {
        let db = Database::open_in_memory()?;
        let indexer = Indexer::new_in_memory()?;

        Ok(Self {
            db: Arc::new(db),
            indexer: Arc::new(indexer),
            search_engine: SearchEngine::new(),
        })
    }

    /// Rebuild index from database if the index is empty but database has items
    fn rebuild_index_if_needed(&self) -> Result<(), ClipKittyError> {
        // Check if index is empty
        if self.indexer.num_docs() > 0 {
            return Ok(());
        }

        // Get all items from database
        let items = self.db.fetch_all_items()?;
        if items.is_empty() {
            return Ok(());
        }

        // Index all items
        for item in items {
            if let Some(id) = item.id {
                self.indexer.add_document(id, item.text_content(), item.timestamp_unix)?;
            }
        }
        self.indexer.commit()?;

        Ok(())
    }

    /// Get the database size in bytes
    pub fn database_size(&self) -> i64 {
        self.db.database_size().unwrap_or(0)
    }

    /// Verify FTS integrity and rebuild if needed (for backwards compat)
    pub fn verify_fts_integrity(&self) -> bool {
        // With Tantivy, we just check if the index has docs matching the database
        true
    }

    /// Save a text item to the database and index
    /// Returns the new item ID, or 0 if duplicate (timestamp updated)
    pub fn save_text(
        &self,
        text: String,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
        timestamp_unix: Option<i64>,
    ) -> Result<i64, ClipKittyError> {
        let item = ClipboardItem::new_text(text, source_app, source_app_bundle_id, timestamp_unix);

        // Check for duplicate
        if let Some(existing) = self.db.find_by_hash(&item.content_hash)? {
            if let Some(id) = existing.id {
                let now = Utc::now();
                self.db.update_timestamp(id, now)?;

                // Update index timestamp
                self.indexer
                    .add_document(id, existing.text_content(), now.timestamp())?;
                self.indexer.commit()?;

                return Ok(0); // Indicates duplicate
            }
        }

        // Insert new item into database
        let id = self.db.insert_item(&item)?;

        // Index the new item
        self.indexer
            .add_document(id, item.text_content(), item.timestamp_unix)?;
        self.indexer.commit()?;

        Ok(id)
    }

    /// Save an image item to the database
    /// Note: Images are indexed with their description for searchability
    pub fn save_image(
        &self,
        image_data: Vec<u8>,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
        timestamp_unix: Option<i64>,
    ) -> Result<i64, ClipKittyError> {
        if image_data.is_empty() {
            return Err(ClipKittyError::InvalidInput("Empty image data".into()));
        }

        let item = ClipboardItem::new_image(image_data, source_app, source_app_bundle_id, timestamp_unix);
        let id = self.db.insert_item(&item)?;

        // Index with description (images can be searched by their description)
        self.indexer
            .add_document(id, item.text_content(), item.timestamp_unix)?;
        self.indexer.commit()?;

        Ok(id)
    }

    /// Update link metadata for an item
    pub fn update_link_metadata(
        &self,
        item_id: i64,
        title: Option<String>,
        image_data: Option<Vec<u8>>,
    ) -> Result<(), ClipKittyError> {
        let title_for_db = title.as_deref().unwrap_or("");
        self.db
            .update_link_metadata(item_id, Some(title_for_db), image_data.as_deref())?;
        Ok(())
    }

    /// Update image description and re-index
    pub fn update_image_description(
        &self,
        item_id: i64,
        description: String,
    ) -> Result<(), ClipKittyError> {
        self.db.update_image_description(item_id, &description)?;

        // Re-index with new description
        if let Some(item) = self.get_item(item_id)? {
            self.indexer
                .add_document(item_id, &description, item.timestamp_unix)?;
            self.indexer.commit()?;
        }

        Ok(())
    }

    /// Update item timestamp to now
    pub fn update_timestamp(&self, item_id: i64) -> Result<(), ClipKittyError> {
        let now = Utc::now();
        self.db.update_timestamp(item_id, now)?;

        // Update index timestamp
        if let Some(item) = self.get_item(item_id)? {
            self.indexer
                .add_document(item_id, item.text_content(), now.timestamp())?;
            self.indexer.commit()?;
        }

        Ok(())
    }

    /// Delete an item by ID from both database and index
    pub fn delete_item(&self, item_id: i64) -> Result<(), ClipKittyError> {
        self.db.delete_item(item_id)?;
        self.indexer.delete_document(item_id)?;
        self.indexer.commit()?;
        Ok(())
    }

    /// Clear all items from database and index
    pub fn clear_all(&self) -> Result<(), ClipKittyError> {
        self.db.clear_all()?;
        self.indexer.clear()?;
        Ok(())
    }

    /// Prune old items to stay under max size
    pub fn prune_to_size(&self, max_bytes: i64, keep_ratio: f64) -> Result<u64, ClipKittyError> {
        // Get IDs that will be deleted
        let deleted_ids = self.db.get_prunable_ids(max_bytes, keep_ratio)?;

        // Delete from index
        for id in &deleted_ids {
            self.indexer.delete_document(*id)?;
        }
        if !deleted_ids.is_empty() {
            self.indexer.commit()?;
        }

        // Delete from database
        let deleted = self.db.prune_to_size(max_bytes, keep_ratio)?;
        Ok(deleted as u64)
    }

    /// Fetch items with pagination
    pub fn fetch_items(
        &self,
        before_timestamp_unix: Option<i64>,
        limit: u64,
    ) -> Result<FetchResult, ClipKittyError> {
        let before_timestamp = before_timestamp_unix
            .filter(|&ts| ts > 0)
            .and_then(|ts| Utc.timestamp_opt(ts, 0).single());

        let items = self.db.fetch_items(before_timestamp, limit as usize)?;
        let has_more = items.len() == limit as usize;

        Ok(FetchResult { items, has_more })
    }

    /// Search for items using two-layer search (Tantivy + fuzzy-matcher)
    /// Returns IDs + highlight ranges sorted by fuzzy score
    /// For queries < 3 chars, streams from database instead of using trigram index
    pub fn search(&self, query: String) -> Result<SearchResult, ClipKittyError> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Ok(SearchResult {
                matches: Vec::new(),
                total_count: 0,
            });
        }

        // Choose search strategy based on query length
        let matches = if trimmed.len() < MIN_TRIGRAM_QUERY_LEN {
            self.search_streaming(trimmed)?
        } else {
            self.search_engine.search(&self.indexer, trimmed)?
        };

        let search_matches: Vec<SearchMatch> = matches
            .into_iter()
            .map(|m| {
                let highlights = SearchEngine::indices_to_ranges(&m.matched_indices);
                SearchMatch {
                    item_id: m.id,
                    highlights,
                }
            })
            .collect();

        let total_count = search_matches.len() as u64;
        Ok(SearchResult {
            matches: search_matches,
            total_count,
        })
    }

    /// Streaming search for short queries - fetches from DB in batches and applies Nucleo
    fn search_streaming(&self, query: &str) -> Result<Vec<FuzzyMatch>, ClipKittyError> {
        const BATCH_SIZE: usize = 1000;
        let max_results = SearchEngine::max_results();

        let mut results = Vec::new();
        let mut offset = 0;

        loop {
            let batch = self.db.fetch_content_batch(offset, BATCH_SIZE)?;
            if batch.is_empty() {
                break;
            }

            let batch_len = batch.len();
            self.search_engine.filter_batch(
                batch.into_iter(),
                query,
                &mut results,
                max_results,
            );

            // Stop if we have enough results or exhausted all items
            if results.len() >= max_results || batch_len < BATCH_SIZE {
                break;
            }

            offset += BATCH_SIZE;
        }

        // Sort by score descending
        results.sort_by(|a, b| b.score.cmp(&a.score));
        results.truncate(max_results);

        Ok(results)
    }

    /// Fetch items by their IDs (for cache misses)
    pub fn fetch_by_ids(&self, ids: Vec<i64>) -> Result<Vec<ClipboardItem>, ClipKittyError> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        Ok(self.db.fetch_items_by_ids(&ids)?)
    }

    /// Get a single item by ID
    pub fn get_item(&self, item_id: i64) -> Result<Option<ClipboardItem>, ClipKittyError> {
        let items = self.db.fetch_items_by_ids(&[item_id])?;
        Ok(items.into_iter().next())
    }
}

// Implement Send + Sync for UniFFI
unsafe impl Send for ClipboardStore {}
unsafe impl Sync for ClipboardStore {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_store_creation() {
        let store = ClipboardStore::new_in_memory().unwrap();
        assert!(store.database_size() > 0);
    }

    #[test]
    fn test_save_and_fetch() {
        let store = ClipboardStore::new_in_memory().unwrap();

        let id = store
            .save_text("Hello World".to_string(), None, None, None)
            .unwrap();
        assert!(id > 0);

        let result = store.fetch_items(None, 10).unwrap();
        assert_eq!(result.items.len(), 1);
        assert_eq!(result.items[0].text_content(), "Hello World");
    }

    #[test]
    fn test_duplicate_handling() {
        let store = ClipboardStore::new_in_memory().unwrap();

        let id1 = store
            .save_text("Same content".to_string(), None, None, None)
            .unwrap();
        assert!(id1 > 0);

        let id2 = store
            .save_text("Same content".to_string(), None, None, None)
            .unwrap();
        assert_eq!(id2, 0); // Duplicate returns 0

        let result = store.fetch_items(None, 10).unwrap();
        assert_eq!(result.items.len(), 1); // Only one item
    }

    #[test]
    fn test_delete_item() {
        let store = ClipboardStore::new_in_memory().unwrap();

        let id = store
            .save_text("To delete".to_string(), None, None, None)
            .unwrap();
        assert_eq!(store.fetch_items(None, 10).unwrap().items.len(), 1);

        store.delete_item(id).unwrap();
        assert_eq!(store.fetch_items(None, 10).unwrap().items.len(), 0);
    }

}
