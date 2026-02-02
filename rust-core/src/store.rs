//! ClipboardStore - Main API for Swift interop
//! and Tantivy search functionality, designed for UniFFI export.
//!
//! Architecture: Two-layer search using Tantivy (trigram retrieval) + Nucleo (precision)

use crate::database::Database;
use crate::indexer::Indexer;
use crate::interface::{
    ClipboardItem, ItemMatch, MatchData, SearchResult, ClipKittyError, ClipboardStoreApi,
};
use crate::models::{StoredItem};
use crate::search::{SearchEngine, MIN_TRIGRAM_QUERY_LEN, MAX_RESULTS_SHORT, compute_preview_highlights};
use chrono::Utc;
use std::path::PathBuf;
use std::sync::Arc;



/// Thread-safe clipboard store with SQLite + Tantivy
///
/// Note on Concurrency:
/// The Database is wrapped in a `Mutex`, which serializes all database access (writes AND reads).
/// This ensures safety but means concurrent searches (e.g. from rapid typing) will block each other
/// during the final item fetch phase.
#[derive(uniffi::Object)]
pub struct ClipboardStore {
    db: Arc<Database>,
    indexer: Arc<Indexer>,
    search_engine: SearchEngine,
}

// Internal implementation (not exported via FFI)
impl ClipboardStore {
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
        if self.indexer.num_docs() > 0 {
            return Ok(());
        }

        let items = self.db.fetch_all_items()?;
        if items.is_empty() {
            return Ok(());
        }

        for item in items {
            if let Some(id) = item.id {
                self.indexer.add_document(id, item.text_content(), item.timestamp_unix)?;
            }
        }
        self.indexer.commit()?;

        Ok(())
    }

    /// Short query search using prefix matching + LIKE on recent items
    fn search_short_query(&self, query: &str) -> Result<Vec<ItemMatch>, ClipKittyError> {
        let candidates = self.db.search_short_query(query, MAX_RESULTS_SHORT * 5)?;

        if candidates.is_empty() {
            return Ok(Vec::new());
        }

        let query_lower = query.to_lowercase();
        let candidates_with_prefix: Vec<_> = candidates
            .into_iter()
            .map(|(id, content, timestamp)| {
                let is_prefix = content.to_lowercase().starts_with(&query_lower);
                (id, content, timestamp, is_prefix)
            })
            .collect();

        let fuzzy_matches = self.search_engine.score_short_query_batch(
            candidates_with_prefix.into_iter(),
            query,
        );

        let ids: Vec<i64> = fuzzy_matches.iter().map(|m| m.id).collect();
        let stored_items = self.db.fetch_items_by_ids(&ids)?;

        let item_map: std::collections::HashMap<i64, StoredItem> = stored_items
            .into_iter()
            .filter_map(|item| item.id.map(|id| (id, item)))
            .collect();

        let matches: Vec<ItemMatch> = fuzzy_matches
            .iter()
            .filter_map(|fm| {
                let item = item_map.get(&fm.id)?;
                Some(SearchEngine::create_item_match(item, fm))
            })
            .collect();

        Ok(matches)
    }

    /// Trigram query search using Tantivy + Nucleo
    fn search_trigram_query(&self, query: &str) -> Result<Vec<ItemMatch>, ClipKittyError> {
        let fuzzy_matches = self.search_engine.search(&self.indexer, query)?;

        if fuzzy_matches.is_empty() {
            return Ok(Vec::new());
        }

        let ids: Vec<i64> = fuzzy_matches.iter().map(|m| m.id).collect();
        let stored_items = self.db.fetch_items_by_ids(&ids)?;

        let item_map: std::collections::HashMap<i64, StoredItem> = stored_items
            .into_iter()
            .filter_map(|item| item.id.map(|id| (id, item)))
            .collect();

        let matches: Vec<ItemMatch> = fuzzy_matches
            .iter()
            .filter_map(|fm| {
                let item = item_map.get(&fm.id)?;
                Some(SearchEngine::create_item_match(item, fm))
            })
            .collect();

        Ok(matches)
    }

    /// Get a single stored item by ID (internal use)
    fn get_stored_item(&self, item_id: i64) -> Result<Option<StoredItem>, ClipKittyError> {
        let items = self.db.fetch_items_by_ids(&[item_id])?;
        Ok(items.into_iter().next())
    }

    /// Set item timestamp to a specific value (for synthetic data generation)
    #[cfg(feature = "data-gen")]
    pub fn set_timestamp(&self, item_id: i64, timestamp_unix: i64) -> Result<(), ClipKittyError> {
        let timestamp = Utc.timestamp_opt(timestamp_unix, 0).single().unwrap_or_else(Utc::now);
        self.db.update_timestamp(item_id, timestamp)?;

        if let Some(item) = self.get_stored_item(item_id)? {
            self.indexer
                .add_document(item_id, item.text_content(), timestamp_unix)?;
            self.indexer.commit()?;
        }

        Ok(())
    }
}

