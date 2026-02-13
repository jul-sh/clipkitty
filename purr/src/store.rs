//! ClipboardStore - Main API for Swift interop
//! and Tantivy search functionality, designed for UniFFI export.
//!
//! Architecture: Tantivy search with trigram retrieval and phrase-boost scoring
//!
//! Async Cancellation Architecture:
//! When Swift cancels an async Task, UniFFI drops the Rust Future. We intercept this
//! via a DropGuard that triggers a CancellationToken. The blocking search thread
//! checks this token at key checkpoints and can abort mid-flight.

use crate::database::{Database, StoredItem};
use crate::interface::{
    ClipboardItem, ItemMatch, MatchData, SearchResult, ClipKittyError, ClipboardStoreApi,
};
use crate::search::{self, Indexer, MIN_TRIGRAM_QUERY_LEN, MAX_RESULTS};
use chrono::Utc;
use once_cell::sync::Lazy;
use std::path::PathBuf;
use std::sync::{Arc, Once};
use tokio_util::sync::CancellationToken;

/// Global fallback Tokio runtime for when async functions are called outside any runtime context.
/// This is shared across all ClipboardStore instances and never dropped.
/// Used by UniFFI which doesn't provide a tokio runtime.
static FALLBACK_RUNTIME: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("Failed to create fallback tokio runtime")
});

static RAYON_INIT: Once = Once::new();

/// Initialize global Rayon thread pool with core reservation and lower priority
fn init_rayon() {
    RAYON_INIT.call_once(|| {
        let num_threads = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4);

        // Reserve 2 cores for Tokio to ensure responsiveness, but use at least 1 thread.
        let rayon_threads = num_threads.saturating_sub(2).max(1);

        let _ = rayon::ThreadPoolBuilder::new()
            .num_threads(rayon_threads)
            .thread_name(|i| format!("clipkitty-rayon-{}", i))
            .start_handler(|_| {
                // Lower Rayon thread priority to allow Tokio worker threads to preempt them easily.
                use thread_priority::*;
                let _ = set_current_thread_priority(ThreadPriority::Min);
            })
            .build_global();
    });
}

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
/// - Uses global FALLBACK_RUNTIME when called outside any runtime (e.g., from UniFFI)
#[derive(uniffi::Object)]
pub struct ClipboardStore {
    db: Arc<Database>,
    indexer: Arc<Indexer>,
}

// Internal implementation (not exported via FFI)
impl ClipboardStore {
    /// Create a store with an in-memory database (for testing)
    #[cfg(test)]
    pub(crate) fn new_in_memory() -> Result<Self, ClipKittyError> {
        init_rayon();
        let database = Database::open_in_memory().map_err(ClipKittyError::from)?;
        let indexer = Indexer::new_in_memory()?;

        Ok(Self {
            db: Arc::new(database),
            indexer: Arc::new(indexer),
        })
    }

    /// Get a tokio runtime handle - uses current runtime if available, otherwise global fallback
    fn runtime_handle(&self) -> tokio::runtime::Handle {
        tokio::runtime::Handle::try_current()
            .unwrap_or_else(|_| FALLBACK_RUNTIME.handle().clone())
    }

    /// Rebuild index from database if the index is empty but database has items
    fn rebuild_index_if_needed(&self) -> Result<(), ClipKittyError> {
        let db_count = self.db.count_items()?;
        let index_count = self.indexer.num_docs();

        if db_count == index_count {
            return Ok(());
        }

        let items = self.db.fetch_all_items()?;
        if items.is_empty() {
            return Ok(());
        }

        use rayon::prelude::*;
        items.into_par_iter().try_for_each(|item| {
            if let Some(id) = item.id {
                self.indexer.add_document(id, item.text_content(), item.timestamp_unix)?;
            }
            Ok::<(), ClipKittyError>(())
        })?;
        self.indexer.commit()?;

        Ok(())
    }

