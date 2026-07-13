//! ClipboardStore - Thin UniFFI-facing facade over search/save services.

use crate::database::Database;
use crate::indexer::{IndexInspection, Indexer};
use crate::interface::{
    ClipKittyError, ClipboardItem, ClipboardStoreApi, FilePreviewSnapshot, ItemQueryFilter,
    ItemTag, ListPresentationProfile, MatchedExcerptRequest, MatchedExcerptResolution,
    PreviewPayload, RecentItemsScope, SearchOutcome, SearchResult, StoreBootstrapPlan,
};
#[cfg(feature = "sync")]
use crate::sync_bridge::{snapshot_from_stored_item_with_bookmark, RealSyncEmitter, SyncEmitter};
use crate::{match_presentation, save_service, search_service};
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Once};
use tokio::sync::Notify;
use tokio_util::sync::CancellationToken;

/// Global fallback Tokio runtime for when async functions are called outside any runtime context.
static FALLBACK_RUNTIME: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("Failed to create fallback tokio runtime")
});

static RAYON_INIT: Once = Once::new();

fn init_rayon() {
    RAYON_INIT.call_once(|| {
        let num_threads = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4);
        let rayon_threads = num_threads.saturating_sub(2).max(1);

        let _ = rayon::ThreadPoolBuilder::new()
            .num_threads(rayon_threads)
            .thread_name(|i| format!("clipkitty-rayon-{}", i))
            .start_handler(|_| {
                use thread_priority::*;
                let _ = set_current_thread_priority(ThreadPriority::Min);
            })
            .build_global();
    });
}

#[derive(uniffi::Object)]
pub struct ClipboardStore {
    db: Arc<Database>,
    indexer: Arc<Indexer>,
    analysis_cache: Arc<match_presentation::HighlightAnalysisCache>,
    #[cfg(feature = "sync")]
    sync_emitter: Arc<RealSyncEmitter>,
    /// Token for the currently running search, if any. The store allows one in-flight
    /// search: beginning a search cancels the previous one by calling cancel() on this
    /// token, so each UI surface must funnel interactive searches through a single owner.
    active_search_token: Arc<Mutex<Option<CancellationToken>>>,
}

struct SearchCompletionCell {
    terminal: Mutex<Option<Result<SearchOutcome, ClipKittyError>>>,
    notify: Notify,
}

impl SearchCompletionCell {
    fn new() -> Self {
        Self {
            terminal: Mutex::new(None),
            notify: Notify::new(),
        }
    }

    fn finish(&self, terminal: Result<SearchOutcome, ClipKittyError>) {
        *self.terminal.lock() = Some(terminal);
        self.notify.notify_waiters();
    }

    async fn wait(&self) -> Result<SearchOutcome, ClipKittyError> {
        loop {
            if let Some(terminal) = self.terminal.lock().clone() {
                return terminal;
            }
            self.notify.notified().await;
        }
    }
}

#[derive(uniffi::Object)]
pub struct SearchOperation {
    token: CancellationToken,
    completion: Arc<SearchCompletionCell>,
}

impl Drop for SearchOperation {
    fn drop(&mut self) {
        self.token.cancel();
    }
}

impl ClipboardStore {
    #[cfg(test)]
    pub(crate) fn new_in_memory() -> Result<Self, ClipKittyError> {
        init_rayon();
        let database = Database::open_in_memory().map_err(ClipKittyError::from)?;
        let indexer = Indexer::new_in_memory()?;
        #[cfg(feature = "sync")]
        let sync_emitter = Arc::new(RealSyncEmitter::new(database.pool().clone()));

        Ok(Self {
            db: Arc::new(database),
            indexer: Arc::new(indexer),
            analysis_cache: Arc::new(match_presentation::HighlightAnalysisCache::default()),
            #[cfg(feature = "sync")]
            sync_emitter,
            active_search_token: Arc::new(Mutex::new(None)),
        })
    }

    /// Expose database reference for integration tests.
    #[cfg(test)]
    pub fn db_for_test(&self) -> &Database {
        &self.db
    }

    fn runtime_handle(&self) -> tokio::runtime::Handle {
        tokio::runtime::Handle::try_current().unwrap_or_else(|_| FALLBACK_RUNTIME.handle().clone())
    }

    fn index_path_for_database(path: &Path) -> PathBuf {
        let index_dir = format!("tantivy_index_{}", crate::indexer::INDEX_VERSION);
        path.parent()
            .map(|parent| parent.join(&index_dir))
            .unwrap_or_else(|| PathBuf::from(&index_dir))
    }

    /// Best-effort removal of index directories left behind by INDEX_VERSION
    /// bumps; failures are ignored (a stale dir only costs disk space).
    fn remove_stale_index_dirs(current_index_path: &Path) {
        let Some(parent) = current_index_path.parent() else {
            return;
        };
        let Ok(entries) = std::fs::read_dir(parent) else {
            return;
        };
        for entry in entries.flatten() {
            let is_stale_index_dir = entry
                .file_name()
                .to_str()
                .is_some_and(|name| name.starts_with("tantivy_index_v"));
            let entry_path = entry.path();
            if is_stale_index_dir && entry_path != current_index_path && entry_path.is_dir() {
                let _ = std::fs::remove_dir_all(&entry_path);
            }
        }
    }

    fn open_at_path(path: &Path) -> Result<Self, ClipKittyError> {
        let db = Database::open(path).map_err(ClipKittyError::from)?;
        let index_path = Self::index_path_for_database(path);
        Self::remove_stale_index_dirs(&index_path);
        let indexer = Indexer::new(&index_path)?;
        #[cfg(feature = "sync")]
        let sync_emitter = Arc::new(RealSyncEmitter::new(db.pool().clone()));

        Ok(Self {
            db: Arc::new(db),
            indexer: Arc::new(indexer),
            analysis_cache: Arc::new(match_presentation::HighlightAnalysisCache::default()),
            #[cfg(feature = "sync")]
            sync_emitter,
            active_search_token: Arc::new(Mutex::new(None)),
        })
    }

    fn inspect_bootstrap(path: &Path) -> Result<StoreBootstrapPlan, ClipKittyError> {
        let db = Database::open(path).map_err(ClipKittyError::from)?;
        let db_count = db.count_items()?;
        let needs_rebuild = match Indexer::inspect(&Self::index_path_for_database(path))? {
            IndexInspection::Missing => db_count > 0,
            IndexInspection::RebuildRequired => true,
            // Chunked indexing means one parent item can expand to multiple index units.
            // Still rebuild if the database has content but the matching-version index is empty.
            IndexInspection::Ready { doc_count } => db_count > 0 && doc_count == 0,
        };

        if needs_rebuild {
            return Ok(StoreBootstrapPlan::RebuildIndex);
        }

        Ok(StoreBootstrapPlan::Ready)
    }