// FFI-exported methods
#[uniffi::export]
impl ClipboardStore {
    /// Create a new store with a database at the given path
    #[uniffi::constructor]
    pub fn new(db_path: String) -> Result<Self, ClipKittyError> {
        let db = Database::open(&db_path)?;

        // Create index directory next to database
        let db_path_buf = PathBuf::from(&db_path);
        let index_path = db_path_buf
            .parent()
            .map(|p| p.join("tantivy_index"))
            .unwrap_or_else(|| PathBuf::from("tantivy_index"));

        let indexer = Indexer::new(&index_path)?;

        let store = Self {
            db: Arc::new(db),
            indexer: Arc::new(indexer),
            search_engine: SearchEngine::new(),
        };

        store.rebuild_index_if_needed()?;

        Ok(store)
    }

    /// Get the database size in bytes
    pub fn database_size(&self) -> i64 {
        self.db.database_size().unwrap_or(0)
    }

    /// Verify FTS integrity (for backwards compat - always returns true with Tantivy)
    pub fn verify_fts_integrity(&self) -> bool {
        true
    }

    /// Save an image item to the database
    /// Generates thumbnail automatically for preview
    pub fn save_image(
        &self,
        image_data: Vec<u8>,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Result<i64, ClipKittyError> {
        if image_data.is_empty() {
            return Err(ClipKittyError::InvalidInput("Empty image data".into()));
        }

        let item = StoredItem::new_image(image_data, source_app, source_app_bundle_id);
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
        if let Some(item) = self.get_stored_item(item_id)? {
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
        if let Some(item) = self.get_stored_item(item_id)? {
            self.indexer
                .add_document(item_id, item.text_content(), now.timestamp())?;
            self.indexer.commit()?;
        }

        Ok(())
    }

    /// Prune old items to stay under max size
    pub fn prune_to_size(&self, max_bytes: i64, keep_ratio: f64) -> Result<u64, ClipKittyError> {
        let deleted_ids = self.db.get_prunable_ids(max_bytes, keep_ratio)?;

        for id in &deleted_ids {
            self.indexer.delete_document(*id)?;
        }
        if !deleted_ids.is_empty() {
            self.indexer.commit()?;
        }

        let deleted = self.db.prune_to_size(max_bytes, keep_ratio)?;
        Ok(deleted as u64)
    }
}

#[uniffi::export]
impl ClipboardStoreApi for ClipboardStore {
    /// Save a text item to the database and index
    /// Returns the new item ID, or 0 if duplicate (timestamp updated)
    /// If the text is a URL, automatically fetches link metadata in background
    fn save_text(
        &self,
        text: String,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Result<i64, ClipKittyError> {
        let item = StoredItem::new_text(text.clone(), source_app, source_app_bundle_id);
        let is_link = matches!(item.content, crate::interface::ClipboardContent::Link { .. });

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

        // If it's a link, fetch metadata in background (async)
        if is_link {
            let db = Arc::clone(&self.db);
            let url = text;
            tokio::spawn(async move {
                if let Some(metadata) = crate::link_metadata::fetch_metadata(&url).await {
                    let title = metadata.title.as_deref().unwrap_or("");
                    let _ = db.update_link_metadata(id, Some(title), metadata.image_data.as_deref());
                } else {
                    // Mark as failed (empty title, no image)
                    let _ = db.update_link_metadata(id, Some(""), None);
                }
            });
        }

        Ok(id)
    }

    /// Search for items - unified API for both browse and search modes
    /// Empty query returns recent items (browse mode), non-empty returns search results
    /// Both return ItemMatch objects for consistent UI handling
    fn search(&self, query: String) -> Result<SearchResult, ClipKittyError> {
        let trimmed = query.trim();

        // Empty query = browse mode (return recent items as ItemMatch with empty MatchData)
        if trimmed.is_empty() {
            let (items, total_count) = self.db.fetch_item_metadata(None, 1000)?;

            let matches: Vec<ItemMatch> = items
                .into_iter()
                .map(|metadata| ItemMatch {
                    item_metadata: metadata,
                    match_data: MatchData::default(),
                })
                .collect();

            Ok(SearchResult {
                matches,
                total_count,
            })
        } else {
        // Non-empty query = search mode
        let matches = if trimmed.len() < MIN_TRIGRAM_QUERY_LEN {
            self.search_short_query(trimmed)?
        } else {
            self.search_trigram_query(&query)?
        };

        let total_count = matches.len() as u64;
        Ok(SearchResult { matches, total_count })
        }
    }

    /// Fetch full items by IDs for preview pane
    /// Includes highlights computed from optional search query
    fn fetch_by_ids(
        &self,
        item_ids: Vec<i64>,
        search_query: Option<String>,
    ) -> Result<Vec<ClipboardItem>, ClipKittyError> {
         let stored_items = self.db.fetch_items_by_ids(&item_ids)?;

        let items: Vec<ClipboardItem> = stored_items
            .into_iter()
            .map(|item| {
                // Compute highlights for preview pane if search query provided
                let highlights = search_query
                    .as_ref()
                    .map(|q| compute_preview_highlights(item.text_content(), q))
                    .unwrap_or_default();

                item.to_clipboard_item(highlights)
            })
            .collect();

        Ok(items)
    }

    /// Delete an item by ID from both database and index
    fn delete_item(&self, item_id: i64) -> Result<(), ClipKittyError> {
        self.db.delete_item(item_id)?;
        self.indexer.delete_document(item_id)?;
        self.indexer.commit()?;
        Ok(())
    }

    /// Clear all items from database and index
    fn clear(&self) -> Result<(), ClipKittyError> {
        self.db.clear_all()?;
        self.indexer.clear()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::interface::ClipboardStoreApi;

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

        let result = store.search("".to_string()).unwrap();
        assert_eq!(result.matches.len(), 1);
        assert!(result.matches[0].item_metadata.preview.contains("Hello World"));
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

        let result = store.search("".to_string()).unwrap();
        assert_eq!(result.matches.len(), 1); // Only one item
    }

    #[test]
    fn test_delete_item() {
        let store = ClipboardStore::new_in_memory().unwrap();

        let id = store
            .save_text("To delete".to_string(), None, None)
            .unwrap();
        assert_eq!(store.search("".to_string()).unwrap().matches.len(), 1);

        store.delete_item(id).unwrap();
        assert_eq!(store.search("".to_string()).unwrap().matches.len(), 0);
    }

    #[test]
    fn test_search_returns_item_matches() {
        let store = ClipboardStore::new_in_memory().unwrap();

        store.save_text("Hello World from ClipKitty".to_string(), None, None).unwrap();
        store.save_text("Another test item".to_string(), None, None).unwrap();

        let result = store.search("Hello".to_string()).unwrap();

        assert_eq!(result.matches.len(), 1);
        assert!(result.matches[0].item_metadata.preview.contains("Hello"));
        assert!(!result.matches[0].match_data.highlights.is_empty());
    }

    #[test]
    fn test_fetch_by_ids_with_highlights() {
        let store = ClipboardStore::new_in_memory().unwrap();

        let id = store.save_text("Hello World".to_string(), None, None).unwrap();

        // Fetch without query
        let items = store.fetch_by_ids(vec![id], None).unwrap();
        assert_eq!(items.len(), 1);
        assert!(items[0].preview_highlights.is_empty());

        // Fetch with query
        let items = store.fetch_by_ids(vec![id], Some("World".to_string())).unwrap();
        assert_eq!(items.len(), 1);
        assert!(!items[0].preview_highlights.is_empty());
    }

    #[test]
    fn test_color_detection() {
        let store = ClipboardStore::new_in_memory().unwrap();

        let id = store.save_text("#FF5733".to_string(), None, None).unwrap();
        assert!(id > 0);

        let items = store.fetch_by_ids(vec![id], None).unwrap();
        assert_eq!(items.len(), 1);

        // Check that it's detected as a color
        if let crate::interface::ClipboardContent::Color { value } = &items[0].content {
            assert_eq!(value, "#FF5733");
        } else {
            panic!("Expected Color content");
        }

        // Check icon is a color swatch
        if let crate::interface::ItemIcon::ColorSwatch { rgba } = items[0].item_metadata.icon {
            assert_eq!(rgba, 0xFF5733FF);
        } else {
            panic!("Expected ColorSwatch icon");
        }
    }
}