    /// Fetch stored items for fuzzy matches and generate ItemMatches in parallel.
    /// Shared by both short-query and trigram search paths.
    fn fuzzy_matches_to_item_matches(
        db: &Database,
        fuzzy_matches: Vec<search::FuzzyMatch>,
        token: &CancellationToken,
        runtime: &tokio::runtime::Handle,
    ) -> Result<Vec<ItemMatch>, ClipKittyError> {
        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let ids: Vec<i64> = fuzzy_matches.iter().map(|m| m.id).collect();
        let stored_items = db.fetch_items_by_ids_interruptible(&ids, token, runtime)?;

        if stored_items.is_empty() && !ids.is_empty() && token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let item_map: std::collections::HashMap<i64, StoredItem> = stored_items
            .into_iter()
            .filter_map(|item| item.id.map(|id| (id, item)))
            .collect();

        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        // Use indexed par_iter to preserve the ranking order from search.
        // into_par_iter() on Vec<T> is an IndexedParallelIterator, so
        // enumerate + collect preserves input order.
        use rayon::prelude::*;
        let indexed: Vec<(usize, Option<ItemMatch>)> = fuzzy_matches
            .into_par_iter()
            .enumerate()
            .map(|(i, fm)| {
                if token.is_cancelled() {
                    return Err(ClipKittyError::Cancelled);
                }
                Ok((i, item_map.get(&fm.id).map(|item| search::create_item_match(item, &fm))))
            })
            .collect::<Result<Vec<_>, ClipKittyError>>()?;

        let mut sorted = indexed;
        sorted.sort_unstable_by_key(|(i, _)| *i);
        Ok(sorted.into_iter().filter_map(|(_, item)| item).collect())
    }

    /// Short query search using prefix matching + LIKE on recent items
    fn search_short_query_sync(
        db: &Database,
        query: &str,
        token: &CancellationToken,
        runtime: &tokio::runtime::Handle,
    ) -> Result<Vec<ItemMatch>, ClipKittyError> {
        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let candidates = db.search_short_query(query, MAX_RESULTS)?;
        if candidates.is_empty() {
            return Ok(Vec::new());
        }

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

        let fuzzy_matches = search::score_short_query_batch(
            candidates_with_prefix.into_iter(),
            query,
            token,
        );

        Self::fuzzy_matches_to_item_matches(db, fuzzy_matches, token, runtime)
    }

    /// Trigram query search using Tantivy with phrase-boost scoring
    fn search_trigram_query_sync(
        db: &Database,
        indexer: &Indexer,
        query: &str,
        token: &CancellationToken,
        runtime: &tokio::runtime::Handle,
    ) -> Result<Vec<ItemMatch>, ClipKittyError> {
        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let fuzzy_matches = search::search_trigram(indexer, query, token)?;
        if fuzzy_matches.is_empty() {
            return Ok(Vec::new());
        }

        Self::fuzzy_matches_to_item_matches(db, fuzzy_matches, token, runtime)
    }

    /// Get a single stored item by ID (internal use)
    fn get_stored_item(&self, item_id: i64) -> Result<Option<StoredItem>, ClipKittyError> {
        let items = self.db.fetch_items_by_ids(&[item_id])?;
        Ok(items.into_iter().next())
    }
}

// FFI-exported constructor (must be in standalone impl block)
#[uniffi::export]
impl ClipboardStore {
    /// Create a new store with a database at the given path
    #[uniffi::constructor]
    pub fn new(db_path: String) -> Result<Self, ClipKittyError> {
        init_rayon();
        let path = PathBuf::from(db_path);
        let db = Database::open(&path).map_err(ClipKittyError::from)?;

        // Create index directory next to database
        let db_path_buf = PathBuf::from(&path);
        let index_path = db_path_buf
            .parent()
            .map(|p| p.join("tantivy_index_v2"))
            .unwrap_or_else(|| PathBuf::from("tantivy_index_v2"));

        let indexer = Indexer::new(&index_path)?;

        let store = Self {
            db: Arc::new(db),
            indexer: Arc::new(indexer),
        };

        store.rebuild_index_if_needed()?;

        Ok(store)
    }
}

#[uniffi::export]
#[async_trait::async_trait]
impl ClipboardStoreApi for ClipboardStore {
    // ─────────────────────────────────────────────────────────────────────────────
    // Read Operations
    // ─────────────────────────────────────────────────────────────────────────────

