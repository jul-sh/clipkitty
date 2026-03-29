//! ClipboardStore - Thin UniFFI-facing facade over search/save services.

use crate::database::Database;
use crate::indexer::{IndexInspection, Indexer};
use crate::interface::{
    ClipKittyError, ClipboardItem, ClipboardStoreApi, ItemQueryFilter, ItemTag, PreviewPayload,
    RowDecorationResult, SearchOutcome, SearchResult, StoreBootstrapPlan,
};
#[cfg(feature = "sync")]
use crate::sync_bridge::{RealSyncEmitter, SyncEmitter};
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
    /// Token for the currently running search, if any. Starting a new search cancels
    /// the previous one by calling cancel() on this token.
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

    fn open_at_path(path: &Path) -> Result<Self, ClipKittyError> {
        let db = Database::open(path).map_err(ClipKittyError::from)?;
        let indexer = Indexer::new(&Self::index_path_for_database(path))?;
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
        use rayon::prelude::*;
        let prepared: Vec<_> = items
            .par_iter()
            .map(|item| {
                let id = item.id.expect("persisted item should have id");
                let text = item
                    .file_index_text()
                    .unwrap_or_else(|| item.text_content().to_string());
                (id, text, item.timestamp_unix)
            })
            .collect();
        for (id, text, ts) in prepared {
            self.indexer.add_document(id, &text, ts)?;
        }
        self.indexer.commit()?;
        Ok(())
    }

    fn begin_search_operation(
        &self,
        query: String,
        filter: ItemQueryFilter,
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
        self.rebuild_index_contents()
    }

    pub fn start_search(&self, query: String, filter: ItemQueryFilter) -> Arc<SearchOperation> {
        self.begin_search_operation(query, filter)
    }
}