    fn rebuild_index_contents(&self) -> Result<(), ClipKittyError> {
        let items = self.db.fetch_all_items()?;
        self.indexer.delete_all_documents()?;
        use rayon::prelude::*;
        let prepared: Vec<_> = items
            .par_iter()
            .map(|item| {
                let text = item
                    .file_index_text()
                    .unwrap_or_else(|| item.text_content().to_string());
                (item.item_id.as_str(), text, item.timestamp_unix)
            })
            .collect();
        for (item_id, text, ts) in prepared {
            self.indexer.add_document(item_id, &text, ts)?;
        }
        self.indexer.commit()?;
        Ok(())
    }

    fn begin_search_operation(
        &self,
        query: String,
        filter: ItemQueryFilter,
        presentation: ListPresentationProfile,
    ) -> Arc<SearchOperation> {
        let token = CancellationToken::new();
        let completion = Arc::new(SearchCompletionCell::new());
        let operation = Arc::new(SearchOperation {
            token: token.clone(),
            completion: completion.clone(),
        });
        {
            let mut active = self.active_search_token.lock();
            if let Some(prev) = active.take() {
                prev.cancel();
            }
            *active = Some(token.clone());
        }

        let db = Arc::clone(&self.db);
        let indexer = Arc::clone(&self.indexer);
        let cache = Arc::clone(&self.analysis_cache);
        let runtime = self.runtime_handle();

        let runtime_clone = runtime.clone();
        runtime.spawn(async move {
            let result = search_service::execute_search(
                search_service::SearchContext {
                    db,
                    indexer,
                    cache,
                    runtime: runtime_clone,
                    token: token.clone(),
                    presentation,
                },
                query,
                filter,
            )
            .await;

            let terminal = match result {
                Ok(result) => Ok(SearchOutcome::Success { result }),
                Err(ClipKittyError::Cancelled) => Ok(SearchOutcome::Cancelled),
                Err(error) => Err(error),
            };
            completion.finish(terminal);
        });

        operation
    }
}

#[uniffi::export]
impl ClipboardStore {
    #[uniffi::constructor]
    pub fn new(db_path: String) -> Result<Self, ClipKittyError> {
        init_rayon();
        Self::open_at_path(&PathBuf::from(db_path))
    }

    pub fn rebuild_index(&self) -> Result<(), ClipKittyError> {
        self.rebuild_index_contents()?;
        #[cfg(feature = "sync")]
        {
            use purr_sync::store::SyncStore;
            use purr_sync::types::FLAG_INDEX_DIRTY;

            let sync = SyncStore::new(self.db.pool());
            sync.clear_index_queue()?;
            sync.set_dirty_flag(FLAG_INDEX_DIRTY, false)?;
        }
        Ok(())
    }

    pub fn prepare_for_suspend(&self) {
        if let Some(token) = self.active_search_token.lock().take() {
            token.cancel();
        }
        let _ = self.indexer.prepare_for_suspend();
        let _ = self.db.checkpoint_for_suspend();
    }

    pub fn start_search(
        &self,
        query: String,
        filter: ItemQueryFilter,
        presentation: ListPresentationProfile,
    ) -> Arc<SearchOperation> {
        self.begin_search_operation(query, filter, presentation)
    }

    /// Format an excerpt for a given presentation profile.
    /// Exposed to Swift so optimistic edit updates don't need local truncation rules.
    pub fn format_excerpt(&self, content: String, presentation: ListPresentationProfile) -> String {
        crate::search::format_excerpt(&content, presentation)
    }
}

impl ClipboardStore {
    /// Emit the appropriate sync event for an insert outcome.
    #[cfg(feature = "sync")]
    fn emit_for_insert(&self, outcome: &save_service::InsertOutcome) -> Result<(), ClipKittyError> {
        match outcome {
            save_service::InsertOutcome::Deduplicated {
                item_id,
                touched_at_unix,
                ..
            } => {
                self.sync_emitter
                    .emit_item_touched(item_id, *touched_at_unix)?;
            }
            save_service::InsertOutcome::Inserted { item_id, item, .. } => {
                let snapshot = crate::sync_bridge::snapshot_from_stored_item(item);
                self.sync_emitter.emit_item_created(item_id, snapshot)?;
            }
        }
        Ok(())
    }

    /// Look up the stable string item_id for a row ID, for use in sync emission.
    #[cfg(feature = "sync")]
    fn resolve_item_id(&self, row_id: i64) -> Result<Option<String>, ClipKittyError> {
        Ok(self.db.fetch_item_id_by_row_id(row_id)?)
    }
}

impl ClipboardStore {
    /// Resolve a string item_id to its numeric row ID, returning an error if not found.
    fn require_row_id(&self, item_id: &str) -> Result<i64, ClipKittyError> {
        self.db
            .fetch_row_id_by_item_id(item_id)?
            .ok_or_else(|| ClipKittyError::InvalidInput(format!("item not found: {item_id}")))
    }
}

#[uniffi::export]
pub fn inspect_store_bootstrap(db_path: String) -> Result<StoreBootstrapPlan, ClipKittyError> {
    init_rayon();
    ClipboardStore::inspect_bootstrap(&PathBuf::from(db_path))
}

#[uniffi::export]
#[async_trait::async_trait]
impl ClipboardStoreApi for ClipboardStore {
    fn database_size(&self) -> i64 {
        self.db.database_size().unwrap_or(0)
    }

