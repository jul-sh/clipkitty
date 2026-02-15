//! ClipboardStore - Main API for Swift interop
//! and Tantivy search functionality, designed for UniFFI export.
//!
//! Architecture: Tantivy search with trigram retrieval and phrase-boost scoring
//!
//! Async Cancellation Architecture:
//! When Swift cancels an async Task, UniFFI drops the Rust Future. We intercept this
//! via a DropGuard that triggers a CancellationToken. The blocking search thread
//! checks this token at key checkpoints and can abort mid-flight.

use crate::database::Database;
use crate::indexer::Indexer;
use crate::interface::{
    ClipboardItem, ContentTypeFilter, ItemMatch, MatchData, SearchResult, ClipKittyError, ClipboardStoreApi,
};
use crate::models::StoredItem;
use crate::search::{self, MIN_TRIGRAM_QUERY_LEN, MAX_RESULTS};
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
        filter: Option<&ContentTypeFilter>,
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
            // Apply content type filter post-retrieval (Tantivy doesn't index content type)
            .filter(|(_, item)| {
                match filter {
                    Some(f) => f.matches_db_type(item.content.database_type()),
                    None => true,
                }
            })
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
        filter: Option<&ContentTypeFilter>,
    ) -> Result<Vec<ItemMatch>, ClipKittyError> {
        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let candidates = db.search_short_query(query, MAX_RESULTS, filter)?;
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

        Self::fuzzy_matches_to_item_matches(db, fuzzy_matches, token, runtime, filter)
    }

    /// Trigram query search using Tantivy with phrase-boost scoring
    fn search_trigram_query_sync(
        db: &Database,
        indexer: &Indexer,
        query: &str,
        token: &CancellationToken,
        runtime: &tokio::runtime::Handle,
        filter: Option<&ContentTypeFilter>,
    ) -> Result<Vec<ItemMatch>, ClipKittyError> {
        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let fuzzy_matches = search::search_trigram(indexer, query, token)?;
        if fuzzy_matches.is_empty() {
            return Ok(Vec::new());
        }

        Self::fuzzy_matches_to_item_matches(db, fuzzy_matches, token, runtime, filter)
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
            .map(|p| p.join("tantivy_index_v3"))
            .unwrap_or_else(|| PathBuf::from("tantivy_index_v3"));

        let indexer = Indexer::new(&index_path)?;

        let store = Self {
            db: Arc::new(db),
            indexer: Arc::new(indexer),
        };

        store.rebuild_index_if_needed()?;

        Ok(store)
    }
}

