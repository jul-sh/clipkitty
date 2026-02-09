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
    ClipboardItem, ItemMatch, MatchData, SearchResult, ClipKittyError, ClipboardStoreApi,
};
use crate::models::StoredItem;
use crate::search::{SearchEngine, MIN_TRIGRAM_QUERY_LEN, MAX_RESULTS, HIGHLIGHT_BATCH_SIZE};
use chrono::Utc;
use once_cell::sync::Lazy;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio_util::sync::CancellationToken;

/// Global fallback Tokio runtime for when async functions are called outside any runtime context.
/// This is shared across all ClipboardStore instances and never dropped.
/// Used by UniFFI which doesn't provide a tokio runtime.
static FALLBACK_RUNTIME: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("Failed to create fallback tokio runtime")
});

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

/// Per-stage timing breakdown for benchmarking
pub struct SearchTimings {
    pub tantivy_ms: f64,
    pub highlight_ms: f64,
    pub db_fetch_head_ms: f64,
    pub match_gen_ms: f64,
    pub db_fetch_tail_ms: f64,
    pub total_ms: f64,
    pub num_candidates: usize,
    pub num_highlighted: usize,
    pub num_metadata_only: usize,
    pub num_results: usize,
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

    /// Get a tokio runtime handle - uses current runtime if available, otherwise global fallback
    fn runtime_handle(&self) -> tokio::runtime::Handle {
        tokio::runtime::Handle::try_current()
            .unwrap_or_else(|_| FALLBACK_RUNTIME.handle().clone())
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
    ///
    /// Lazy highlighting: only the first HIGHLIGHT_BATCH_SIZE results get full highlights.
    /// The rest are returned as IDs only (no DB fetch during search).
    fn search_short_query_sync(
        db: &Database,
        search_engine: &SearchEngine,
        query: &str,
        token: &CancellationToken,
        runtime: &tokio::runtime::Handle,
    ) -> Result<(Vec<i64>, HashMap<i64, ItemMatch>), ClipKittyError> {
        // Checkpoint: Check cancellation before DB query
        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let candidates = db.search_short_query(query, MAX_RESULTS * 5)?;

        if candidates.is_empty() {
            return Ok((Vec::new(), HashMap::new()));
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

        // Collect all IDs in order
        let ids: Vec<i64> = fuzzy_matches.iter().map(|m| m.id).collect();

        // Split at HIGHLIGHT_BATCH_SIZE
        let split_at = HIGHLIGHT_BATCH_SIZE.min(fuzzy_matches.len());
        let head = &fuzzy_matches[..split_at];

        // --- First batch: full highlight + DB fetch ---
        let head_ids: Vec<i64> = head.iter().map(|m| m.id).collect();
        let head_items = db.fetch_items_by_ids_interruptible(&head_ids, token, runtime)?;

        if head_items.is_empty() && !head_ids.is_empty() && token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let head_stored: HashMap<i64, StoredItem> = head_items
            .into_iter()
            .filter_map(|item| item.id.map(|id| (id, item)))
            .collect();

        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let mut item_matches: HashMap<i64, ItemMatch> = HashMap::with_capacity(split_at);
        for fm in head {
            if let Some(item) = head_stored.get(&fm.id) {
                item_matches.insert(fm.id, SearchEngine::create_item_match(item, fm));
            }
        }

        // Remaining IDs: no DB fetch at all during search

        Ok((ids, item_matches))
    }

    /// Trigram query search using Tantivy with phrase-boost scoring
    /// Returns (ids, item_matches, total_count) where total_count is the true number of matching documents.
    ///
    /// Lazy highlighting: only the first HIGHLIGHT_BATCH_SIZE results get full highlights
    /// and are placed in the item_matches map. The rest are just IDs (no DB fetch).
    /// Swift calls `highlight_results` on scroll to fill in highlights for the rest.
    fn search_trigram_query_sync(
        db: &Database,
        indexer: &Indexer,
        search_engine: &SearchEngine,
        query: &str,
        token: &CancellationToken,
        runtime: &tokio::runtime::Handle,
    ) -> Result<(Vec<i64>, HashMap<i64, ItemMatch>, usize), ClipKittyError> {
        // Checkpoint: Check cancellation before Tantivy search
        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let (fuzzy_matches, total_count) = search_engine.search(indexer, query)?;

        if fuzzy_matches.is_empty() {
            return Ok((Vec::new(), HashMap::new(), total_count));
        }

        // Checkpoint: Check cancellation before SQLite fetch
        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        // Collect all IDs in order
        let ids: Vec<i64> = fuzzy_matches.iter().map(|m| m.id).collect();

        // Split at HIGHLIGHT_BATCH_SIZE: first batch gets full highlights
        let split_at = HIGHLIGHT_BATCH_SIZE.min(fuzzy_matches.len());
        let head = &fuzzy_matches[..split_at];

        // --- First batch: full highlight + DB fetch + create_item_match ---
        let head_ids: Vec<i64> = head.iter().map(|m| m.id).collect();
        let head_items = db.fetch_items_by_ids_interruptible(&head_ids, token, runtime)?;

        if head_items.is_empty() && !head_ids.is_empty() && token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let head_stored: HashMap<i64, StoredItem> = head_items
            .into_iter()
            .filter_map(|item| item.id.map(|id| (id, item)))
            .collect();

        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let mut item_matches: HashMap<i64, ItemMatch> = HashMap::with_capacity(split_at);
        for fm in head {
            if let Some(item) = head_stored.get(&fm.id) {
                item_matches.insert(fm.id, SearchEngine::create_item_match(item, fm));
            }
        }

        // Remaining IDs: no DB fetch at all during search

        Ok((ids, item_matches, total_count))
    }

    /// Instrumented trigram query search — returns per-stage timings.
    /// Only used by benchmarks; not exported via FFI.
    ///
    /// Mirrors the lazy-highlight split: first HIGHLIGHT_BATCH_SIZE get full
    /// highlight + StoredItem fetch, the rest are just IDs (no DB fetch).
    fn search_trigram_instrumented(
        db: &Database,
        indexer: &Indexer,
        _search_engine: &SearchEngine,
        query: &str,
    ) -> Result<SearchTimings, ClipKittyError> {
        use std::time::Instant;
        let t_total = Instant::now();

        // Stage 1: Tantivy search
        let t0 = Instant::now();
        let query_words: Vec<&str> = query.split_whitespace().collect();
        let (candidates, _total_count) = indexer.search(query.trim(), crate::search::MAX_RESULTS)?;
        let tantivy_ms = t0.elapsed().as_secs_f64() * 1000.0;
        let num_candidates = candidates.len();

        // Split at HIGHLIGHT_BATCH_SIZE
        let split_at = HIGHLIGHT_BATCH_SIZE.min(candidates.len());
        let head_cands = &candidates[..split_at];
        let num_tail = candidates.len() - split_at;

        // Stage 2: Highlighting (head only)
        let t1 = Instant::now();
        let head_matches: Vec<_> = head_cands
            .iter()
            .map(|c| crate::search::SearchEngine::highlight_candidate_pub(
                c.id, &c.content, c.timestamp, c.tantivy_score, &query_words,
            ))
            .collect();
        let highlight_ms = t1.elapsed().as_secs_f64() * 1000.0;

        // Stage 3: DB fetch for head (full StoredItem)
        let t2 = Instant::now();
        let head_ids: Vec<i64> = head_matches.iter().map(|m| m.id).collect();
        let head_items = db.fetch_items_by_ids(&head_ids)?;
        let db_fetch_head_ms = t2.elapsed().as_secs_f64() * 1000.0;

        let head_map: HashMap<i64, StoredItem> = head_items
            .into_iter()
            .filter_map(|item| item.id.map(|id| (id, item)))
            .collect();

        // Stage 4: Match generation (head only — snippet + highlight ranges)
        let t3 = Instant::now();
        let mut item_matches: HashMap<i64, ItemMatch> = HashMap::with_capacity(split_at);
        for fm in &head_matches {
            if let Some(item) = head_map.get(&fm.id) {
                item_matches.insert(fm.id, SearchEngine::create_item_match(item, fm));
            }
        }
        let match_gen_ms = t3.elapsed().as_secs_f64() * 1000.0;
        let num_highlighted = item_matches.len();

        // Stage 5: Tail is just IDs — no DB fetch needed (no-op)
        let t4 = Instant::now();
        let db_fetch_tail_ms = t4.elapsed().as_secs_f64() * 1000.0;

        let total_ms = t_total.elapsed().as_secs_f64() * 1000.0;

        Ok(SearchTimings {
            tantivy_ms,
            highlight_ms,
            db_fetch_head_ms,
            match_gen_ms,
            db_fetch_tail_ms,
            total_ms,
            num_candidates,
            num_highlighted,
            num_metadata_only: num_tail,
            num_results: num_candidates,
        })
    }

    /// Get a single stored item by ID (internal use)
    fn get_stored_item(&self, item_id: i64) -> Result<Option<StoredItem>, ClipKittyError> {
        let items = self.db.fetch_items_by_ids(&[item_id])?;
        Ok(items.into_iter().next())
    }
}

// Benchmark-only methods (not exported via FFI)
impl ClipboardStore {
    /// Run an instrumented search for benchmarking. Returns per-stage timings.
    pub async fn search_instrumented(&self, query: String) -> Result<SearchTimings, ClipKittyError> {
        let runtime = self.runtime_handle();
        let db = Arc::clone(&self.db);
        let indexer = Arc::clone(&self.indexer);
        let search_engine = Arc::clone(&self.search_engine);

        let handle = runtime.spawn_blocking(move || {
            Self::search_trigram_instrumented(&db, &indexer, &search_engine, &query)
        });

        match handle.await {
            Ok(Ok(timings)) => Ok(timings),
            Ok(Err(e)) => Err(e),
            Err(_) => Err(ClipKittyError::Cancelled),
        }
    }
}

// FFI-exported constructor (must be in standalone impl block)
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
    /// Returns ordered IDs + a HashMap of highlighted ItemMatches for the first batch.
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
                    .map(|item| item.to_clipboard_item())
            } else {
                None
            };