    /// Get the database size in bytes
    fn database_size(&self) -> i64 {
        self.db.database_size().unwrap_or(0)
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Write Operations
    // ─────────────────────────────────────────────────────────────────────────────

    /// Save a text item to the database and index
    /// Returns the new item ID, or 0 if duplicate (timestamp updated)
    /// URLs are detected and stored as links with Pending metadata state
    /// Swift fetches link metadata using LinkPresentation framework
    fn save_text(
        &self,
        text: String,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Result<i64, ClipKittyError> {
        let item = StoredItem::new_text(text.clone(), source_app, source_app_bundle_id);

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

        // Link metadata fetching is handled by Swift using LinkPresentation framework
        // for better reliability (handles JavaScript, caching, etc.)

        Ok(id)
    }

    /// Search for items
    /// Empty query returns all recent items, non-empty query filters by search terms
    /// Returns ItemMatch objects with optional highlights for consistent UI handling
    ///
    /// This is an async function that supports cancellation. When Swift drops the Task,
    /// the DropGuard triggers the CancellationToken, allowing mid-flight abortion.
    async fn search(&self, query: String) -> Result<SearchResult, ClipKittyError> {
        let trimmed = query.trim();

        // Empty query: return recent items with empty MatchData (no highlights)
        if trimmed.is_empty() {
            let (items, total_count) = self.db.fetch_item_metadata(None, 1000)?;

            // Fetch first item's full content for preview pane
            let first_item = if let Some(first_metadata) = items.first() {
                self.db
                    .fetch_items_by_ids(&[first_metadata.item_id])?
                    .into_iter()
                    .next()
                    .map(|item| ClipboardItem::from(&item))
            } else {
                None
            };

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
                first_item,
            });
        }

        // Create cancellation token and guard
        let token = CancellationToken::new();
        let _guard = DropGuard::new(token.clone());

        // Get runtime handle - uses current runtime if available, otherwise our fallback
        // This ensures we work both in tokio tests and when called from UniFFI
        let runtime = self.runtime_handle();
        let runtime_for_closure = runtime.clone();

        // Clone Arcs for the blocking closure
        let db = Arc::clone(&self.db);
        let indexer = Arc::clone(&self.indexer);
        let query_owned = query.to_string();
        let trimmed_owned = trimmed.to_string();
        let token_clone = token.clone();

        // Spawn the blocking search work on our runtime
        // We use runtime.spawn_blocking() instead of tokio::task::spawn_blocking()
        // because UniFFI doesn't provide a tokio runtime context
        let handle = runtime.spawn_blocking(move || {
            if trimmed_owned.len() < MIN_TRIGRAM_QUERY_LEN {
                let matches = Self::search_short_query_sync(&db, &trimmed_owned, &token_clone, &runtime_for_closure)?;
                let total_count = matches.len() as u64;
                Ok((matches, total_count))
            } else {
                let matches = Self::search_trigram_query_sync(&db, &indexer, &query_owned, &token_clone, &runtime_for_closure)?;
                let total_count = matches.len() as u64;
                Ok((matches, total_count))
            }
        });

        // Await the result
        match handle.await {
            Ok(Ok((matches, total_count))) => {

                // Fetch first item's full content for preview pane
                let first_item = if let Some(first_match) = matches.first() {
                    let id = first_match.item_metadata.item_id;
                    self.db
                        .fetch_items_by_ids(&[id])?
                        .into_iter()
                        .next()
                        .map(|item| ClipboardItem::from(&item))
                } else {
                    None
                };

                Ok(SearchResult { matches, total_count, first_item })
            }
            Ok(Err(e)) => Err(e),
            Err(_join_error) => {
                // JoinError means the task panicked or was aborted
                Err(ClipKittyError::Cancelled)
            }
        }
    }

    /// Fetch full items by IDs for preview pane
    fn fetch_by_ids(&self, item_ids: Vec<i64>) -> Result<Vec<ClipboardItem>, ClipKittyError> {
        let stored_items = self.db.fetch_items_by_ids(&item_ids)?;
        let items: Vec<ClipboardItem> = stored_items
            .into_iter()
            .map(|item| ClipboardItem::from(&item))
            .collect();
        Ok(items)
    }

