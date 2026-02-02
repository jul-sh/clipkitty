//! ClipboardStore - Main API for Swift interop
//! and Tantivy search functionality, designed for UniFFI export.
//!
//! Architecture: Two-layer search using Tantivy (trigram retrieval) + Nucleo (precision)
//!
//! Async Cancellation Architecture:
//! When Swift cancels an async Task, UniFFI drops the Rust Future. We intercept this
//! via a DropGuard that triggers a CancellationToken. The blocking search thread
//! checks this token at key checkpoints and can abort mid-flight.

use crate::database::Database;
use crate::indexer::Indexer;
use crate::interface::{
    ClipboardItem, ItemMatch, MatchData, SearchResult, ClipKittyError, ClipboardStoreApi,
};
use crate::models::StoredItem;
use crate::search::{SearchEngine, MIN_TRIGRAM_QUERY_LEN, MAX_RESULTS_SHORT, compute_preview_highlights};
use chrono::Utc;
use std::path::PathBuf;
use std::sync::Arc;
use tokio_util::sync::CancellationToken;

/// RAII guard that cancels a token when dropped.
/// When Swift cancels an async Task, UniFFI drops the Future, which drops this guard,
/// which triggers the cancellation token.
struct DropGuard {
    token: CancellationToken,
}

impl DropGuard {
    fn new(token: CancellationToken) -> Self {
        Self { token }
    }
}

impl Drop for DropGuard {
    fn drop(&mut self) {
        self.token.cancel();
    }
}

/// Thread-safe clipboard store with SQLite + Tantivy
///
/// Concurrency Model:
/// - Database uses r2d2 connection pool (concurrent reads, no mutex blocking)
/// - Search is async with cancellation support via CancellationToken
/// - Blocking work runs on tokio::spawn_blocking threads
#[derive(uniffi::Object)]
pub struct ClipboardStore {
    db: Arc<Database>,
    indexer: Arc<Indexer>,
    search_engine: Arc<SearchEngine>,
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
            search_engine: Arc::new(SearchEngine::new()),
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
    fn search_short_query_sync(
        db: &Database,
        search_engine: &SearchEngine,
        query: &str,
        token: &CancellationToken,
        runtime: &tokio::runtime::Handle,
    ) -> Result<Vec<ItemMatch>, ClipKittyError> {
        // Checkpoint: Check cancellation before DB query
        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let candidates = db.search_short_query(query, MAX_RESULTS_SHORT * 5)?;

        if candidates.is_empty() {
            return Ok(Vec::new());
        }

        // Checkpoint: Check cancellation before scoring
        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let query_lower = query.to_lowercase();
        let candidates_with_prefix: Vec<_> = candidates
            .into_iter()
            .map(|(id, content, timestamp)| {
                let is_prefix = content.to_lowercase().starts_with(&query_lower);
                (id, content, timestamp, is_prefix)
            })
            .collect();

        let fuzzy_matches = search_engine.score_short_query_batch(
            candidates_with_prefix.into_iter(),
            query,
        );

        // Checkpoint: Check cancellation before fetching items
        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        // Use interruptible fetch with SQLite C-level interrupt support
        let ids: Vec<i64> = fuzzy_matches.iter().map(|m| m.id).collect();
        let stored_items = db.fetch_items_by_ids_interruptible(&ids, token, runtime)?;

        // Check if we were interrupted (empty result with non-empty IDs)
        if stored_items.is_empty() && !ids.is_empty() && token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let item_map: std::collections::HashMap<i64, StoredItem> = stored_items
            .into_iter()
            .filter_map(|item| item.id.map(|id| (id, item)))
            .collect();

        // Checkpoint: Check cancellation before highlight generation
        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        // Generate matches with chunked cancellation checks
        let mut matches: Vec<ItemMatch> = Vec::with_capacity(fuzzy_matches.len());
        for (index, fm) in fuzzy_matches.iter().enumerate() {
            // Check every 100 iterations for cancellation (preserve CPU cache performance)
            if index % 100 == 0 && token.is_cancelled() {
                return Err(ClipKittyError::Cancelled);
            }

            if let Some(item) = item_map.get(&fm.id) {
                matches.push(SearchEngine::create_item_match(item, fm));
            }
        }

        Ok(matches)
    }