impl ClipboardStore {
    /// Emit the appropriate sync event for an insert outcome.
    #[cfg(feature = "sync")]
    fn emit_for_insert(&self, outcome: &save_service::InsertOutcome) -> Result<(), ClipKittyError> {
        match outcome {
            save_service::InsertOutcome::Deduplicated {
                existing_id,
                touched_at_unix,
            } => {
                self.sync_emitter
                    .emit_item_touched(*existing_id, *touched_at_unix)?;
            }
            save_service::InsertOutcome::Inserted { new_id, item } => {
                let snapshot = crate::sync_bridge::snapshot_from_stored_item(item);
                self.sync_emitter.emit_item_created(*new_id, snapshot)?;
            }
        }
        Ok(())
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
    ) -> Result<i64, ClipKittyError> {
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

    async fn search(&self, query: String) -> Result<SearchResult, ClipKittyError> {
        match self
            .begin_search_operation(query, ItemQueryFilter::All)
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
    ) -> Result<SearchResult, ClipKittyError> {
        if filter == ItemQueryFilter::All {
            return self.search(query).await;
        }
        match self
            .begin_search_operation(query, filter)
            .await_result()
            .await?
        {
            SearchOutcome::Success { result } => Ok(result),
            SearchOutcome::Cancelled => Err(ClipKittyError::Cancelled),
        }
    }

    fn fetch_by_ids(&self, item_ids: Vec<i64>) -> Result<Vec<ClipboardItem>, ClipKittyError> {
        let stored_items = self.db.fetch_items_by_ids(&item_ids)?;
        let mut items: Vec<ClipboardItem> = stored_items
            .into_iter()
            .map(|item| item.to_clipboard_item())
            .collect();
        let tags_by_id = self.db.get_tags_for_ids(&item_ids)?;
        for item in &mut items {
            item.item_metadata.tags = tags_by_id
                .get(&item.item_metadata.item_id)
                .cloned()
                .unwrap_or_default();
        }
        Ok(items)
    }

    fn compute_row_decorations(
        &self,
        item_ids: Vec<i64>,
        query: String,
    ) -> Result<Vec<RowDecorationResult>, ClipKittyError> {
        search_service::compute_row_decorations(&self.db, &self.analysis_cache, item_ids, query)
    }

    fn load_preview_payload(
        &self,
        item_id: i64,
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
        thumbnail: Option<Vec<u8>>,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Result<i64, ClipKittyError> {
        if paths.is_empty() {
            return Err(ClipKittyError::InvalidInput("No files provided".into()));
        }
        let outcome = save_service::save_files(
            &self.db,
            &self.indexer,
            paths,
            filenames,
            file_sizes,
            utis,
            bookmark_data_list,
            thumbnail,
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
        thumbnail: Option<Vec<u8>>,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Result<i64, ClipKittyError> {
        let outcome = save_service::save_file(
            &self.db,
            &self.indexer,
            path,
            filename,
            file_size,
            uti,
            bookmark_data,
            thumbnail,
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
    ) -> Result<i64, ClipKittyError> {
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
        item_id: i64,
        title: Option<String>,
        description: Option<String>,
        image_data: Option<Vec<u8>>,
    ) -> Result<(), ClipKittyError> {
        // Emit before DB write (existing ordering).
        #[cfg(feature = "sync")]
        {
            // Build the snapshot from the raw inputs before save_service normalizes them.
            // We need to call save_service first to get the resolved metadata, but the
            // original code emitted before the DB write. Since save_service now does the
            // DB write, we must emit after to get the resolved fields.
        }
        #[allow(unused_variables)]
        let resolved = save_service::update_link_metadata(
            &self.db,
            item_id,
            title,
            description,
            image_data,
        )?;
        #[cfg(feature = "sync")]
        {
            let snapshot = crate::sync_bridge::link_metadata_snapshot(&resolved);
            self.sync_emitter
                .emit_link_metadata_updated(item_id, snapshot)?;
        }
        Ok(())
    }

    fn update_image_description(
        &self,
        item_id: i64,
        description: String,
    ) -> Result<(), ClipKittyError> {
        // Emit before DB write (existing ordering).
        #[cfg(feature = "sync")]
        self.sync_emitter
            .emit_image_description_updated(item_id, &description)?;

        #[allow(unused_variables)]
        let reindex =
            save_service::update_image_description(&self.db, &self.indexer, item_id, description)?;

        #[cfg(feature = "sync")]
        if matches!(reindex, save_service::ReindexOutcome::IndexFailed) {
            let _ = self.sync_emitter.set_index_dirty();
        }
        Ok(())
    }

    fn update_text_item(&self, item_id: i64, text: String) -> Result<(), ClipKittyError> {
        // Emit before DB write (existing ordering).
        #[cfg(feature = "sync")]
        self.sync_emitter.emit_text_edited(item_id, &text)?;

        #[allow(unused_variables)]
        let reindex =
            save_service::update_text_item(&self.db, &self.indexer, item_id, text)?;

        #[cfg(feature = "sync")]
        if matches!(reindex, save_service::ReindexOutcome::IndexFailed) {
            let _ = self.sync_emitter.set_index_dirty();
        }
        Ok(())
    }

    fn update_timestamp(&self, item_id: i64) -> Result<(), ClipKittyError> {
        #[allow(unused_variables)]
        let timestamp_unix = save_service::update_timestamp(&self.db, item_id)?;

        #[cfg(feature = "sync")]
        self.sync_emitter
            .emit_item_touched(item_id, timestamp_unix)?;
        Ok(())
    }

    fn add_tag(&self, item_id: i64, tag: ItemTag) -> Result<(), ClipKittyError> {
        // Emit before DB write (existing ordering).
        #[cfg(feature = "sync")]
        self.sync_emitter.emit_bookmark_set(item_id)?;

        save_service::add_tag(&self.db, item_id, tag)
    }

    fn remove_tag(&self, item_id: i64, tag: ItemTag) -> Result<(), ClipKittyError> {
        // Emit before DB write (existing ordering).
        #[cfg(feature = "sync")]
        self.sync_emitter.emit_bookmark_cleared(item_id)?;

        save_service::remove_tag(&self.db, item_id, tag)
    }

    fn delete_item(&self, item_id: i64) -> Result<(), ClipKittyError> {
        // Emit before DB write (existing ordering).
        #[cfg(feature = "sync")]
        self.sync_emitter.emit_item_deleted(item_id)?;

        save_service::delete_item(&self.db, &self.indexer, item_id)
    }

    fn clear(&self) -> Result<(), ClipKittyError> {
        // Clear sync state before clearing items (existing ordering).
        #[cfg(feature = "sync")]
        self.sync_emitter.emit_clear()?;

        save_service::clear(&self.db, &self.indexer)
    }

    fn prune_to_size(&self, max_bytes: i64, keep_ratio: f64) -> Result<u64, ClipKittyError> {
        let outcome =
            save_service::prune_to_size(&self.db, &self.indexer, max_bytes, keep_ratio)?;

        #[cfg(feature = "sync")]
        for id in &outcome.deleted_ids {
            self.sync_emitter.emit_item_deleted(*id)?;
        }

        Ok(outcome.bytes_freed)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Sync internals — not exposed via FFI
// ═══════════════════════════════════════════════════════════════════════════════

#[cfg(feature = "sync")]
impl ClipboardStore {
    /// Materialize a sync aggregate into the local items table.
    ///
    /// For Live aggregates: upsert into items table (insert if new, update if exists).
    /// For Tombstoned aggregates: delete from items table.
    fn materialize_aggregate(
        &self,
        global_item_id: &str,
        aggregate: &purr_sync::types::ItemAggregate,
        index_dirty: bool,
    ) -> Result<(), ClipKittyError> {
        use crate::sync_bridge::stored_item_from_snapshot;
        use purr_sync::store::SyncStore;
        use purr_sync::types::ItemAggregate;

        let sync = SyncStore::new(self.db.pool());
        let proj = sync.fetch_projection(global_item_id)?;

        match aggregate {
            ItemAggregate::Live(live) => {
                let item = stored_item_from_snapshot(&live.snapshot)
                    .map_err(ClipKittyError::InvalidInput)?;

                if let Some(ref proj) = proj {
                    if let Some(local_id) = proj.local_item_id {
                        // Update existing item: delete old, insert new.
                        self.db.delete_item(local_id)?;
                        let new_id = self.db.insert_item(&item)?;
                        if index_dirty {
                            let text = item
                                .file_index_text()
                                .unwrap_or_else(|| item.text_content().to_string());
                            let _ = self.indexer.delete_document(local_id);
                            let _ =
                                self.indexer
                                    .add_document(new_id, &text, item.timestamp_unix);
                            let _ = self.indexer.commit();
                        }
                        // Re-map projection to the new local ID.
                        sync.upsert_projection(
                            global_item_id,
                            Some(new_id),
                            &live.versions,
                            false,
                        )?;
                        return Ok(());
                    }
                }

                // No existing local item — insert fresh.
                let new_id = self.db.insert_item(&item)?;
                if index_dirty {
                    let text = item
                        .file_index_text()
                        .unwrap_or_else(|| item.text_content().to_string());
                    let _ = self.indexer.add_document(new_id, &text, item.timestamp_unix);
                    let _ = self.indexer.commit();
                }
                sync.upsert_projection(
                    global_item_id,
                    Some(new_id),
                    &live.versions,
                    false,
                )?;
            }
            ItemAggregate::Tombstoned(_tomb) => {
                if let Some(ref proj) = proj {
                    if let Some(local_id) = proj.local_item_id {
                        let _ = self.indexer.delete_document(local_id);
                        let _ = self.indexer.commit();
                        self.db.delete_item(local_id)?;
                    }
                }
            }
        }

        Ok(())
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
                    global_item_id: e.global_item_id,
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
        let snapshots = sync.fetch_all_snapshots()?;
        Ok(snapshots
            .into_iter()
            .map(|s| {
                let aggregate_data = s.aggregate_data();
                SyncSnapshotRecord {
                    global_item_id: s.global_item_id,
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
    pub fn mark_snapshot_uploaded(
        &self,
        global_item_id: String,
    ) -> Result<(), ClipKittyError> {
        use purr_sync::store::SyncStore;

        let sync = SyncStore::new(self.db.pool());
        sync.mark_snapshot_uploaded(&global_item_id)?;
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
        use crate::sync_bridge::stored_item_from_snapshot;
        use purr_sync::event::ItemEvent;
        use purr_sync::replay;
        use purr_sync::snapshot::ItemSnapshot;
        use purr_sync::store::SyncStore;

        // Apply snapshots first.
        let mut snapshots_applied: usize = 0;
        for record in &snapshot_records {
            let snapshot = ItemSnapshot::from_stored(
                record.global_item_id.clone(),
                record.snapshot_revision,
                record.schema_version,
                record.covers_through_event.clone(),
                &record.aggregate_data,
                false,
                None,
            )
            .map_err(|e| ClipKittyError::InvalidInput(e))?;

            let global_item_id = snapshot.global_item_id.clone();
            let aggregate = snapshot.aggregate.clone();
            let applied = replay::apply_remote_snapshots(self.db.pool(), &[snapshot])?;
            if applied > 0 {
                self.materialize_aggregate(&global_item_id, &aggregate, true)?;
                snapshots_applied += 1;
            }
        }

        // Convert and apply events as a batch.
        let events: Vec<ItemEvent> = event_records
            .iter()
            .map(|r| {
                ItemEvent::from_stored(
                    r.event_id.clone(),
                    r.global_item_id.clone(),
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
        let sync = SyncStore::new(self.db.pool());
        for event_record in &event_records {
            if sync.fetch_projection(&event_record.global_item_id)?.is_some() {
                if let Some(snapshot) = sync.fetch_snapshot(&event_record.global_item_id)? {
                    if self
                        .materialize_aggregate(
                            &event_record.global_item_id,
                            &snapshot.aggregate,
                            true,
                        )
                        .is_err()
                    {
                        batch_result.materialization_failures += 1;
                    }
                }
            }
        }

        // Handle fork plans.
        for (_original_gid, plan) in &batch_result.fork_plans {
            let item = stored_item_from_snapshot(&plan.forked_snapshot)
                .map_err(ClipKittyError::InvalidInput)?;
            let new_id = self.db.insert_item(&item)?;
            let text = item
                .file_index_text()
                .unwrap_or_else(|| item.text_content().to_string());
            let _ = self.indexer.add_document(new_id, &text, item.timestamp_unix);
            let _ = self.indexer.commit();

            let fork_global_id = uuid::Uuid::new_v4().to_string();
            let versions = purr_sync::types::VersionVector {
                content: 1,
                bookmark: 0,
                existence: 1,
                touch: 1,
                metadata: 1,
            };
            sync.upsert_projection(&fork_global_id, Some(new_id), &versions, false)?;
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
        use crate::sync_bridge::stored_item_from_snapshot;
        use purr_sync::event::ItemEvent;
        use purr_sync::replay;
        use purr_sync::store::SyncStore;
        use purr_sync::types::ApplyResult;

        let event = ItemEvent::from_stored(
            record.event_id,
            record.global_item_id.clone(),
            record.origin_device_id,
            record.schema_version,
            record.recorded_at,
            &record.payload_type,
            &record.payload_data,
        )
        .map_err(|e| ClipKittyError::InvalidInput(e))?;

        let result = replay::apply_remote_event(self.db.pool(), &event)?;

        match &result {
            ApplyResult::Applied(delta) => {
                self.materialize_aggregate(
                    &record.global_item_id,
                    &delta.new_aggregate,
                    delta.index_dirty,
                )?;
                Ok(SyncApplyOutcome::Applied)
            }
            ApplyResult::Ignored(_) => Ok(SyncApplyOutcome::Ignored),
            ApplyResult::Deferred(_) => Ok(SyncApplyOutcome::Deferred),
            ApplyResult::Forked(plan) => {
                // Create a new local item from the forked snapshot.
                let item = stored_item_from_snapshot(&plan.forked_snapshot)
                    .map_err(ClipKittyError::InvalidInput)?;
                let new_id = self.db.insert_item(&item)?;
                let text = item
                    .file_index_text()
                    .unwrap_or_else(|| item.text_content().to_string());
                let _ = self.indexer.add_document(new_id, &text, item.timestamp_unix);
                let _ = self.indexer.commit();

                // Create a sync projection for the forked item so it can sync.
                let fork_global_id = uuid::Uuid::new_v4().to_string();
                let sync = SyncStore::new(self.db.pool());
                let versions = purr_sync::types::VersionVector {
                    content: 1,
                    bookmark: 0,
                    existence: 1,
                    touch: 1,
                    metadata: 1,
                };
                sync.upsert_projection(&fork_global_id, Some(new_id), &versions, false)?;

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
            record.global_item_id,
            record.snapshot_revision,
            record.schema_version,
            record.covers_through_event,
            &record.aggregate_data,
            false,
            None,
        )
        .map_err(|e| ClipKittyError::InvalidInput(e))?;

        let global_item_id = snapshot.global_item_id.clone();
        let aggregate = snapshot.aggregate.clone();
        let applied = replay::apply_remote_snapshots(self.db.pool(), &[snapshot])?;
        if applied > 0 {
            self.materialize_aggregate(&global_item_id, &aggregate, true)?;
        }
        Ok(applied > 0)
    }

    /// Run compaction and retention for all items.
    pub fn run_compaction(&self) -> Result<crate::interface::CompactionResult, ClipKittyError> {
        use crate::interface::CompactionResult;
        use purr_sync::compactor;

        let items_compacted = compactor::compact_all(self.db.pool())? as u64;
        let events_purged = compactor::purge_retained_events(self.db.pool())? as u64;
        let tombstones_purged = compactor::purge_tombstone_snapshots(self.db.pool())? as u64;

        Ok(CompactionResult {
            items_compacted,
            events_purged,
            tombstones_purged,
        })
    }

    /// Perform a full resync from the provided snapshots.
    /// Clears all sync state, rebuilds from snapshots, and materializes
    /// live items into the local items table + Tantivy index.
    pub fn full_resync(
        &self,
        snapshot_records: Vec<crate::interface::SyncSnapshotRecord>,
    ) -> Result<u64, ClipKittyError> {
        use purr_sync::replay;
        use purr_sync::snapshot::ItemSnapshot;

        let snapshots: Vec<ItemSnapshot> = snapshot_records
            .into_iter()
            .map(|r| {
                ItemSnapshot::from_stored(
                    r.global_item_id,
                    r.snapshot_revision,
                    r.schema_version,
                    r.covers_through_event,
                    &r.aggregate_data,
                    false,
                    None,
                )
                .map_err(|e| ClipKittyError::InvalidInput(e))
            })
            .collect::<Result<Vec<_>, _>>()?;

        let applied = replay::full_resync_from_snapshots(self.db.pool(), &snapshots)?;

        // Materialize all snapshots into the read model.
        for snapshot in &snapshots {
            self.materialize_aggregate(
                &snapshot.global_item_id,
                &snapshot.aggregate,
                true,
            )?;
        }
        let _ = self.indexer.commit();

        Ok(applied as u64)
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

        let snapshots: Vec<ItemSnapshot> = snapshot_records
            .into_iter()
            .map(|r| {
                ItemSnapshot::from_stored(
                    r.global_item_id,
                    r.snapshot_revision,
                    r.schema_version,
                    r.covers_through_event,
                    &r.aggregate_data,
                    false,
                    None,
                )
                .map_err(|e| ClipKittyError::InvalidInput(e))
            })
            .collect::<Result<Vec<_>, _>>()?;

        let tail_events: Vec<ItemEvent> = tail_event_records
            .into_iter()
            .map(|r| {
                ItemEvent::from_stored(
                    r.event_id,
                    r.global_item_id,
                    r.origin_device_id,
                    r.schema_version,
                    r.recorded_at,
                    &r.payload_type,
                    &r.payload_data,
                )
                .map_err(|e| ClipKittyError::InvalidInput(e))
            })
            .collect::<Result<Vec<_>, _>>()?;

        let result = replay::full_resync(self.db.pool(), &snapshots, &tail_events)?;

        // Materialize all live snapshots into the read model.
        let sync = SyncStore::new(self.db.pool());
        let all_snapshots = sync.fetch_all_snapshots()?;
        for snapshot in &all_snapshots {
            self.materialize_aggregate(
                &snapshot.global_item_id,
                &snapshot.aggregate,
                true,
            )?;
        }
        let _ = self.indexer.commit();

        Ok(SyncFullResyncResult {
            checkpoints_applied: result.checkpoints_applied as u64,
            tail_events_applied: result.tail_events_applied as u64,
            tail_events_ignored: result.tail_events_ignored as u64,
            tail_events_deferred: result.tail_events_deferred as u64,
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
        let index_dirty = sync.get_dirty_flag(FLAG_INDEX_DIRTY)?;

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
    pub fn purgeable_cloud_event_ids(&self, max_age_days: u32) -> Result<Vec<String>, ClipKittyError> {
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
        let count = sync.delete_events_by_ids(&refs)?;
        Ok(count as u64)
    }

    /// Clear the index_dirty flag (after a successful rebuild).
    pub fn clear_index_dirty_flag(&self) -> Result<(), ClipKittyError> {
        use purr_sync::store::SyncStore;
        use purr_sync::types::FLAG_INDEX_DIRTY;

        let sync = SyncStore::new(self.db.pool());
        sync.set_dirty_flag(FLAG_INDEX_DIRTY, false)?;
        Ok(())
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

    #[test]
    fn test_round_trip_save_and_fetch() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let id = store
            .save_text("hello world".into(), None, None)
            .unwrap();
        assert!(id > 0);

        let items = store.fetch_by_ids(vec![id]).unwrap();
        assert_eq!(items.len(), 1);
    }

    #[test]
    fn test_dedup_returns_zero() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let id = store
            .save_text("hello world".into(), None, None)
            .unwrap();
        assert!(id > 0);

        let dup = store
            .save_text("hello world".into(), None, None)
            .unwrap();
        assert_eq!(dup, 0);
    }
}
