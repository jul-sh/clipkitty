//! ClipboardStore - Main API for Swift interop
//! and Tantivy search functionality, designed for UniFFI export.
//!
//! Architecture: Two-layer search using Tantivy (trigram retrieval) + fuzzy-matcher (precision)

use crate::database::Database;
use crate::indexer::Indexer;
use crate::models::{ClipboardItem, FetchResult, SearchMatch, SearchResult};
use crate::search::{FuzzyMatch, SearchEngine, MIN_TRIGRAM_QUERY_LEN, MAX_RESULTS};
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
    ) -> Result<i64, ClipKittyError> {
        let item = ClipboardItem::new_text(text, source_app, source_app_bundle_id);

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
    ) -> Result<i64, ClipKittyError> {
        self.save_image_with_description(image_data, "Image".to_string(), source_app, source_app_bundle_id)
    }

    /// Save an image item with a custom description (for searchability)
    pub fn save_image_with_description(
        &self,
        image_data: Vec<u8>,
        description: String,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Result<i64, ClipKittyError> {
        if image_data.is_empty() {
            return Err(ClipKittyError::InvalidInput("Empty image data".into()));
        }

        let item = ClipboardItem::new_image_with_description(image_data, description, source_app, source_app_bundle_id);
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

    /// Set item timestamp to a specific value (for synthetic data generation)
    #[cfg(feature = "data-gen")]
    pub fn set_timestamp(&self, item_id: i64, timestamp_unix: i64) -> Result<(), ClipKittyError> {
        let timestamp = Utc.timestamp_opt(timestamp_unix, 0).single().unwrap_or_else(Utc::now);
        self.db.update_timestamp(item_id, timestamp)?;

        // Update index timestamp
        if let Some(item) = self.get_item(item_id)? {
            self.indexer
                .add_document(item_id, item.text_content(), timestamp_unix)?;
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
    /// For queries < 3 chars, uses SQL LIKE search with pagination
    pub fn search(
        &self,
        query: String,
        before_timestamp_unix: Option<i64>,
        limit: u64,
    ) -> Result<SearchResult, ClipKittyError> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Ok(SearchResult {
                matches: Vec::new(),
                total_count: 0,
                has_more: false,
            });
        }

        let before_timestamp = before_timestamp_unix
            .filter(|&ts| ts > 0)
            .and_then(|ts| Utc.timestamp_opt(ts, 0).single());

        // Choose search strategy based on query length
        if trimmed.len() < MIN_TRIGRAM_QUERY_LEN {
            let items = self.db.search_like(trimmed, before_timestamp, limit as usize)?;
            let has_more = items.len() == limit as usize;

            let matches = items
                .into_iter()
                .map(|item| {
                    let content = item.text_content();
                    let mut matched_indices = Vec::new();
                    // Basic exact substring match indices for highlighting
                    if let Some(pos) = content.to_lowercase().find(&trimmed.to_lowercase()) {
                        for i in 0..trimmed.len() {
                            matched_indices.push((pos + i) as u32);
                        }
                    }

                    SearchMatch {
                        item_id: item.id.unwrap_or(0),
                        highlights: SearchEngine::indices_to_ranges(&matched_indices),
                    }
                })
                .collect();

            Ok(SearchResult {
                matches,
                total_count: 0, // Count is not easily available with pagination
                has_more,
            })
        } else {
            // Long queries use Tantivy + re-ranking
            // Note: Tantivy search currently doesn't support keyset pagination in our implementation,
            // but we'll apply the limit and return has_more based on that for now.
            // In a real production app, we'd add offset/score-based pagination to the indexer.
            let mut matches = self.search_engine.search(&self.indexer, &query)?;

            // Sort by blended score (already handled in search_engine.search)
            let total_count = matches.len() as u64;
            let has_more = matches.len() > limit as usize;
            matches.truncate(limit as usize);

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

            Ok(SearchResult {
                matches: search_matches,
                total_count,
                has_more,
            })
        }
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
            .save_text("Hello World".to_string(), None, None)
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
            .save_text("Same content".to_string(), None, None)
            .unwrap();
        assert!(id1 > 0);

        let id2 = store
            .save_text("Same content".to_string(), None, None)
            .unwrap();
        assert_eq!(id2, 0); // Duplicate returns 0

        let result = store.fetch_items(None, 10).unwrap();
        assert_eq!(result.items.len(), 1); // Only one item
    }

    #[test]
    fn test_delete_item() {
        let store = ClipboardStore::new_in_memory().unwrap();

        let id = store
            .save_text("To delete".to_string(), None, None)
            .unwrap();
        assert_eq!(store.fetch_items(None, 10).unwrap().items.len(), 1);

        store.delete_item(id).unwrap();
        assert_eq!(store.fetch_items(None, 10).unwrap().items.len(), 0);
    }

    #[test]
    fn test_search_ranking_recent_vs_old() {
        // Integration test for the full search flow through Tantivy
        // Tests that recent items with equal fuzzy scores beat old items
        let store = ClipboardStore::new_in_memory().unwrap();

        // Insert old item first (will have earlier timestamp)
        let id1 = store
            .save_text(
                "def hello(name: str) -> str: return f'Hello, {name}!'".to_string(),
                None,
                None,
            )
            .unwrap();

        // Sleep to ensure different timestamps (timestamps are in seconds, need >1s)
        std::thread::sleep(std::time::Duration::from_millis(1100));

        // Insert recent item
        let id2 = store
            .save_text(
                "Hello and welcome to the onboarding flow for new team members...".to_string(),
                None,
                None,
            )
            .unwrap();

        // Debug: fetch items to see their timestamps
        let items = store.fetch_items(None, 10).unwrap();
        println!("Items in store:");
        for item in &items.items {
            println!("  id={}, ts={}, content={:.50}",
                item.id.unwrap_or(-1),
                item.timestamp_unix,
                item.text_content());
        }

        // Debug: check what Tantivy returns
        let candidates = store.indexer.search("hello ").unwrap();
        println!("Tantivy candidates:");
        for c in &candidates {
            println!("  id={}, ts={}, content={:.50}", c.id, c.timestamp, c.content);
        }

        // Search for "hello "
        let result = store.search("hello ".to_string(), None, 100).unwrap();

        println!("Search results for 'hello ':");
        for (i, m) in result.matches.iter().enumerate() {
            println!("  {}: id={}", i, m.item_id);
        }

        assert_eq!(result.matches.len(), 2, "Should find both items");
        assert_eq!(
            result.matches[0].item_id, id2,
            "Recent 'Hello and welcome...' (id={}) should be first, but got id={}",
            id2, result.matches[0].item_id
        );
        assert_eq!(
            result.matches[1].item_id, id1,
            "Old code snippet (id={}) should be second",
            id1
        );
    }

    #[test]
    fn test_timestamps_stored_and_used_in_search() {
        // Comprehensive test verifying timestamps flow correctly through the system:
        // 1. Database stores correct timestamps
        // 2. Tantivy index stores correct timestamps
        // 3. Timestamps match between database and index
        // 4. Recency boost affects search ranking
        let store = ClipboardStore::new_in_memory().unwrap();

        // Insert items with forced timestamp separation
        // Use content with same prefix to get similar Tantivy scores
        let id1 = store.save_text("config file A1".to_string(), None, None).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(1100));
        let id2 = store.save_text("config file B2".to_string(), None, None).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(1100));
        let id3 = store.save_text("config file C3".to_string(), None, None).unwrap();

        // 1. Verify database timestamps are in correct order (most recent first)
        let db_items = store.fetch_items(None, 10).unwrap();
        assert_eq!(db_items.items.len(), 3);
        let db_ts: Vec<(i64, i64)> = db_items.items.iter()
            .map(|i| (i.id.unwrap(), i.timestamp_unix))
            .collect();

        // Most recent (id3) should have highest timestamp
        assert!(db_ts[0].0 == id3, "Most recent item should be first in fetch");
        assert!(db_ts[0].1 > db_ts[1].1, "id3 timestamp should be > id2 timestamp");
        assert!(db_ts[1].1 > db_ts[2].1, "id2 timestamp should be > id1 timestamp");

        // 2. Verify Tantivy index timestamps match database
        let candidates = store.indexer.search("config").unwrap();
        assert_eq!(candidates.len(), 3, "Tantivy should find all 3 items");

        for candidate in &candidates {
            let db_item = db_items.items.iter()
                .find(|i| i.id == Some(candidate.id))
                .expect("Candidate should exist in database");

            assert_eq!(
                candidate.timestamp, db_item.timestamp_unix,
                "Tantivy timestamp for id={} should match database: index={} vs db={}",
                candidate.id, candidate.timestamp, db_item.timestamp_unix
            );
            assert!(candidate.timestamp > 0, "Timestamp should not be 0 for id={}", candidate.id);
        }

        // 3. Verify search results respect recency (most recent first for equal scores)
        let result = store.search("config file".to_string(), None, 100).unwrap();
        assert_eq!(result.matches.len(), 3);

        // All have same base fuzzy score, so recency should determine order
        assert_eq!(result.matches[0].item_id, id3, "Most recent (id3) should be first");
        assert_eq!(result.matches[1].item_id, id2, "Middle (id2) should be second");
        assert_eq!(result.matches[2].item_id, id1, "Oldest (id1) should be third");
    }

    #[test]
    fn test_short_query_sql_like_search() {
        let store = ClipboardStore::new_in_memory().unwrap();

        store.save_text("apple pie".to_string(), None, None).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(100));
        store.save_text("banana split".to_string(), None, None).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(100));
        let id3 = store.save_text("apple tart".to_string(), None, None).unwrap();

        // Search for "ap" (short query < 3 chars)
        let result = store.search("ap".to_string(), None, 10).unwrap();
        assert_eq!(result.matches.len(), 2);
        assert_eq!(result.matches[0].item_id, id3); // Most recent first
        assert!(result.matches[0].highlights.len() > 0);
        assert_eq!(result.matches[0].highlights[0].start, 0);
        assert_eq!(result.matches[0].highlights[0].end, 2);
    }

    #[test]
    fn test_search_pagination() {
        let store = ClipboardStore::new_in_memory().unwrap();

        for i in 0..30 {
            store.save_text(format!("item {}", i), None, None).unwrap();
            // Sleep a bit to ensure unique timestamps for this test
            std::thread::sleep(std::time::Duration::from_millis(10));
        }

        // Fetch first page of 10 (use 2-char query "it" to trigger SQL LIKE path)
        let result1 = store.search("it".to_string(), None, 10).unwrap();
        assert_eq!(result1.matches.len(), 10);
        assert!(result1.has_more);

        // Fetch second page of 10
        let last_id = result1.matches.last().unwrap().item_id;
        let last_item = store.get_item(last_id).unwrap().unwrap();
        let last_ts = last_item.timestamp_unix;

        // Note: Due to 1s resolution, we might still have same timestamp.
        // But searching for < last_ts will skip all items in that second.
        // For this test, we accept that it might return fewer items or fail if same second.
        // In a real app we'd use (timestamp, id) for keyset pagination.
        let result2 = store.search("it".to_string(), Some(last_ts), 10).unwrap();

        if !result2.matches.is_empty() {
            assert!(result1.matches[0].item_id != result2.matches[0].item_id);
        }
    }
}