    /// Trigram query search using Tantivy + Nucleo
    fn search_trigram_query_sync(
        db: &Database,
        indexer: &Indexer,
        search_engine: &SearchEngine,
        query: &str,
        token: &CancellationToken,
        runtime: &tokio::runtime::Handle,
    ) -> Result<Vec<ItemMatch>, ClipKittyError> {
        // Checkpoint: Check cancellation before Tantivy search
        // Note: We don't inject checks into Tantivy's internal SIMD loops
        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let fuzzy_matches = search_engine.search(indexer, query)?;

        if fuzzy_matches.is_empty() {
            return Ok(Vec::new());
        }

        // Checkpoint: Check cancellation before SQLite fetch
        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        // Use interruptible fetch with SQLite C-level interrupt support
        let ids: Vec<i64> = fuzzy_matches.iter().map(|m| m.id).collect();
        let stored_items = db.fetch_items_by_ids_interruptible(&ids, token, runtime)?;

        // Check if we were interrupted (empty result with non-empty IDs)
        if stored_items.is_empty() && !ids.is_empty() && token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let item_map: std::collections::HashMap<i64, StoredItem> = stored_items
            .into_iter()
            .filter_map(|item| item.id.map(|id| (id, item)))
            .collect();

        // Checkpoint: Check cancellation before highlight generation
        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        // Generate matches with chunked cancellation checks
        let mut matches: Vec<ItemMatch> = Vec::with_capacity(fuzzy_matches.len());
        for (index, fm) in fuzzy_matches.iter().enumerate() {
            // Check every 100 iterations for cancellation (preserve CPU cache performance)
            if index % 100 == 0 && token.is_cancelled() {
                return Err(ClipKittyError::Cancelled);
            }

            if let Some(item) = item_map.get(&fm.id) {
                matches.push(SearchEngine::create_item_match(item, fm));
            }
        }

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
            search_engine: Arc::new(SearchEngine::new()),
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
#[async_trait::async_trait]
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
    ///
    /// This is an async function that supports cancellation. When Swift drops the Task,
    /// the DropGuard triggers the CancellationToken, allowing mid-flight abortion.
    async fn search(&self, query: String) -> Result<SearchResult, ClipKittyError> {
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

            return Ok(SearchResult {
                matches,
                total_count,
            });
        }

        // Create cancellation token and guard
        let token = CancellationToken::new();
        let _guard = DropGuard::new(token.clone());

        // Get runtime handle for SQLite interrupt watcher spawning inside spawn_blocking
        let runtime = tokio::runtime::Handle::current();

        // Clone Arcs for the blocking closure
        let db = Arc::clone(&self.db);
        let indexer = Arc::clone(&self.indexer);
        let search_engine = Arc::clone(&self.search_engine);
        let query_owned = query.to_string();
        let trimmed_owned = trimmed.to_string();
        let token_clone = token.clone();

        // Spawn the blocking search work
        let handle = tokio::task::spawn_blocking(move || {
            if trimmed_owned.len() < MIN_TRIGRAM_QUERY_LEN {
                Self::search_short_query_sync(&db, &search_engine, &trimmed_owned, &token_clone, &runtime)
            } else {
                Self::search_trigram_query_sync(&db, &indexer, &search_engine, &query_owned, &token_clone, &runtime)
            }
        });

        // Await the result
        match handle.await {
            Ok(Ok(matches)) => {
                let total_count = matches.len() as u64;
                Ok(SearchResult { matches, total_count })
            }
            Ok(Err(e)) => Err(e),
            Err(_join_error) => {
                // JoinError means the task panicked or was aborted
                Err(ClipKittyError::Cancelled)
            }
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

    fn runtime() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
    }

    #[test]
    fn test_store_creation() {
        let store = ClipboardStore::new_in_memory().unwrap();
        assert!(store.database_size() > 0);
    }

    #[test]
    fn test_save_and_fetch() {
        let rt = runtime();
        let store = ClipboardStore::new_in_memory().unwrap();

        let id = store
            .save_text("Hello World".to_string(), None, None)
            .unwrap();
        assert!(id > 0);

        let result = rt.block_on(store.search("".to_string())).unwrap();
        assert_eq!(result.matches.len(), 1);
        assert!(result.matches[0].item_metadata.preview.contains("Hello World"));
    }

    #[test]
    fn test_duplicate_handling() {
        let rt = runtime();
        let store = ClipboardStore::new_in_memory().unwrap();

        let id1 = store
            .save_text("Same content".to_string(), None, None)
            .unwrap();
        assert!(id1 > 0);

        let id2 = store
            .save_text("Same content".to_string(), None, None)
            .unwrap();
        assert_eq!(id2, 0); // Duplicate returns 0

        let result = rt.block_on(store.search("".to_string())).unwrap();
        assert_eq!(result.matches.len(), 1); // Only one item
    }

    #[test]
    fn test_delete_item() {
        let rt = runtime();
        let store = ClipboardStore::new_in_memory().unwrap();

        let id = store
            .save_text("To delete".to_string(), None, None)
            .unwrap();
        assert_eq!(rt.block_on(store.search("".to_string())).unwrap().matches.len(), 1);

        store.delete_item(id).unwrap();
        assert_eq!(rt.block_on(store.search("".to_string())).unwrap().matches.len(), 0);
    }

    #[test]
    fn test_search_returns_item_matches() {
        let rt = runtime();
        let store = ClipboardStore::new_in_memory().unwrap();

        store.save_text("Hello World from ClipKitty".to_string(), None, None).unwrap();
        store.save_text("Another test item".to_string(), None, None).unwrap();

        let result = rt.block_on(store.search("Hello".to_string())).unwrap();

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

    #[test]
    fn test_cancellation_token() {
        // Test that cancellation token works correctly
        let token = CancellationToken::new();
        assert!(!token.is_cancelled());

        let guard = DropGuard::new(token.clone());
        assert!(!token.is_cancelled());

        drop(guard);
        assert!(token.is_cancelled());
    }
}