// Filtered search (not on trait, to avoid breaking foreign interface)
#[uniffi::export]
impl ClipboardStore {
    /// Search with a content type filter.
    /// When filter is All, delegates to the trait's search() method.
    pub async fn search_filtered(
        &self,
        query: String,
        filter: ContentTypeFilter,
    ) -> Result<SearchResult, ClipKittyError> {
        if filter == ContentTypeFilter::All {
            return self.search(query).await;
        }

        let trimmed = query.trim();

        // Empty query with filter: return recent items of that type
        if trimmed.is_empty() {
            let (items, total_count) = self.db.fetch_item_metadata(None, 1000, Some(&filter))?;

            let first_item = if let Some(first_metadata) = items.first() {
                self.db
                    .fetch_items_by_ids(&[first_metadata.item_id])?
                    .into_iter()
                    .next()
                    .map(|item| item.to_clipboard_item())
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

        let runtime = self.runtime_handle();
        let runtime_for_closure = runtime.clone();

        let db = Arc::clone(&self.db);
        let indexer = Arc::clone(&self.indexer);
        let query_owned = query.to_string();
        let trimmed_owned = trimmed.to_string();
        let token_clone = token.clone();

        let handle = runtime.spawn_blocking(move || {
            if trimmed_owned.len() < MIN_TRIGRAM_QUERY_LEN {
                let matches = Self::search_short_query_sync(&db, &trimmed_owned, &token_clone, &runtime_for_closure, Some(&filter))?;
                let total_count = matches.len() as u64;
                Ok((matches, total_count))
            } else {
                let matches = Self::search_trigram_query_sync(&db, &indexer, &query_owned, &token_clone, &runtime_for_closure, Some(&filter))?;
                let total_count = matches.len() as u64;
                Ok((matches, total_count))
            }
        });

        match handle.await {
            Ok(Ok((matches, total_count))) => {
                let first_item = if let Some(first_match) = matches.first() {
                    let id = first_match.item_metadata.item_id;
                    self.db
                        .fetch_items_by_ids(&[id])?
                        .into_iter()
                        .next()
                        .map(|item| item.to_clipboard_item())
                } else {
                    None
                };

                Ok(SearchResult { matches, total_count, first_item })
            }
            Ok(Err(e)) => Err(e),
            Err(_join_error) => Err(ClipKittyError::Cancelled),
        }
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
            let (items, total_count) = self.db.fetch_item_metadata(None, 1000, None)?;

            // Fetch first item's full content for preview pane
            let first_item = if let Some(first_metadata) = items.first() {
                self.db
                    .fetch_items_by_ids(&[first_metadata.item_id])?
                    .into_iter()
                    .next()
                    .map(|item| item.to_clipboard_item())
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
                let matches = Self::search_short_query_sync(&db, &trimmed_owned, &token_clone, &runtime_for_closure, None)?;
                let total_count = matches.len() as u64;
                Ok((matches, total_count))
            } else {
                let matches = Self::search_trigram_query_sync(&db, &indexer, &query_owned, &token_clone, &runtime_for_closure, None)?;
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
                        .map(|item| item.to_clipboard_item())
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
            .map(|item| item.to_clipboard_item())
            .collect();
        Ok(items)
    }

    /// Save a file item to the database and index
    /// Returns the new item ID, or 0 if duplicate (timestamp updated)
    fn save_file(
        &self,
        path: String,
        filename: String,
        file_size: u64,
        uti: String,
        bookmark_data: Vec<u8>,
        thumbnail: Option<Vec<u8>>,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Result<i64, ClipKittyError> {
        let item = StoredItem::new_file(
            path, filename, file_size, uti, bookmark_data,
            thumbnail, source_app, source_app_bundle_id,
        );

        // Check for duplicate
        if let Some(existing) = self.db.find_by_hash(&item.content_hash)? {
            if let Some(id) = existing.id {
                let now = Utc::now();
                self.db.update_timestamp(id, now)?;

                let index_text = item.file_index_text().unwrap_or_else(|| item.text_content().to_string());
                self.indexer.add_document(id, &index_text, now.timestamp())?;
                self.indexer.commit()?;

                return Ok(0);
            }
        }

        // Index text includes both filename and path for searchability
        let index_text = item.file_index_text().unwrap_or_else(|| item.text_content().to_string());

        let id = self.db.insert_item(&item)?;
        self.indexer.add_document(id, &index_text, item.timestamp_unix)?;
        self.indexer.commit()?;

        Ok(id)
    }

    /// Update file status (called from Swift when file move/delete detected)
    fn update_file_status(&self, item_id: i64, status: String, new_path: Option<String>) -> Result<(), ClipKittyError> {
        self.db.update_file_status(item_id, &status, new_path.as_deref())?;
        Ok(())
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
            None,
        );
        assert!(matches!(result, Err(crate::interface::ClipKittyError::Cancelled)));

        // Test trigram query sync with pre-cancelled token
        let result = ClipboardStore::search_trigram_query_sync(
            &store.db,
            &store.indexer,
            "Hello",
            &token,
            &runtime_handle,
            None,
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

    // ─────────────────────────────────────────────────────────────────────────────
    // File item tests
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_save_file_roundtrip() {
        // Verify all file fields survive the save → database → fetch roundtrip
        let store = ClipboardStore::new_in_memory().unwrap();

        let bookmark_data = vec![0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04];
        let thumbnail = vec![0xFF, 0xD8, 0xFF, 0xE0]; // Simulated JPEG header

        let id = store.save_file(
            "/Users/test/Documents/report.pdf".to_string(),
            "report.pdf".to_string(),
            1024 * 1024, // 1 MB
            "com.adobe.pdf".to_string(),
            bookmark_data.clone(),
            Some(thumbnail.clone()),
            Some("Finder".to_string()),
            Some("com.apple.finder".to_string()),
        ).unwrap();

        assert!(id > 0, "save_file should return a positive ID for new items");

        // Fetch the item back
        let items = store.fetch_by_ids(vec![id]).unwrap();
        assert_eq!(items.len(), 1);

        let item = &items[0];

        // Verify content is File variant with all fields preserved
        if let crate::interface::ClipboardContent::File {
            path, filename, file_size, uti, bookmark_data: bm, file_status,
        } = &item.content {
            assert_eq!(path, "/Users/test/Documents/report.pdf");
            assert_eq!(filename, "report.pdf");
            assert_eq!(*file_size, 1024 * 1024);
            assert_eq!(uti, "com.adobe.pdf");
            assert_eq!(bm, &bookmark_data, "bookmark_data must survive roundtrip");
            assert_eq!(*file_status, crate::interface::FileStatus::Available);
        } else {
            panic!("Expected File content, got: {:?}", item.content);
        }

        // Verify metadata
        assert_eq!(item.item_metadata.source_app.as_deref(), Some("Finder"));
        assert_eq!(item.item_metadata.source_app_bundle_id.as_deref(), Some("com.apple.finder"));

        // Verify icon is thumbnail (since we provided one)
        if let crate::interface::ItemIcon::Thumbnail { bytes } = &item.item_metadata.icon {
            assert_eq!(bytes, &thumbnail);
        } else {
            panic!("Expected Thumbnail icon, got: {:?}", item.item_metadata.icon);
        }
    }

    #[test]
    fn test_save_file_without_thumbnail() {
        // Files without thumbnails should use the File symbol icon
        let store = ClipboardStore::new_in_memory().unwrap();

        let id = store.save_file(
            "/tmp/notes.txt".to_string(),
            "notes.txt".to_string(),
            256,
            "public.plain-text".to_string(),
            vec![1, 2, 3],
            None, // no thumbnail
            None,
            None,
        ).unwrap();

        let items = store.fetch_by_ids(vec![id]).unwrap();
        assert_eq!(items.len(), 1);

        // Should have File symbol icon (no thumbnail)
        if let crate::interface::ItemIcon::Symbol { icon_type } = &items[0].item_metadata.icon {
            assert_eq!(*icon_type, crate::interface::IconType::File);
        } else {
            panic!("Expected Symbol(File) icon, got: {:?}", items[0].item_metadata.icon);
        }
    }

    #[test]
    fn test_save_file_duplicate_handling() {
        let rt = runtime();
        let store = ClipboardStore::new_in_memory().unwrap();

        let id1 = store.save_file(
            "/Users/test/file.txt".to_string(),
            "file.txt".to_string(),
            100,
            "public.plain-text".to_string(),
            vec![1, 2, 3],
            None,
            None,
            None,
        ).unwrap();
        assert!(id1 > 0);

        // Save same path again — should deduplicate
        let id2 = store.save_file(
            "/Users/test/file.txt".to_string(),
            "file.txt".to_string(),
            100,
            "public.plain-text".to_string(),
            vec![1, 2, 3],
            None,
            None,
            None,
        ).unwrap();
        assert_eq!(id2, 0, "Duplicate file should return 0");

        // Only one item in the store
        let result = rt.block_on(store.search("".to_string())).unwrap();
        assert_eq!(result.matches.len(), 1);
    }

    #[tokio::test]
    async fn test_save_file_searchable_by_filename() {
        let store = ClipboardStore::new_in_memory().unwrap();

        store.save_file(
            "/Users/test/Documents/quarterly-report.pdf".to_string(),
            "quarterly-report.pdf".to_string(),
            5000,
            "com.adobe.pdf".to_string(),
            vec![1],
            None,
            None,
            None,
        ).unwrap();

        // Search by filename
        let result = store.search("quarterly".to_string()).await.unwrap();
        assert!(!result.matches.is_empty(), "Should find file by filename search");
    }

    #[tokio::test]
    async fn test_save_file_searchable_by_path() {
        let store = ClipboardStore::new_in_memory().unwrap();

        store.save_file(
            "/Users/test/Documents/quarterly-report.pdf".to_string(),
            "quarterly-report.pdf".to_string(),
            5000,
            "com.adobe.pdf".to_string(),
            vec![1],
            None,
            None,
            None,
        ).unwrap();

        // Search by path component
        let result = store.search("Documents".to_string()).await.unwrap();
        assert!(!result.matches.is_empty(), "Should find file by path component search");
    }

    #[tokio::test]
    async fn test_file_content_type_filter() {
        let store = ClipboardStore::new_in_memory().unwrap();

        // Save a text item and a file item
        store.save_text("Hello World".to_string(), None, None).unwrap();
        store.save_file(
            "/tmp/test.pdf".to_string(),
            "test.pdf".to_string(),
            100,
            "com.adobe.pdf".to_string(),
            vec![1],
            None,
            None,
            None,
        ).unwrap();

        // Unfiltered search should return both
        let all = store.search("".to_string()).await.unwrap();
        assert_eq!(all.matches.len(), 2);

        // Files filter should return only the file
        let files = store.search_filtered("".to_string(), ContentTypeFilter::Files).await.unwrap();
        assert_eq!(files.matches.len(), 1);
        assert!(files.matches[0].item_metadata.snippet.contains("test.pdf"));

        // Text filter should return only the text
        let texts = store.search_filtered("".to_string(), ContentTypeFilter::Text).await.unwrap();
        assert_eq!(texts.matches.len(), 1);
        assert!(texts.matches[0].item_metadata.snippet.contains("Hello World"));
    }

    #[test]
    fn test_update_file_status_roundtrip() {
        let store = ClipboardStore::new_in_memory().unwrap();

        let id = store.save_file(
            "/Users/test/doc.txt".to_string(),
            "doc.txt".to_string(),
            50,
            "public.plain-text".to_string(),
            vec![10, 20, 30],
            None,
            None,
            None,
        ).unwrap();

        // Initially available
        let items = store.fetch_by_ids(vec![id]).unwrap();
        if let crate::interface::ClipboardContent::File { file_status, .. } = &items[0].content {
            assert_eq!(*file_status, crate::interface::FileStatus::Available);
        } else {
            panic!("Expected File content");
        }

        // Update to moved
        store.update_file_status(
            id,
            "moved:/Users/test/renamed.txt".to_string(),
            Some("/Users/test/renamed.txt".to_string()),
        ).unwrap();

        let items = store.fetch_by_ids(vec![id]).unwrap();
        if let crate::interface::ClipboardContent::File { file_status, path, .. } = &items[0].content {
            assert_eq!(*file_status, crate::interface::FileStatus::Moved {
                new_path: "/Users/test/renamed.txt".to_string()
            });
            assert_eq!(path, "/Users/test/renamed.txt", "path should update on move");
        } else {
            panic!("Expected File content");
        }

        // Update to trashed
        store.update_file_status(id, "trashed".to_string(), None).unwrap();
        let items = store.fetch_by_ids(vec![id]).unwrap();
        if let crate::interface::ClipboardContent::File { file_status, .. } = &items[0].content {
            assert_eq!(*file_status, crate::interface::FileStatus::Trashed);
        } else {
            panic!("Expected File content");
        }

        // Update to missing
        store.update_file_status(id, "missing".to_string(), None).unwrap();
        let items = store.fetch_by_ids(vec![id]).unwrap();
        if let crate::interface::ClipboardContent::File { file_status, .. } = &items[0].content {
            assert_eq!(*file_status, crate::interface::FileStatus::Missing);
        } else {
            panic!("Expected File content");
        }
    }

    #[test]
    fn test_save_file_bookmark_data_preserved_exactly() {
        // Verify bookmark data (binary blob) survives the full roundtrip byte-for-byte
        // This is the critical data needed for paste — if corrupted, paste silently fails
        let store = ClipboardStore::new_in_memory().unwrap();

        // Use realistic-sized bookmark data (real bookmarks are typically 200-1000 bytes)
        let bookmark_data: Vec<u8> = (0..512).map(|i| (i % 256) as u8).collect();

        let id = store.save_file(
            "/Users/test/important.docx".to_string(),
            "important.docx".to_string(),
            2048,
            "org.openxmlformats.wordprocessingml.document".to_string(),
            bookmark_data.clone(),
            None,
            None,
            None,
        ).unwrap();

        let items = store.fetch_by_ids(vec![id]).unwrap();
        if let crate::interface::ClipboardContent::File { bookmark_data: fetched, .. } = &items[0].content {
            assert_eq!(fetched.len(), bookmark_data.len(), "bookmark_data length mismatch");
            assert_eq!(fetched, &bookmark_data, "bookmark_data bytes must match exactly");
        } else {
            panic!("Expected File content");
        }
    }

    #[test]
    fn test_file_text_content_is_filename() {
        // The text_content for files should be the filename (used for display/snippets)
        let store = ClipboardStore::new_in_memory().unwrap();

        let id = store.save_file(
            "/very/long/path/to/my-spreadsheet.xlsx".to_string(),
            "my-spreadsheet.xlsx".to_string(),
            100,
            "org.openxmlformats.spreadsheetml.sheet".to_string(),
            vec![1],
            None,
            None,
            None,
        ).unwrap();

        let items = store.fetch_by_ids(vec![id]).unwrap();
        assert_eq!(items[0].content.text_content(), "my-spreadsheet.xlsx");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Phase 2: Comprehensive file clipboard tests
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_save_folder_item() {
        // Directory (UTI public.folder) should save and fetch correctly
        let store = ClipboardStore::new_in_memory().unwrap();

        let id = store.save_file(
            "/Users/test/Projects".to_string(),
            "Projects".to_string(),
            0,
            "public.folder".to_string(),
            vec![0xAA, 0xBB],
            None,
            Some("Finder".to_string()),
            Some("com.apple.finder".to_string()),
        ).unwrap();
        assert!(id > 0);

        let items = store.fetch_by_ids(vec![id]).unwrap();
        assert_eq!(items.len(), 1);

        if let crate::interface::ClipboardContent::File {
            path, filename, file_size, uti, ..
        } = &items[0].content {
            assert_eq!(path, "/Users/test/Projects");
            assert_eq!(filename, "Projects");
            assert_eq!(*file_size, 0);
            assert_eq!(uti, "public.folder");
        } else {
            panic!("Expected File content, got: {:?}", items[0].content);
        }

        // text_content should return the folder name
        assert_eq!(items[0].content.text_content(), "Projects");
    }

    #[test]
    fn test_file_icon_type_with_thumbnail() {
        // File with thumbnail should have ItemIcon::Thumbnail
        let store = ClipboardStore::new_in_memory().unwrap();
        let thumb = vec![0xFF, 0xD8, 0xFF, 0xE0];

        let id = store.save_file(
            "/tmp/photo.png".to_string(),
            "photo.png".to_string(),
            2048,
            "public.png".to_string(),
            vec![1],
            Some(thumb.clone()),
            None,
            None,
        ).unwrap();

        let items = store.fetch_by_ids(vec![id]).unwrap();
        if let crate::interface::ItemIcon::Thumbnail { bytes } = &items[0].item_metadata.icon {
            assert_eq!(bytes, &thumb);
        } else {
            panic!("Expected Thumbnail icon, got: {:?}", items[0].item_metadata.icon);
        }
    }

    #[test]
    fn test_file_icon_type_without_thumbnail() {
        // File without thumbnail should have ItemIcon::Symbol { icon_type: File }
        let store = ClipboardStore::new_in_memory().unwrap();

        let id = store.save_file(
            "/tmp/data.csv".to_string(),
            "data.csv".to_string(),
            500,
            "public.comma-separated-values-text".to_string(),
            vec![1],
            None,
            None,
            None,
        ).unwrap();

        let items = store.fetch_by_ids(vec![id]).unwrap();
        if let crate::interface::ItemIcon::Symbol { icon_type } = &items[0].item_metadata.icon {
            assert_eq!(*icon_type, crate::interface::IconType::File);
        } else {
            panic!("Expected Symbol(File) icon, got: {:?}", items[0].item_metadata.icon);
        }
    }

    #[test]
    fn test_file_database_type() {
        // File should have contentType "file" and appear in Files filter
        let store = ClipboardStore::new_in_memory().unwrap();

        let id = store.save_file(
            "/tmp/test.pdf".to_string(),
            "test.pdf".to_string(),
            100,
            "com.adobe.pdf".to_string(),
            vec![1],
            None,
            None,
            None,
        ).unwrap();

        let items = store.fetch_by_ids(vec![id]).unwrap();
        assert_eq!(items[0].content.database_type(), "file");
    }

    #[tokio::test]
    async fn test_file_snippet_in_search_results() {
        // Searching by filename should return a snippet containing the filename
        let store = ClipboardStore::new_in_memory().unwrap();

        store.save_file(
            "/Users/test/resume.docx".to_string(),
            "resume.docx".to_string(),
            4096,
            "org.openxmlformats.wordprocessingml.document".to_string(),
            vec![1],
            None,
            None,
            None,
        ).unwrap();

        let result = store.search("resume".to_string()).await.unwrap();
        assert!(!result.matches.is_empty(), "Should find file by filename");
        assert!(
            result.matches[0].item_metadata.snippet.contains("resume"),
            "Snippet should contain filename"
        );
    }

    #[tokio::test]
    async fn test_files_excluded_from_text_filter() {
        // Text filter should not return file items
        let store = ClipboardStore::new_in_memory().unwrap();

        store.save_text("plain text".to_string(), None, None).unwrap();
        store.save_file(
            "/tmp/file.txt".to_string(),
            "file.txt".to_string(),
            10,
            "public.plain-text".to_string(),
            vec![1],
            None,
            None,
            None,
        ).unwrap();

        let texts = store.search_filtered("".to_string(), ContentTypeFilter::Text).await.unwrap();
        assert_eq!(texts.matches.len(), 1);
        assert!(texts.matches[0].item_metadata.snippet.contains("plain text"));
    }

    #[tokio::test]
    async fn test_text_excluded_from_files_filter() {
        // Files filter should not return text items
        let store = ClipboardStore::new_in_memory().unwrap();

        store.save_text("some text".to_string(), None, None).unwrap();
        store.save_file(
            "/tmp/doc.pdf".to_string(),
            "doc.pdf".to_string(),
            200,
            "com.adobe.pdf".to_string(),
            vec![1],
            None,
            None,
            None,
        ).unwrap();

        let files = store.search_filtered("".to_string(), ContentTypeFilter::Files).await.unwrap();
        assert_eq!(files.matches.len(), 1);
        assert!(files.matches[0].item_metadata.snippet.contains("doc.pdf"));
    }

    #[test]
    fn test_same_filename_different_paths_no_dedup() {
        // Same filename but different paths should not deduplicate (different hashes)
        let store = ClipboardStore::new_in_memory().unwrap();

        let id1 = store.save_file(
            "/Users/alice/readme.md".to_string(),
            "readme.md".to_string(),
            100,
            "net.daringfireball.markdown".to_string(),
            vec![1],
            None,
            None,
            None,
        ).unwrap();

        let id2 = store.save_file(
            "/Users/bob/readme.md".to_string(),
            "readme.md".to_string(),
            200,
            "net.daringfireball.markdown".to_string(),
            vec![2],
            None,
            None,
            None,
        ).unwrap();

        assert!(id1 > 0);
        assert!(id2 > 0, "Different paths should not deduplicate");
    }

    #[test]
    fn test_same_path_deduplicates() {
        // Same path should deduplicate (hash is based on path)
        let store = ClipboardStore::new_in_memory().unwrap();

        let id1 = store.save_file(
            "/Users/test/file.txt".to_string(),
            "file.txt".to_string(),
            100,
            "public.plain-text".to_string(),
            vec![1],
            None,
            None,
            None,
        ).unwrap();
        assert!(id1 > 0);

        // Same path, different filename (simulating rename) — should deduplicate by path
        let id2 = store.save_file(
            "/Users/test/file.txt".to_string(),
            "renamed.txt".to_string(),
            100,
            "public.plain-text".to_string(),
            vec![1],
            None,
            None,
            None,
        ).unwrap();
        assert_eq!(id2, 0, "Same path should deduplicate");
    }

    #[test]
    fn test_file_with_unicode_filename() {
        // Unicode filenames (emoji, CJK, accented chars) should roundtrip exactly
        let store = ClipboardStore::new_in_memory().unwrap();

        let filename = "日本語ファイル🎉café.txt";
        let path = format!("/Users/test/{}", filename);

        let id = store.save_file(
            path.clone(),
            filename.to_string(),
            42,
            "public.plain-text".to_string(),
            vec![1],
            None,
            None,
            None,
        ).unwrap();

        let items = store.fetch_by_ids(vec![id]).unwrap();
        if let crate::interface::ClipboardContent::File {
            path: fetched_path, filename: fetched_name, ..
        } = &items[0].content {
            assert_eq!(fetched_name, filename);
            assert_eq!(fetched_path, &path);
        } else {
            panic!("Expected File content");
        }
    }

    #[tokio::test]
    async fn test_file_with_spaces_in_path() {
        // Paths with spaces should roundtrip and be searchable
        let store = ClipboardStore::new_in_memory().unwrap();

        let id = store.save_file(
            "/Users/test/My Documents/Annual Report 2024.pdf".to_string(),
            "Annual Report 2024.pdf".to_string(),
            1000,
            "com.adobe.pdf".to_string(),
            vec![1],
            None,
            None,
            None,
        ).unwrap();

        let items = store.fetch_by_ids(vec![id]).unwrap();
        if let crate::interface::ClipboardContent::File { path, .. } = &items[0].content {
            assert_eq!(path, "/Users/test/My Documents/Annual Report 2024.pdf");
        } else {
            panic!("Expected File content");
        }

        // Should be searchable by terms with spaces
        let result = store.search("Annual Report".to_string()).await.unwrap();
        assert!(!result.matches.is_empty(), "Should find file with spaces in name");
    }

    #[test]
    fn test_file_status_parsing_unknown_string() {
        // Unknown status strings should default to Available
        use crate::interface::FileStatus;

        assert_eq!(
            FileStatus::from_database_str("garbage"),
            FileStatus::Available
        );
        assert_eq!(
            FileStatus::from_database_str(""),
            FileStatus::Available
        );
        assert_eq!(
            FileStatus::from_database_str("AVAILABLE"),
            FileStatus::Available
        );
    }

    #[test]
    fn test_file_status_moved_with_colon_in_path() {
        // "moved:" prefix should only split on first colon
        use crate::interface::FileStatus;

        let status = FileStatus::from_database_str("moved:/path/with:colon/file.txt");
        assert_eq!(
            status,
            FileStatus::Moved { new_path: "/path/with:colon/file.txt".to_string() }
        );
    }

    #[test]
    fn test_file_zero_size() {
        // Empty files (size 0) should roundtrip correctly
        let store = ClipboardStore::new_in_memory().unwrap();

        let id = store.save_file(
            "/tmp/empty.txt".to_string(),
            "empty.txt".to_string(),
            0,
            "public.plain-text".to_string(),
            vec![1],
            None,
            None,
            None,
        ).unwrap();

        let items = store.fetch_by_ids(vec![id]).unwrap();
        if let crate::interface::ClipboardContent::File { file_size, .. } = &items[0].content {
            assert_eq!(*file_size, 0);
        } else {
            panic!("Expected File content");
        }
    }

    #[test]
    fn test_file_large_size() {
        // Very large file sizes should roundtrip without overflow
        let store = ClipboardStore::new_in_memory().unwrap();

        let large_size: u64 = u64::MAX;
        let id = store.save_file(
            "/tmp/huge.bin".to_string(),
            "huge.bin".to_string(),
            large_size,
            "public.data".to_string(),
            vec![1],
            None,
            None,
            None,
        ).unwrap();

        let items = store.fetch_by_ids(vec![id]).unwrap();
        if let crate::interface::ClipboardContent::File { file_size, .. } = &items[0].content {
            assert_eq!(*file_size, large_size);
        } else {
            panic!("Expected File content");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Regression guards
    // ─────────────────────────────────────────────────────────────────────────────

    #[tokio::test]
    async fn test_file_search_ranking_with_text_items() {
        // Files should appear alongside text in mixed search results
        let store = ClipboardStore::new_in_memory().unwrap();

        store.save_text("meeting notes from today".to_string(), None, None).unwrap();
        store.save_file(
            "/Users/test/meeting-notes.pdf".to_string(),
            "meeting-notes.pdf".to_string(),
            500,
            "com.adobe.pdf".to_string(),
            vec![1],
            None,
            None,
            None,
        ).unwrap();

        let result = store.search("meeting".to_string()).await.unwrap();
        assert_eq!(result.matches.len(), 2, "Both text and file should appear in results");
    }

    #[tokio::test]
    async fn test_file_text_content_used_for_snippet() {
        // Snippet should use filename, not the full path
        let store = ClipboardStore::new_in_memory().unwrap();

        store.save_file(
            "/very/deep/nested/path/to/important-doc.pdf".to_string(),
            "important-doc.pdf".to_string(),
            100,
            "com.adobe.pdf".to_string(),
            vec![1],
            None,
            None,
            None,
        ).unwrap();

        let result = store.search("".to_string()).await.unwrap();
        assert!(!result.matches.is_empty());
        // Snippet should contain the filename
        assert!(
            result.matches[0].item_metadata.snippet.contains("important-doc.pdf"),
            "Snippet should display filename: {}",
            result.matches[0].item_metadata.snippet
        );
    }

    #[test]
    fn test_update_file_status_only_affects_files() {
        // Calling update_file_status on a text item should be a no-op
        let store = ClipboardStore::new_in_memory().unwrap();

        let text_id = store.save_text("Hello World".to_string(), None, None).unwrap();

        // This should succeed without error (SQL WHERE clause filters by contentType='file')
        store.update_file_status(
            text_id,
            "trashed".to_string(),
            None,
        ).unwrap();

        // Text item should be unchanged
        let items = store.fetch_by_ids(vec![text_id]).unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].content.text_content(), "Hello World");
        assert!(matches!(items[0].content, crate::interface::ClipboardContent::Text { .. }));
    }
}