            let ids: Vec<i64> = items.iter().map(|m| m.item_id).collect();
            let item_matches: HashMap<i64, ItemMatch> = items
                .into_iter()
                .map(|metadata| {
                    let id = metadata.item_id;
                    (id, ItemMatch {
                        item_metadata: metadata,
                        match_data: MatchData::default(),
                    })
                })
                .collect();

            return Ok(SearchResult {
                ids,
                item_matches,
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
        let search_engine = Arc::clone(&self.search_engine);
        let query_owned = query.to_string();
        let trimmed_owned = trimmed.to_string();
        let token_clone = token.clone();

        // Spawn the blocking search work on our runtime
        // We use runtime.spawn_blocking() instead of tokio::task::spawn_blocking()
        // because UniFFI doesn't provide a tokio runtime context
        let handle = runtime.spawn_blocking(move || {
            if trimmed_owned.len() < MIN_TRIGRAM_QUERY_LEN {
                let (ids, item_matches) = Self::search_short_query_sync(&db, &search_engine, &trimmed_owned, &token_clone, &runtime_for_closure)?;
                let total_count = ids.len() as u64;
                Ok((ids, item_matches, total_count))
            } else {
                let (ids, item_matches, total_count) = Self::search_trigram_query_sync(&db, &indexer, &search_engine, &query_owned, &token_clone, &runtime_for_closure)?;
                Ok((ids, item_matches, total_count as u64))
            }
        });

        // Await the result
        match handle.await {
            Ok(Ok((ids, item_matches, total_count))) => {

                // Fetch first item's full content for preview pane
                let first_item = if let Some(&first_id) = ids.first() {
                    self.db
                        .fetch_items_by_ids(&[first_id])?
                        .into_iter()
                        .next()
                        .map(|item| item.to_clipboard_item())
                } else {
                    None
                };

                Ok(SearchResult { ids, item_matches, total_count, first_item })
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

    /// Compute highlights for items that were returned without highlights (lazy highlighting).
    /// Swift calls this as the user scrolls past the initial batch.
    fn highlight_results(&self, query: String, item_ids: Vec<i64>) -> Result<HashMap<i64, ItemMatch>, ClipKittyError> {
        let stored_items = self.db.fetch_items_by_ids(&item_ids)?;
        let query_words: Vec<&str> = query.split_whitespace().collect();

        let matches = stored_items
            .iter()
            .map(|item| {
                let id = item.id.unwrap_or(0);
                let content = item.text_content();
                let fm = SearchEngine::highlight_candidate_pub(
                    id,
                    content,
                    item.timestamp_unix,
                    0.0,
                    &query_words,
                );
                (id, SearchEngine::create_item_match(item, &fm))
            })
            .collect();

        Ok(matches)
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
        assert_eq!(result.ids.len(), 1);
        let item = &result.item_matches[&result.ids[0]];
        assert!(item.item_metadata.snippet.contains("Hello World"));
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
        assert_eq!(result.ids.len(), 1); // Only one item
    }

    #[test]
    fn test_delete_item() {
        let rt = runtime();
        let store = ClipboardStore::new_in_memory().unwrap();

        let id = store
            .save_text("To delete".to_string(), None, None)
            .unwrap();
        assert_eq!(rt.block_on(store.search("".to_string())).unwrap().ids.len(), 1);

        store.delete_item(id).unwrap();
        assert_eq!(rt.block_on(store.search("".to_string())).unwrap().ids.len(), 0);
    }

    #[test]
    fn test_search_returns_item_matches() {
        let rt = runtime();
        let store = ClipboardStore::new_in_memory().unwrap();

        store.save_text("Hello World from ClipKitty".to_string(), None, None).unwrap();
        store.save_text("Another test item".to_string(), None, None).unwrap();

        let result = rt.block_on(store.search("Hello".to_string())).unwrap();

        assert_eq!(result.ids.len(), 1);
        let item = &result.item_matches[&result.ids[0]];
        assert!(item.item_metadata.snippet.contains("Hello"));
        assert!(!item.match_data.highlights.is_empty());
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
        assert!(!result.ids.is_empty(), "Should find the link by searching 'github'");
        let first_item_match = &result.item_matches[&result.ids[0]];
        assert!(first_item_match.item_metadata.snippet.contains("github"));

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
            &store.search_engine,
            "He",
            &token,
            &runtime_handle,
        );
        assert!(matches!(result, Err(crate::interface::ClipKittyError::Cancelled)));

        // Test trigram query sync with pre-cancelled token
        let result = ClipboardStore::search_trigram_query_sync(
            &store.db,
            &store.indexer,
            &store.search_engine,
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
        assert!(!result.ids.is_empty());
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
        assert!(!result.ids.is_empty());

        // Trigram query (>= 3 chars)
        let result = store.search("Hello".to_string()).await.unwrap();
        assert!(!result.ids.is_empty());
        assert!(result.item_matches.values().all(|m|
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

        assert!(!result1.ids.is_empty());
        assert!(!result2.ids.is_empty());
        assert!(!result3.ids.is_empty());

        // Store should still be usable after concurrent access
        let result = store.search("Test".to_string()).await.unwrap();
        assert!(!result.ids.is_empty());
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
        assert!(!result.ids.is_empty());

        // Can still add and search for new items
        store.save_text("New item after aborts".to_string(), None, None).unwrap();
        let result = store.search("after aborts".to_string()).await.unwrap();
        assert!(!result.ids.is_empty());
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
        assert!(!search_result.ids.is_empty());
    }
}