    fn save_text(
        &self,
        text: String,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Result<String, ClipKittyError> {
        let outcome = save_service::save_text(
            &self.db,
            &self.indexer,
            text,
            source_app,
            source_app_bundle_id,
        )?;
        #[cfg(feature = "sync")]
        self.emit_for_insert(&outcome)?;
        Ok(outcome.ffi_id())
    }

    async fn search(
        &self,
        query: String,
        presentation: ListPresentationProfile,
    ) -> Result<SearchResult, ClipKittyError> {
        match self
            .begin_search_operation(query, ItemQueryFilter::All, presentation)
            .await_result()
            .await?
        {
            SearchOutcome::Success { result } => Ok(result),
            SearchOutcome::Cancelled => Err(ClipKittyError::Cancelled),
        }
    }

    async fn search_filtered(
        &self,
        query: String,
        filter: ItemQueryFilter,
        presentation: ListPresentationProfile,
    ) -> Result<SearchResult, ClipKittyError> {
        if filter == ItemQueryFilter::All {
            return self.search(query, presentation).await;
        }
        match self
            .begin_search_operation(query, filter, presentation)
            .await_result()
            .await?
        {
            SearchOutcome::Success { result } => Ok(result),
            SearchOutcome::Cancelled => Err(ClipKittyError::Cancelled),
        }
    }

    fn fetch_by_ids(&self, item_ids: Vec<String>) -> Result<Vec<ClipboardItem>, ClipKittyError> {
        let stored_items = self.db.fetch_items_by_item_ids(&item_ids)?;
        let mut items: Vec<ClipboardItem> = stored_items
            .into_iter()
            .map(|item| item.to_clipboard_item())
            .collect();
        let tags_by_id = self.db.get_tags_for_item_ids(&item_ids)?;
        for item in &mut items {
            item.item_metadata.tags = tags_by_id
                .get(&item.item_metadata.item_id)
                .cloned()
                .unwrap_or_default();
        }
        Ok(items)
    }

    fn fetch_recent_items(
        &self,
        scope: RecentItemsScope,
        limit: u32,
    ) -> Result<Vec<ClipboardItem>, ClipKittyError> {
        Ok(self
            .db
            .fetch_recent_items(scope, limit)?
            .into_iter()
            .map(|item| item.to_clipboard_item())
            .collect())
    }

    fn resolve_matched_excerpts(
        &self,
        requests: Vec<MatchedExcerptRequest>,
    ) -> Result<Vec<MatchedExcerptResolution>, ClipKittyError> {
        search_service::resolve_matched_excerpts(&self.db, &self.analysis_cache, requests)
    }

    fn load_preview_payload(
        &self,
        item_id: String,
        query: String,
    ) -> Result<Option<PreviewPayload>, ClipKittyError> {
        search_service::load_preview_payload(&self.db, &self.analysis_cache, item_id, query)
    }

    fn save_files(
        &self,
        paths: Vec<String>,
        filenames: Vec<String>,
        file_sizes: Vec<u64>,
        utis: Vec<String>,
        bookmark_data_list: Vec<Vec<u8>>,
        preview_snapshots: Vec<FilePreviewSnapshot>,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Result<String, ClipKittyError> {
        let outcome = save_service::save_files(
            &self.db,
            &self.indexer,
            paths,
            filenames,
            file_sizes,
            utis,
            bookmark_data_list,
            preview_snapshots,
            source_app,
            source_app_bundle_id,
        )?;
        #[cfg(feature = "sync")]
        self.emit_for_insert(&outcome)?;
        Ok(outcome.ffi_id())
    }

    fn save_file(
        &self,
        path: String,
        filename: String,
        file_size: u64,
        uti: String,
        bookmark_data: Vec<u8>,
        preview: FilePreviewSnapshot,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Result<String, ClipKittyError> {
        let outcome = save_service::save_file(
            &self.db,
            &self.indexer,
            path,
            filename,
            file_size,
            uti,
            bookmark_data,
            preview,
            source_app,
            source_app_bundle_id,
        )?;
        #[cfg(feature = "sync")]
        self.emit_for_insert(&outcome)?;
        Ok(outcome.ffi_id())
    }

    fn save_image(
        &self,
        image_data: Vec<u8>,
        thumbnail: Option<Vec<u8>>,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
        is_animated: bool,
    ) -> Result<String, ClipKittyError> {
        let outcome = save_service::save_image(
            &self.db,
            &self.indexer,
            image_data,
            thumbnail,
            source_app,
            source_app_bundle_id,
            is_animated,
        )?;
        #[cfg(feature = "sync")]
        self.emit_for_insert(&outcome)?;
        Ok(outcome.ffi_id())
    }

    fn update_link_metadata(
        &self,
        item_id: String,
        title: Option<String>,
        description: Option<String>,
        image_data: Option<Vec<u8>>,
    ) -> Result<(), ClipKittyError> {
        let row_id = self.require_row_id(&item_id)?;
        #[allow(unused_variables)]
        let resolved =
            save_service::update_link_metadata(&self.db, row_id, title, description, image_data)?;
        #[cfg(feature = "sync")]
        {
            let snapshot = crate::sync_bridge::link_metadata_snapshot(&resolved);
            self.sync_emitter
                .emit_link_metadata_updated(&item_id, snapshot)?;
        }
        Ok(())
    }

    fn update_image_description(
        &self,
        item_id: String,
        description: String,
    ) -> Result<(), ClipKittyError> {
        let row_id = self.require_row_id(&item_id)?;
        // Bake in the "Image: " label once, up front, so the sync event and the
        // local store record the identical prefixed description across devices.
        let description = crate::interface::format_image_description(&description);
        #[cfg(feature = "sync")]
        self.sync_emitter
            .emit_image_description_updated(&item_id, &description)?;

        #[allow(unused_variables)]
        let reindex =
            save_service::update_image_description(&self.db, &self.indexer, row_id, description)?;

        #[cfg(feature = "sync")]
        if matches!(reindex, save_service::ReindexOutcome::IndexFailed) {
            let _ = self.sync_emitter.set_index_dirty();
        }
        Ok(())
    }

    fn update_text_item(&self, item_id: String, text: String) -> Result<(), ClipKittyError> {
        let row_id = self.require_row_id(&item_id)?;
        #[cfg(feature = "sync")]
        self.sync_emitter.emit_text_edited(&item_id, &text)?;

        #[allow(unused_variables)]
        let reindex = save_service::update_text_item(&self.db, &self.indexer, row_id, text)?;

        #[cfg(feature = "sync")]
        if matches!(reindex, save_service::ReindexOutcome::IndexFailed) {
            let _ = self.sync_emitter.set_index_dirty();
        }
        Ok(())
    }

    fn update_timestamp(&self, item_id: String) -> Result<(), ClipKittyError> {
        let row_id = self.require_row_id(&item_id)?;
        #[allow(unused_variables)]
        let timestamp_unix = match save_service::update_timestamp(&self.db, &self.indexer, row_id)?
        {
            save_service::TouchOutcome::Indexed { timestamp_unix } => timestamp_unix,
            save_service::TouchOutcome::IndexFailed { timestamp_unix } => {
                #[cfg(feature = "sync")]
                let _ = self.sync_emitter.set_index_dirty();
                timestamp_unix
            }
        };

        #[cfg(feature = "sync")]
        self.sync_emitter
            .emit_item_touched(&item_id, timestamp_unix)?;
        Ok(())
    }

    fn add_tag(&self, item_id: String, tag: ItemTag) -> Result<(), ClipKittyError> {
        let row_id = self.require_row_id(&item_id)?;
        #[cfg(feature = "sync")]
        self.sync_emitter.emit_bookmark_set(&item_id)?;

        save_service::add_tag(&self.db, row_id, tag)
    }

    fn remove_tag(&self, item_id: String, tag: ItemTag) -> Result<(), ClipKittyError> {
        let row_id = self.require_row_id(&item_id)?;
        #[cfg(feature = "sync")]
        self.sync_emitter.emit_bookmark_cleared(&item_id)?;

        save_service::remove_tag(&self.db, row_id, tag)
    }

    fn delete_item(&self, item_id: String) -> Result<(), ClipKittyError> {
        let row_id = self.require_row_id(&item_id)?;
        #[cfg(feature = "sync")]
        self.sync_emitter.emit_item_deleted(&item_id)?;

        save_service::delete_item(&self.db, &self.indexer, row_id)
    }

    fn clear(&self) -> Result<(), ClipKittyError> {
        #[cfg(feature = "sync")]
        for row_id in self.db.fetch_all_item_ids()? {
            if let Some(stable_id) = self.resolve_item_id(row_id)? {
                self.sync_emitter.emit_item_deleted(&stable_id)?;
            }
        }

        save_service::clear(&self.db, &self.indexer)
    }

    fn prune_to_size(&self, max_bytes: i64, keep_ratio: f64) -> Result<u64, ClipKittyError> {
        let outcome = save_service::prune_to_size(&self.db, &self.indexer, max_bytes, keep_ratio)?;

        #[cfg(feature = "sync")]
        for item_id in &outcome.deleted_ids {
            self.sync_emitter.emit_item_deleted(item_id)?;
        }

        Ok(outcome.bytes_freed)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Sync internals — not exposed via FFI
// ═══════════════════════════════════════════════════════════════════════════════

#[cfg(feature = "sync")]
impl ClipboardStore {
    fn materialize_forked_snapshot(
        &self,
        snapshot: &purr_sync::types::ItemSnapshotData,
    ) -> Result<String, ClipKittyError> {
        use crate::sync_bridge::stored_item_from_snapshot;

        let fork_item_id = uuid::Uuid::new_v4().to_string();
        let item = stored_item_from_snapshot(fork_item_id.clone(), snapshot)
            .map_err(ClipKittyError::InvalidInput)?;
        self.queue_search_upsert(&fork_item_id)?;
        let row_id = self.db.insert_item(&item)?;
        if snapshot.is_bookmarked {
            self.db
                .add_tag(row_id, crate::interface::ItemTag::Bookmark)?;
        }
        self.sync_emitter
            .emit_item_created(&fork_item_id, snapshot.clone())?;
        Ok(fork_item_id)
    }

    fn queue_search_upsert(&self, item_id: &str) -> Result<(), ClipKittyError> {
        use purr_sync::store::SyncStore;
        use purr_sync::types::FLAG_INDEX_DIRTY;

        let sync = SyncStore::new(self.db.pool());
        sync.enqueue_index_upsert(item_id)?;
        sync.set_dirty_flag(FLAG_INDEX_DIRTY, true)?;
        Ok(())
    }

    fn queue_search_delete(&self, item_id: &str) -> Result<(), ClipKittyError> {
        use purr_sync::store::SyncStore;
        use purr_sync::types::FLAG_INDEX_DIRTY;

        let sync = SyncStore::new(self.db.pool());
        sync.enqueue_index_delete(item_id)?;
        sync.set_dirty_flag(FLAG_INDEX_DIRTY, true)?;
        Ok(())
    }

    /// Materialize a sync aggregate into the local items table.
    ///
    /// For Live aggregates: upsert into items table (insert if new, update if exists).
    /// For Tombstoned aggregates: delete from items table.
    /// Returns the current local row ID when the item remains live.
    fn materialize_aggregate(
        &self,
        item_id: &str,
        aggregate: &purr_sync::types::ItemAggregate,
        index_dirty: bool,
        fallback_local_item_id: Option<i64>,
    ) -> Result<Option<i64>, ClipKittyError> {
        use crate::sync_bridge::stored_item_from_snapshot;
        use purr_sync::store::{ProjectionState, SyncStore};
        use purr_sync::types::ItemAggregate;

        let sync = SyncStore::new(self.db.pool());

        // Resolve local row ID: look up by item_id in the items table,
        // falling back to the caller-provided hint.
        let local_item_id = self
            .db
            .fetch_row_id_by_item_id(item_id)?
            .or(fallback_local_item_id);

        match aggregate {
            ItemAggregate::Live(live) => {
                let item = stored_item_from_snapshot(item_id.to_string(), &live.snapshot)
                    .map_err(ClipKittyError::InvalidInput)?;

                if index_dirty {
                    self.queue_search_upsert(item_id)?;
                }

                if let Some(local_id) = local_item_id {
                    self.db.replace_item_preserving_id(local_id, &item)?;
                    if live.snapshot.is_bookmarked {
                        self.db
                            .add_tag(local_id, crate::interface::ItemTag::Bookmark)?;
                    } else {
                        self.db
                            .remove_tag(local_id, crate::interface::ItemTag::Bookmark)?;
                    }
                    sync.upsert_projection(
                        item_id,
                        &ProjectionState::Materialized {
                            versions: live.versions,
                        },
                    )?;
                    return Ok(Some(local_id));
                }

                // No existing local item — insert fresh.
                let new_id = self.db.insert_item(&item)?;
                if live.snapshot.is_bookmarked {
                    self.db
                        .add_tag(new_id, crate::interface::ItemTag::Bookmark)?;
                }
                sync.upsert_projection(
                    item_id,
                    &ProjectionState::Materialized {
                        versions: live.versions,
                    },
                )?;
                Ok(Some(new_id))
            }
            ItemAggregate::Tombstoned(tomb) => {
                if index_dirty {
                    self.queue_search_delete(item_id)?;
                }
                if let Some(local_id) = local_item_id {
                    self.db.delete_item(local_id)?;
                }
                sync.upsert_projection(
                    item_id,
                    &ProjectionState::Tombstoned {
                        versions: tomb.versions,
                    },
                )?;
                Ok(None)
            }
        }
    }

    /// Re-materialize the current sync snapshot for an item into the read model.
    ///
    /// This lets duplicate/already-applied remote records heal the read model if
    /// sync state was stored successfully but a prior materialization failed.
    fn materialize_current_sync_state(
        &self,
        item_id: &str,
        index_dirty: bool,
        fallback_local_item_id: Option<i64>,
    ) -> Result<Option<i64>, ClipKittyError> {
        use purr_sync::store::SyncStore;

        let sync = SyncStore::new(self.db.pool());
        let Some(_) = sync.fetch_projection(item_id)? else {
            return Ok(self
                .db
                .fetch_row_id_by_item_id(item_id)?
                .or(fallback_local_item_id));
        };
        let snapshot = sync.fetch_snapshot(item_id)?.ok_or_else(|| {
            ClipKittyError::DataInconsistency(format!(
                "sync projection for item `{item_id}` is missing snapshot state"
            ))
        })?;

        self.materialize_aggregate(
            item_id,
            &snapshot.aggregate,
            index_dirty,
            fallback_local_item_id,
        )
    }

    fn local_snapshots_for_full_resync(
        &self,
    ) -> Result<Vec<purr_sync::snapshot::ItemSnapshot>, ClipKittyError> {
        use purr_sync::snapshot::ItemSnapshot;
        use purr_sync::store::SyncStore;
        use purr_sync::types::{ItemAggregate, LiveItemState, VersionVector, SYNC_SCHEMA_VERSION};

        let items = self.db.fetch_all_items()?;
        let item_ids: Vec<String> = items.iter().map(|item| item.item_id.clone()).collect();
        let tags_by_item_id = self.db.get_tags_for_item_ids(&item_ids)?;
        let sync = SyncStore::new(self.db.pool());

        items
            .into_iter()
            .map(|item| {
                let item_id = item.item_id.clone();
                let existing_snapshot = sync.fetch_snapshot(&item_id)?;
                let is_bookmarked = tags_by_item_id
                    .get(&item_id)
                    .map(|tags| tags.contains(&ItemTag::Bookmark))
                    .unwrap_or(false);

                let mut versions = match existing_snapshot
                    .as_ref()
                    .map(|snapshot| &snapshot.aggregate)
                {
                    Some(ItemAggregate::Live(live)) => live.versions,
                    Some(ItemAggregate::Tombstoned(_)) | None => VersionVector {
                        content: 1,
                        bookmark: if is_bookmarked { 1 } else { 0 },
                        existence: 1,
                        touch: 1,
                        metadata: 1,
                    },
                };
                if is_bookmarked && versions.bookmark == 0 {
                    versions.bookmark = 1;
                }

                let aggregate = ItemAggregate::Live(LiveItemState {
                    snapshot: snapshot_from_stored_item_with_bookmark(&item, is_bookmarked),
                    versions,
                });
                let snapshot = ItemSnapshot {
                    item_id: item_id.clone(),
                    snapshot_revision: existing_snapshot
                        .as_ref()
                        .map(|snapshot| snapshot.snapshot_revision.max(1))
                        .unwrap_or(1),
                    schema_version: SYNC_SCHEMA_VERSION,
                    covers_through_event: existing_snapshot
                        .and_then(|snapshot| snapshot.covers_through_event),
                    aggregate,
                    uploaded: false,
                    uploaded_at: None,
                };

                Ok(snapshot)
            })
            .collect()
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Sync FFI — methods exposed to Swift SyncEngine
// ═══════════════════════════════════════════════════════════════════════════════

#[cfg(feature = "sync")]
#[uniffi::export]
impl ClipboardStore {
    /// Set the device ID used for locally-originated sync events.
    /// Called by SyncEngine.start() with the stable UUID from UserDefaults.
    pub fn set_sync_device_id(&self, device_id: String) {
        self.sync_emitter.set_device_id(device_id);
    }

    /// Fetch pending local events that need uploading to CloudKit.
    pub fn pending_local_events(
        &self,
    ) -> Result<Vec<crate::interface::SyncEventRecord>, ClipKittyError> {
        use crate::interface::SyncEventRecord;
        use purr_sync::store::SyncStore;

        let sync = SyncStore::new(self.db.pool());
        let events = sync.fetch_pending_upload_events()?;
        Ok(events
            .into_iter()
            .map(|e| {
                let payload_type = e.payload_type().to_string();
                let payload_data = e.payload_data();
                SyncEventRecord {
                    event_id: e.event_id,
                    item_id: e.item_id,
                    origin_device_id: e.origin_device_id,
                    schema_version: e.schema_version,
                    recorded_at: e.recorded_at,
                    payload_type,
                    payload_data,
                }
            })
            .collect())
    }

    /// Fetch compacted snapshots that need uploading to CloudKit.
    pub fn pending_snapshot_records(
        &self,
    ) -> Result<Vec<crate::interface::SyncSnapshotRecord>, ClipKittyError> {
        use crate::interface::SyncSnapshotRecord;
        use purr_sync::store::SyncStore;

        let sync = SyncStore::new(self.db.pool());
        let snapshots = sync.fetch_pending_upload_snapshots()?;
        Ok(snapshots
            .into_iter()
            .map(|s| {
                let aggregate_data = s.aggregate_data();
                SyncSnapshotRecord {
                    item_id: s.item_id,
                    snapshot_revision: s.snapshot_revision,
                    schema_version: s.schema_version,
                    covers_through_event: s.covers_through_event,
                    aggregate_data,
                }
            })
            .collect())
    }

    /// Mark events as uploaded after CloudKit confirms receipt.
    pub fn mark_events_uploaded(&self, event_ids: Vec<String>) -> Result<(), ClipKittyError> {
        use purr_sync::store::SyncStore;

        let sync = SyncStore::new(self.db.pool());
        let refs: Vec<&str> = event_ids.iter().map(|s| s.as_str()).collect();
        sync.mark_events_uploaded(&refs)?;
        Ok(())
    }

    /// Mark a snapshot as uploaded to CloudKit.
    pub fn mark_snapshot_uploaded(&self, item_id: String) -> Result<(), ClipKittyError> {
        use purr_sync::store::SyncStore;

        let sync = SyncStore::new(self.db.pool());
        sync.mark_snapshot_uploaded(&item_id)?;
        Ok(())
    }

    /// Apply a batch of remote events and snapshots.
    /// Returns a structured outcome indicating whether it's safe to advance
    /// the CloudKit zone change token.
    pub fn apply_remote_batch(
        &self,
        event_records: Vec<crate::interface::SyncEventRecord>,
        snapshot_records: Vec<crate::interface::SyncSnapshotRecord>,
    ) -> Result<crate::interface::SyncDownloadBatchOutcome, ClipKittyError> {
        use crate::interface::SyncDownloadBatchOutcome;
        use purr_sync::event::ItemEvent;
        use purr_sync::replay;
        use purr_sync::snapshot::ItemSnapshot;
        use std::collections::HashMap;

        let mut known_local_item_ids: HashMap<String, Option<i64>> = HashMap::new();
        for item_id in snapshot_records
            .iter()
            .map(|record| record.item_id.as_str())
            .chain(event_records.iter().map(|record| record.item_id.as_str()))
        {
            known_local_item_ids
                .entry(item_id.to_string())
                .or_insert_with(|| self.db.fetch_row_id_by_item_id(item_id).ok().flatten());
        }

        // Apply snapshots first.
        let mut snapshots_applied: usize = 0;
        for record in &snapshot_records {
            let snapshot = ItemSnapshot::from_stored(
                record.item_id.clone(),
                record.snapshot_revision,
                record.schema_version,
                record.covers_through_event.clone(),
                &record.aggregate_data,
                true,
                None,
            )
            .map_err(|e| ClipKittyError::InvalidInput(e))?;

            let item_id = snapshot.item_id.clone();
            let applied = replay::apply_remote_snapshots(self.db.pool(), &[snapshot])?;
            let local_item_id = self.materialize_current_sync_state(
                &item_id,
                true,
                known_local_item_ids.get(&item_id).copied().flatten(),
            )?;
            known_local_item_ids.insert(item_id, local_item_id);
            if applied > 0 {
                snapshots_applied += 1;
            }
        }

        // Convert and apply events as a batch.
        let events: Vec<ItemEvent> = event_records
            .iter()
            .map(|r| {
                ItemEvent::from_stored(
                    r.event_id.clone(),
                    r.item_id.clone(),
                    r.origin_device_id.clone(),
                    r.schema_version,
                    r.recorded_at,
                    &r.payload_type,
                    &r.payload_data,
                )
                .map_err(|e| ClipKittyError::InvalidInput(e))
            })
            .collect::<Result<Vec<_>, _>>()?;

        let mut batch_result = replay::apply_remote_event_batch(self.db.pool(), &events)?;

        // Materialize Applied events into the read model.
        // Re-fetch the applied events' aggregates from the sync store.
        for event_record in &event_records {
            match self.materialize_current_sync_state(
                &event_record.item_id,
                true,
                known_local_item_ids
                    .get(&event_record.item_id)
                    .copied()
                    .flatten(),
            ) {
                Ok(local_item_id) => {
                    known_local_item_ids.insert(event_record.item_id.clone(), local_item_id);
                }
                Err(_) => {
                    batch_result.materialization_failures += 1;
                }
            }
        }

        // Handle fork plans.
        for (_original_gid, plan) in &batch_result.fork_plans {
            let _ = self.materialize_forked_snapshot(&plan.forked_snapshot)?;
        }

        // Build the download outcome.
        let outcome = batch_result.download_outcome(snapshots_applied);
        Ok(match outcome {
            purr_sync::types::DownloadBatchOutcome::Applied {
                events_applied,
                snapshots_applied,
            } => SyncDownloadBatchOutcome::Applied {
                events_applied: events_applied as u64,
                snapshots_applied: snapshots_applied as u64,
            },
            purr_sync::types::DownloadBatchOutcome::PartialFailure {
                applied_count,
                failed_count,
                should_retry,
            } => SyncDownloadBatchOutcome::PartialFailure {
                applied_count: applied_count as u64,
                failed_count: failed_count as u64,
                should_retry,
            },
            purr_sync::types::DownloadBatchOutcome::FullResyncRequired => {
                SyncDownloadBatchOutcome::FullResyncRequired
            }
        })
    }

    /// Apply a single remote event received from CloudKit.
    ///
    /// When an event is Applied, the local items table is updated to reflect
    /// the new state so the app's read model stays in sync.
    pub fn apply_remote_event(
        &self,
        record: crate::interface::SyncEventRecord,
    ) -> Result<crate::interface::SyncApplyOutcome, ClipKittyError> {
        use crate::interface::SyncApplyOutcome;
        use purr_sync::event::ItemEvent;
        use purr_sync::replay;
        use purr_sync::types::{ApplyResult, IgnoreReason};

        let event = ItemEvent::from_stored(
            record.event_id,
            record.item_id.clone(),
            record.origin_device_id,
            record.schema_version,
            record.recorded_at,
            &record.payload_type,
            &record.payload_data,
        )
        .map_err(|e| ClipKittyError::InvalidInput(e))?;

        let fallback_local_item_id = self.db.fetch_row_id_by_item_id(&record.item_id)?;
        let result = replay::apply_remote_event(self.db.pool(), &event)?;

        match &result {
            ApplyResult::Applied(_) => {
                let _ = self.materialize_current_sync_state(
                    &record.item_id,
                    true,
                    fallback_local_item_id,
                )?;
                Ok(SyncApplyOutcome::Applied)
            }
            ApplyResult::Ignored(IgnoreReason::AlreadyApplied) => {
                let _ = self.materialize_current_sync_state(
                    &record.item_id,
                    true,
                    fallback_local_item_id,
                )?;
                Ok(SyncApplyOutcome::Ignored)
            }
            ApplyResult::Ignored(_) => Ok(SyncApplyOutcome::Ignored),
            ApplyResult::Deferred(_) => Ok(SyncApplyOutcome::Deferred),
            ApplyResult::Forked(plan) => {
                let _ = self.materialize_forked_snapshot(&plan.forked_snapshot)?;

                Ok(SyncApplyOutcome::Forked {
                    forked_snapshot_data: serde_json::to_string(&plan.forked_snapshot)
                        .unwrap_or_default(),
                })
            }
        }
    }

    /// Apply a remote snapshot received from CloudKit.
    /// Materializes the snapshot into the read model (items table + index).
    pub fn apply_remote_snapshot(
        &self,
        record: crate::interface::SyncSnapshotRecord,
    ) -> Result<bool, ClipKittyError> {
        use purr_sync::replay;
        use purr_sync::snapshot::ItemSnapshot;

        let snapshot = ItemSnapshot::from_stored(
            record.item_id,
            record.snapshot_revision,
            record.schema_version,
            record.covers_through_event,
            &record.aggregate_data,
            true,
            None,
        )
        .map_err(|e| ClipKittyError::InvalidInput(e))?;

        let item_id = snapshot.item_id.clone();
        let fallback_local_item_id = self.db.fetch_row_id_by_item_id(&item_id)?;
        let applied = replay::apply_remote_snapshots(self.db.pool(), &[snapshot])?;
        let _ = self.materialize_current_sync_state(&item_id, true, fallback_local_item_id)?;
        Ok(applied > 0)
    }

    /// Run compaction and retention for all items.
    pub fn run_compaction(&self) -> Result<crate::interface::CompactionResult, ClipKittyError> {
        use crate::interface::CompactionResult;
        use purr_sync::compactor;

        let items_compacted = compactor::compact_all(self.db.pool())? as u64;
        // Old compacted events stay local until CloudKit deletion is confirmed so
        // event cleanup and dedup pruning share one authoritative handoff.
        let events_purged = 0;
        let tombstones_purged = compactor::purge_tombstone_snapshots(self.db.pool())? as u64;

        Ok(CompactionResult {
            items_compacted,
            events_purged,
            tombstones_purged,
        })
    }

    /// Perform a full resync from the provided snapshots.
    /// Reconciles CloudKit's explicit live/tombstoned states with local items.
    pub fn full_resync(
        &self,
        snapshot_records: Vec<crate::interface::SyncSnapshotRecord>,
    ) -> Result<u64, ClipKittyError> {
        Ok(self
            .full_resync_with_tail(snapshot_records, Vec::new())?
            .checkpoints_applied)
    }

    /// Perform a full resync from checkpoints and tail events.
    /// Clears sync state, applies checkpoints, replays tail events,
    /// and materializes all live items into the read model.
    pub fn full_resync_with_tail(
        &self,
        snapshot_records: Vec<crate::interface::SyncSnapshotRecord>,
        tail_event_records: Vec<crate::interface::SyncEventRecord>,
    ) -> Result<crate::interface::SyncFullResyncResult, ClipKittyError> {
        use crate::interface::SyncFullResyncResult;
        use purr_sync::event::ItemEvent;
        use purr_sync::replay;
        use purr_sync::snapshot::ItemSnapshot;
        use purr_sync::store::SyncStore;
        use std::collections::HashSet;

        let local_snapshots_before_resync = self.local_snapshots_for_full_resync()?;

        let remote_snapshots: Vec<ItemSnapshot> = snapshot_records
            .into_iter()
            .map(|r| {
                ItemSnapshot::from_stored(
                    r.item_id,
                    r.snapshot_revision,
                    r.schema_version,
                    r.covers_through_event,
                    &r.aggregate_data,
                    true,
                    None,
                )
                .map_err(|e| ClipKittyError::InvalidInput(e))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let remote_item_ids: HashSet<String> = remote_snapshots
            .iter()
            .map(|snapshot| snapshot.item_id.clone())
            .collect();
        let mut local_base_snapshots: Vec<ItemSnapshot> = local_snapshots_before_resync
            .into_iter()
            .filter(|snapshot| !remote_item_ids.contains(&snapshot.item_id))
            .map(|mut snapshot| {
                // Local bases are not CloudKit checkpoints. They exist so tail
                // events with explicit item IDs can apply, while plain absence
                // from CloudKit still cannot delete local data.
                snapshot.covers_through_event = None;
                snapshot
            })
            .collect();
        let local_base_count = local_base_snapshots.len();
        let mut resync_snapshots = remote_snapshots;
        resync_snapshots.append(&mut local_base_snapshots);

        let tail_events: Vec<ItemEvent> = tail_event_records
            .into_iter()
            .map(|r| {
                ItemEvent::from_stored(
                    r.event_id,
                    r.item_id,
                    r.origin_device_id,
                    r.schema_version,
                    r.recorded_at,
                    &r.payload_type,
                    &r.payload_data,
                )
                .map_err(|e| ClipKittyError::InvalidInput(e))
            })
            .collect::<Result<Vec<_>, _>>()?;

        let mut result = replay::full_resync(self.db.pool(), &resync_snapshots, &tail_events)?;
        result.checkpoints_applied = result.checkpoints_applied.saturating_sub(local_base_count);

        // CloudKit only deletes local data via explicit tombstone snapshots/events.
        // Absence from the full feed means "missing remote proof", not "deleted".
        let sync = SyncStore::new(self.db.pool());
        let all_snapshots = sync.fetch_all_snapshots()?;
        for snapshot in &all_snapshots {
            let _ =
                self.materialize_aggregate(&snapshot.item_id, &snapshot.aggregate, true, None)?;
        }
        for (_original_item_id, plan) in &result.fork_plans {
            let _ = self.materialize_forked_snapshot(&plan.forked_snapshot)?;
        }

        Ok(SyncFullResyncResult {
            checkpoints_applied: result.checkpoints_applied as u64,
            tail_events_applied: result.tail_events_applied as u64,
            tail_events_ignored: result.tail_events_ignored as u64,
            tail_events_deferred: result.tail_events_deferred as u64,
            tail_events_forked: result.tail_events_forked as u64,
        })
    }

    /// Get the current sync device state.
    pub fn get_sync_device_state(
        &self,
        device_id: String,
    ) -> Result<crate::interface::SyncDeviceState, ClipKittyError> {
        use crate::interface::SyncDeviceState;
        use purr_sync::store::SyncStore;
        use purr_sync::types::{FLAG_INDEX_DIRTY, FLAG_NEEDS_FULL_RESYNC};

        let sync = SyncStore::new(self.db.pool());
        let token = sync.fetch_zone_change_token(&device_id)?;
        let needs_resync = sync.get_dirty_flag(FLAG_NEEDS_FULL_RESYNC)?;
        let index_dirty =
            sync.get_dirty_flag(FLAG_INDEX_DIRTY)? || sync.count_index_queue_entries()? > 0;

        Ok(SyncDeviceState {
            device_id,
            zone_change_token: token,
            needs_full_resync: needs_resync,
            index_dirty,
        })
    }

    /// Update the device's zone change token after a successful fetch.
    pub fn update_zone_change_token(
        &self,
        device_id: String,
        token: Option<Vec<u8>>,
    ) -> Result<(), ClipKittyError> {
        use purr_sync::store::SyncStore;

        let sync = SyncStore::new(self.db.pool());
        sync.upsert_device_state(&device_id, token.as_deref())?;
        Ok(())
    }

    /// Fetch event IDs eligible for CloudKit deletion.
    /// Only returns events that are compacted, old, AND covered by an uploaded checkpoint.
    pub fn purgeable_cloud_event_ids(
        &self,
        max_age_days: u32,
    ) -> Result<Vec<String>, ClipKittyError> {
        use purr_sync::store::SyncStore;

        let threshold = chrono::Utc::now().timestamp() - (max_age_days as i64 * 86400);
        let sync = SyncStore::new(self.db.pool());
        let ids = sync.fetch_checkpoint_safe_purgeable_events(threshold)?;
        Ok(ids)
    }

    /// Delete local event records after their CloudKit counterparts have been deleted.
    pub fn purge_cloud_events(&self, event_ids: Vec<String>) -> Result<u64, ClipKittyError> {
        use purr_sync::store::SyncStore;

        let sync = SyncStore::new(self.db.pool());
        let refs: Vec<&str> = event_ids.iter().map(|s| s.as_str()).collect();
        let count = sync.delete_events_and_dedup_by_ids(&refs)?;
        Ok(count as u64)
    }

    /// Clear the index_dirty flag (after a successful rebuild).
    pub fn clear_index_dirty_flag(&self) -> Result<(), ClipKittyError> {
        use purr_sync::store::SyncStore;
        use purr_sync::types::FLAG_INDEX_DIRTY;

        let sync = SyncStore::new(self.db.pool());
        if sync.count_index_queue_entries()? == 0 {
            sync.set_dirty_flag(FLAG_INDEX_DIRTY, false)?;
        }
        Ok(())
    }

    /// Enqueue every live item for derived search-index catch-up.
    pub fn enqueue_full_index_rebuild(&self) -> Result<u64, ClipKittyError> {
        use purr_sync::store::SyncStore;

        let items = self.db.fetch_all_items()?;
        let item_ids: Vec<String> = items.into_iter().map(|item| item.item_id).collect();
        let sync = SyncStore::new(self.db.pool());
        sync.replace_index_queue_with_full_rebuild(&item_ids)?;
        Ok(item_ids.len() as u64)
    }

    /// Process a bounded number of queued search-index updates.
    pub fn process_index_queue(
        &self,
        max_items: u32,
    ) -> Result<crate::interface::IndexMaintenanceOutcome, ClipKittyError> {
        use crate::interface::IndexMaintenanceOutcome;
        use purr_sync::store::SyncStore;
        use purr_sync::types::{IndexQueueEntry, FLAG_INDEX_DIRTY};

        let sync = SyncStore::new(self.db.pool());
        if max_items == 0 {
            let remaining = sync.count_index_queue_entries()?;
            sync.set_dirty_flag(FLAG_INDEX_DIRTY, remaining > 0)?;
            if remaining == 0 {
                return Ok(IndexMaintenanceOutcome::Completed { processed: 0 });
            }
            return Ok(IndexMaintenanceOutcome::MoreRemaining {
                processed: 0,
                remaining: remaining as u64,
            });
        }

        let entries = sync.fetch_index_queue(max_items as usize)?;
        if entries.is_empty() {
            sync.set_dirty_flag(FLAG_INDEX_DIRTY, false)?;
            return Ok(IndexMaintenanceOutcome::Completed { processed: 0 });
        }

        let mut processed_queue_keys = Vec::with_capacity(entries.len());
        for entry in &entries {
            match entry {
                IndexQueueEntry::Reset => {
                    self.indexer.delete_all_documents()?;
                }
                IndexQueueEntry::Upsert { item_id } => {
                    let item = self
                        .db
                        .fetch_items_by_item_ids(&[item_id.clone()])?
                        .into_iter()
                        .next();
                    if let Some(item) = item {
                        let text = item
                            .file_index_text()
                            .unwrap_or_else(|| item.text_content().to_string());
                        self.indexer
                            .add_document(&item.item_id, &text, item.timestamp_unix)?;
                    } else {
                        self.indexer.delete_document(item_id)?;
                    }
                }
                IndexQueueEntry::Delete { item_id } => {
                    self.indexer.delete_document(item_id)?;
                }
            }
            processed_queue_keys.push(entry.queue_key());
        }

        self.indexer.commit()?;
        sync.remove_index_queue_entries(&processed_queue_keys)?;
        let remaining = sync.count_index_queue_entries()?;
        if remaining == 0 {
            sync.set_dirty_flag(FLAG_INDEX_DIRTY, false)?;
            return Ok(IndexMaintenanceOutcome::Completed {
                processed: processed_queue_keys.len() as u64,
            });
        }

        sync.set_dirty_flag(FLAG_INDEX_DIRTY, true)?;
        Ok(IndexMaintenanceOutcome::MoreRemaining {
            processed: processed_queue_keys.len() as u64,
            remaining: remaining as u64,
        })
    }
}

#[uniffi::export]
impl SearchOperation {
    pub fn cancel(&self) {
        self.token.cancel();
    }

    pub async fn await_result(&self) -> Result<SearchOutcome, ClipKittyError> {
        self.completion.wait().await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::StoredItem;

    fn insert_indexed_text_with_timestamp(
        store: &ClipboardStore,
        content: &str,
        timestamp_unix: i64,
    ) -> StoredItem {
        let mut item = StoredItem::new_text(content.to_string(), None, None);
        item.timestamp_unix = timestamp_unix;
        let row_id = store.db.insert_item(&item).unwrap();
        item.id = Some(row_id);
        store
            .indexer
            .add_document(&item.item_id, item.content.text_content(), timestamp_unix)
            .unwrap();
        item
    }

    #[test]
    fn index_version_v8_dir_name() {
        // Pins the v8 migration trigger ("Image: " prefix baked into image
        // descriptions): a revert of INDEX_VERSION would silently reuse an index
        // built from the un-prefixed descriptions.
        let path = ClipboardStore::index_path_for_database(Path::new("/tmp/clipkitty/test.db"));
        assert!(
            path.ends_with("tantivy_index_v8"),
            "expected v8 index dir, got {path:?}"
        );
    }

    #[test]
    fn open_at_path_sweeps_stale_index_dirs() {
        let temp = tempfile::tempdir().unwrap();
        let db_path = temp.path().join("test.db");
        let stale_dir = temp.path().join("tantivy_index_v6");
        std::fs::create_dir_all(&stale_dir).unwrap();

        let _store = ClipboardStore::open_at_path(&db_path).unwrap();

        assert!(!stale_dir.exists(), "stale v6 index dir should be removed");
        assert!(ClipboardStore::index_path_for_database(&db_path).exists());
    }

    #[test]
    fn test_round_trip_save_and_fetch() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let id = store.save_text("hello world".into(), None, None).unwrap();
        assert!(!id.is_empty());

        let items = store.fetch_by_ids(vec![id]).unwrap();
        assert_eq!(items.len(), 1);
    }

    #[test]
    fn test_dedup_returns_empty_string() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let id = store.save_text("hello world".into(), None, None).unwrap();
        assert!(!id.is_empty());

        let dup = store.save_text("hello world".into(), None, None).unwrap();
        assert!(dup.is_empty());
    }

    #[cfg(feature = "sync")]
    #[test]
    fn queued_full_index_rebuild_resets_stale_index_documents() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let stale = insert_indexed_text_with_timestamp(&store, "stale search unit", 1000);
        store.indexer.commit().unwrap();
        assert_eq!(store.indexer.num_docs(), 1);

        store.db.delete_item(stale.id.unwrap()).unwrap();

        assert_eq!(store.enqueue_full_index_rebuild().unwrap(), 0);
        let outcome = store.process_index_queue(64).unwrap();
        assert!(matches!(
            outcome,
            crate::interface::IndexMaintenanceOutcome::Completed { processed: 1 }
        ));
        assert_eq!(store.indexer.num_docs(), 0);
    }

    #[cfg(feature = "sync")]
    #[test]
    fn queued_full_index_rebuild_processes_reset_before_live_upserts() {
        let store = ClipboardStore::new_in_memory().unwrap();
        insert_indexed_text_with_timestamp(&store, "live search unit", 1000);
        store.indexer.commit().unwrap();
        assert_eq!(store.indexer.num_docs(), 1);

        assert_eq!(store.enqueue_full_index_rebuild().unwrap(), 1);
        let reset_pass = store.process_index_queue(1).unwrap();
        assert!(matches!(
            reset_pass,
            crate::interface::IndexMaintenanceOutcome::MoreRemaining {
                processed: 1,
                remaining: 1
            }
        ));
        assert_eq!(store.indexer.num_docs(), 0);

        let upsert_pass = store.process_index_queue(1).unwrap();
        assert!(matches!(
            upsert_pass,
            crate::interface::IndexMaintenanceOutcome::Completed { processed: 1 }
        ));
        assert_eq!(store.indexer.num_docs(), 1);
    }

    #[tokio::test]
    async fn update_timestamp_refreshes_search_ranking_timestamp() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let now = chrono::Utc::now().timestamp();
        let first = insert_indexed_text_with_timestamp(&store, "this is a test 1", now - 10);
        let second = insert_indexed_text_with_timestamp(&store, "this is a test 2", now - 5);
        store.indexer.commit().unwrap();

        let initial = store
            .search(
                "this is a test".to_string(),
                ListPresentationProfile::CompactRow,
            )
            .await
            .unwrap();
        assert_eq!(initial.matches[0].item_metadata.item_id, second.item_id);

        store.update_timestamp(first.item_id.clone()).unwrap();

        let after_touch = store
            .search(
                "this is a test".to_string(),
                ListPresentationProfile::CompactRow,
            )
            .await
            .unwrap();
        assert_eq!(after_touch.matches[0].item_metadata.item_id, first.item_id);
    }

    #[tokio::test]
    async fn second_consumer_search_cancels_first_consumers_in_flight_search() {
        // Pins the single-flight contract on active_search_token: starting any
        // search cancels the previous in-flight one, so each UI surface must
        // funnel interactive searches through a single owner.
        let store = ClipboardStore::new_in_memory().unwrap();
        let now = chrono::Utc::now().timestamp();
        for i in 0..100i64 {
            insert_indexed_text_with_timestamp(&store, &format!("invoice draft {i}"), now - i);
        }
        store.indexer.commit().unwrap();

        let first = store.start_search(
            "invoice".to_string(),
            ItemQueryFilter::All,
            ListPresentationProfile::CompactRow,
        );
        let _second = store.start_search(
            String::new(),
            ItemQueryFilter::All,
            ListPresentationProfile::CompactRow,
        );

        let outcome = first.await_result().await.unwrap();
        assert_eq!(outcome, SearchOutcome::Cancelled);
    }
}