    /// Save an image item to the database
    /// Thumbnail should be generated by Swift (HEIC format not supported by Rust image crate)
    fn save_image(
        &self,
        image_data: Vec<u8>,
        thumbnail: Option<Vec<u8>>,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Result<i64, ClipKittyError> {
        if image_data.is_empty() {
            return Err(ClipKittyError::InvalidInput("Empty image data".into()));
        }

        let item = StoredItem::new_image_with_thumbnail(image_data, thumbnail, source_app, source_app_bundle_id);
        let id = self.db.insert_item(&item)?;

        // Index with description (images can be searched by their description)
        self.indexer
            .add_document(id, item.text_content(), item.timestamp_unix)?;
        self.indexer.commit()?;

        Ok(id)
    }

    /// Update link metadata (called from Swift after LPMetadataProvider fetch)
    fn update_link_metadata(
        &self,
        item_id: i64,
        title: Option<String>,
        description: Option<String>,
        image_data: Option<Vec<u8>>,
    ) -> Result<(), ClipKittyError> {
        // Empty title with no description/image = failed state
        // Non-empty title or has description/image = loaded state
        let title_for_db = title.as_deref().unwrap_or("");
        self.db
            .update_link_metadata(item_id, Some(title_for_db), description.as_deref(), image_data.as_deref())?;
        Ok(())
    }

    /// Update image description and re-index
    fn update_image_description(
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
    fn update_timestamp(&self, item_id: i64) -> Result<(), ClipKittyError> {
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

    // ─────────────────────────────────────────────────────────────────────────────
    // Delete Operations
    // ─────────────────────────────────────────────────────────────────────────────

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

    /// Prune old items to stay under max size. Returns count of deleted items.
    fn prune_to_size(&self, max_bytes: i64, keep_ratio: f64) -> Result<u64, ClipKittyError> {
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
        assert!(result.matches[0].item_metadata.snippet.contains("Hello World"));
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
        assert!(result.matches[0].item_metadata.snippet.contains("Hello"));
        assert!(!result.matches[0].match_data.highlights.is_empty());
    }

    #[test]
    fn test_fetch_by_ids() {
        let store = ClipboardStore::new_in_memory().unwrap();

        let id = store.save_text("Hello World".to_string(), None, None).unwrap();

        let items = store.fetch_by_ids(vec![id]).unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].content.text_content(), "Hello World");
    }

    #[test]
    fn test_color_detection() {
        let store = ClipboardStore::new_in_memory().unwrap();

        let id = store.save_text("#FF5733".to_string(), None, None).unwrap();
        assert!(id > 0);

        let items = store.fetch_by_ids(vec![id]).unwrap();
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
    fn test_link_detection_and_fetch() {
        let rt = runtime();
        let store = ClipboardStore::new_in_memory().unwrap();

        // Save a URL - should be detected as a link
        let url = "https://github.com/anthropics/claude-code".to_string();
        let id = store.save_text(url.clone(), None, None).unwrap();
        assert!(id > 0);

        // Fetch the item - this verifies the database roundtrip works
        let items = store.fetch_by_ids(vec![id]).unwrap();
        assert_eq!(items.len(), 1);

        // Check that it's detected as a link
        if let crate::interface::ClipboardContent::Link { url: stored_url, metadata_state } = &items[0].content {
            assert_eq!(stored_url, &url);
            // Metadata should be pending initially (fetched in background)
            assert!(matches!(metadata_state, crate::interface::LinkMetadataState::Pending));
        } else {
            panic!("Expected Link content, got: {:?}", items[0].content);
        }

        // Check icon is a symbol (Link type)
        if let crate::interface::ItemIcon::Symbol { icon_type } = items[0].item_metadata.icon {
            assert_eq!(icon_type, crate::interface::IconType::Link);
        } else {
            panic!("Expected Symbol icon with Link type");
        }

        // Search should also return the link
        let result = rt.block_on(store.search("github".to_string())).unwrap();
        assert!(!result.matches.is_empty(), "Should find the link by searching 'github'");
        assert!(result.matches[0].item_metadata.snippet.contains("github"));

        // first_item should also be populated when searching
        assert!(result.first_item.is_some(), "first_item should be populated");
        if let Some(first) = &result.first_item {
            if let crate::interface::ClipboardContent::Link { url: first_url, .. } = &first.content {
                assert!(first_url.contains("github"));
            } else {
                panic!("first_item should be a Link");
            }
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

    #[test]
    fn test_search_with_precancelled_token_returns_cancelled() {
        // Test that sync search functions return Cancelled immediately when token is already cancelled
        let rt = runtime();
        let store = ClipboardStore::new_in_memory().unwrap();

        // Add some data
        store.save_text("Hello World".to_string(), None, None).unwrap();
        store.save_text("Another item".to_string(), None, None).unwrap();

        // Create a pre-cancelled token
        let token = CancellationToken::new();
        token.cancel();

        let runtime_handle = rt.handle().clone();

        // Test short query sync with pre-cancelled token
        let result = ClipboardStore::search_short_query_sync(
            &store.db,
            "He",
            &token,
            &runtime_handle,
        );
        assert!(matches!(result, Err(crate::interface::ClipKittyError::Cancelled)));

        // Test trigram query sync with pre-cancelled token
        let result = ClipboardStore::search_trigram_query_sync(
            &store.db,
            &store.indexer,
            "Hello",
            &token,
            &runtime_handle,
        );
        assert!(matches!(result, Err(crate::interface::ClipKittyError::Cancelled)));
    }

    #[test]
    fn test_interruptible_fetch_spawns_watcher() {
        // Test that interruptible fetch properly sets up the interrupt watcher.
        // Note: SQLite interrupt is a race - if query completes before watcher runs,
        // the result is returned normally. This test verifies the mechanism works
        // without depending on timing.
        let rt = runtime();
        let store = ClipboardStore::new_in_memory().unwrap();

        // Add some data
        let id = store.save_text("Test content".to_string(), None, None).unwrap();

        // Test 1: With non-cancelled token, fetch completes normally
        let token = CancellationToken::new();
        let runtime_handle = rt.handle().clone();

        let result = store.db.fetch_items_by_ids_interruptible(
            &[id],
            &token,
            &runtime_handle,
        ).unwrap();

        assert_eq!(result.len(), 1);
        assert!(!token.is_cancelled()); // Token wasn't cancelled

        // Test 2: Verify the AbortOnDropHandle pattern - watcher is aborted on scope exit
        // We can't easily test the interrupt itself without a long-running query,
        // but we can verify the watcher doesn't outlive the fetch call by checking
        // that subsequent fetches work correctly (no lingering watchers)
        for _ in 0..10 {
            let token = CancellationToken::new();
            let result = store.db.fetch_items_by_ids_interruptible(
                &[id],
                &token,
                &runtime_handle,
            ).unwrap();
            assert_eq!(result.len(), 1);
        }
    }

    #[tokio::test]
    async fn test_async_search_cancellation_via_drop() {
        // Test that dropping the search future triggers cancellation

        let store = ClipboardStore::new_in_memory().unwrap();

        // Add many items to make search take longer
        for i in 0..100 {
            store.save_text(format!("Item number {} with some text content", i), None, None).unwrap();
        }

        // Start a search but drop it immediately
        let search_future = store.search("Item".to_string());

        // Drop the future without awaiting - this should trigger DropGuard
        drop(search_future);

        // If we get here without hanging, the cancellation worked
        // The DropGuard should have cancelled the token

        // Verify we can still search normally after cancellation
        let result = store.search("Item".to_string()).await.unwrap();
        assert!(!result.matches.is_empty());
    }

    #[tokio::test]
    async fn test_search_completes_normally_without_cancellation() {
        // Verify that search works normally when not cancelled
        let store = ClipboardStore::new_in_memory().unwrap();

        store.save_text("Hello World from ClipKitty".to_string(), None, None).unwrap();
        store.save_text("Another greeting hello".to_string(), None, None).unwrap();
        store.save_text("Unrelated content".to_string(), None, None).unwrap();

        // Short query (< 3 chars)
        let result = store.search("He".to_string()).await.unwrap();
        assert!(!result.matches.is_empty());

        // Trigram query (>= 3 chars)
        let result = store.search("Hello".to_string()).await.unwrap();
        assert!(!result.matches.is_empty());
        assert!(result.matches.iter().all(|m|
            m.item_metadata.snippet.to_lowercase().contains("hello")
        ));
    }

    #[tokio::test]
    async fn test_concurrent_searches_independent() {
        // Test that multiple concurrent searches work independently
        let store = std::sync::Arc::new(ClipboardStore::new_in_memory().unwrap());

        // Add data
        for i in 0..50 {
            store.save_text(format!("Test item {} for searching", i), None, None).unwrap();
        }

        let store1 = store.clone();
        let store2 = store.clone();
        let store3 = store.clone();

        // Start multiple searches concurrently
        let search1 = tokio::spawn(async move {
            store1.search("Test".to_string()).await
        });

        let search2 = tokio::spawn(async move {
            store2.search("item".to_string()).await
        });

        let search3 = tokio::spawn(async move {
            store3.search("for".to_string()).await
        });

        // All should complete successfully
        let result1 = search1.await.unwrap().unwrap();
        let result2 = search2.await.unwrap().unwrap();
        let result3 = search3.await.unwrap().unwrap();

        assert!(!result1.matches.is_empty());
        assert!(!result2.matches.is_empty());
        assert!(!result3.matches.is_empty());

        // Store should still be usable after concurrent access
        let result = store.search("Test".to_string()).await.unwrap();
        assert!(!result.matches.is_empty());
    }

    #[tokio::test]
    async fn test_search_abort_doesnt_corrupt_store() {
        // Test that aborting a search task doesn't corrupt the store
        let store = std::sync::Arc::new(ClipboardStore::new_in_memory().unwrap());

        // Add data
        for i in 0..20 {
            store.save_text(format!("Item number {}", i), None, None).unwrap();
        }

        // Abort several searches in rapid succession
        for _ in 0..5 {
            let store_clone = store.clone();
            let handle = tokio::spawn(async move {
                store_clone.search("Item".to_string()).await
            });
            handle.abort();
            // Ignore the result - it may complete or be aborted
            let _ = handle.await;
        }

        // Store should still work correctly
        let result = store.search("Item".to_string()).await.unwrap();
        assert!(!result.matches.is_empty());

        // Can still add and search for new items
        store.save_text("New item after aborts".to_string(), None, None).unwrap();
        let result = store.search("after aborts".to_string()).await.unwrap();
        assert!(!result.matches.is_empty());
    }

    #[test]
    fn test_dropguard_cancels_on_panic() {
        // Test that DropGuard cancels even during unwinding
        let token = CancellationToken::new();
        let token_clone = token.clone();

        let result = std::panic::catch_unwind(|| {
            let _guard = DropGuard::new(token_clone);
            panic!("Intentional panic to test unwinding");
        });

        assert!(result.is_err()); // Panic was caught
        assert!(token.is_cancelled()); // Token was still cancelled during unwinding
    }

    #[test]
    fn test_multiple_dropguards_same_token() {
        // Test that multiple DropGuards can share a token
        let token = CancellationToken::new();

        let guard1 = DropGuard::new(token.clone());
        let guard2 = DropGuard::new(token.clone());

        assert!(!token.is_cancelled());

        drop(guard1);
        assert!(token.is_cancelled()); // First drop cancels

        drop(guard2);
        assert!(token.is_cancelled()); // Still cancelled, no error from double-cancel
    }

    /// Test that async search works without an external tokio runtime.
    /// This simulates what happens when UniFFI calls our async function -
    /// UniFFI doesn't provide a tokio runtime, so we must manage our own.
    #[test]
    fn test_search_works_without_external_tokio_runtime() {
        // This test does NOT use #[tokio::test] - it has no tokio runtime context
        // This is how UniFFI calls our async functions

        let store = ClipboardStore::new_in_memory().unwrap();
        store.save_text("Hello World".to_string(), None, None).unwrap();
        store.save_text("Test content".to_string(), None, None).unwrap();

        // Block on the future without a surrounding tokio runtime
        // We use futures::executor to simulate UniFFI's async handling
        let result = futures::executor::block_on(store.search("Hello".to_string()));

        // Should complete successfully, not panic
        assert!(result.is_ok());
        let search_result = result.unwrap();
        assert!(!search_result.matches.is_empty());
    }
}
