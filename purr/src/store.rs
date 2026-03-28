//! ClipboardStore - Thin UniFFI-facing facade over search/save services.

use crate::database::Database;
use crate::indexer::{IndexInspection, Indexer};
use crate::interface::{
    ClipKittyError, ClipboardItem, ClipboardStoreApi, ItemQueryFilter, ItemTag, PreviewPayload,
    RowDecorationResult, SearchOutcome, SearchResult, StoreBootstrapPlan,
};
#[cfg(feature = "sync")]
use crate::interface::{SyncApplyReport, SyncRecordChange};
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

        Ok(Self {
            db: Arc::new(database),
            indexer: Arc::new(indexer),
            analysis_cache: Arc::new(match_presentation::HighlightAnalysisCache::default()),
            active_search_token: Arc::new(Mutex::new(None)),
        })
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

        Ok(Self {
            db: Arc::new(db),
            indexer: Arc::new(indexer),
            analysis_cache: Arc::new(match_presentation::HighlightAnalysisCache::default()),
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
        self.indexer.clear()?;

        use rayon::prelude::*;
        items.into_par_iter().try_for_each(|item| {
            if let Some(id) = item.id {
                let index_text = item
                    .file_index_text()
                    .unwrap_or_else(|| item.text_content().to_string());
                self.indexer
                    .add_document(id, &index_text, item.timestamp_unix)?;
            }
            Ok::<(), ClipKittyError>(())
        })?;
        self.indexer.commit()?;

        Ok(())
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

    fn begin_search_operation(
        &self,
        query: String,
        filter: ItemQueryFilter,
    ) -> Arc<SearchOperation> {
        let token = CancellationToken::new();
        let completion = Arc::new(SearchCompletionCell::new());
        let operation = Arc::new(SearchOperation {
            token: token.clone(),
            completion: Arc::clone(&completion),
        });

        let previous_token = {
            let mut active = self.active_search_token.lock();
            active.replace(token.clone())
        };
        if let Some(previous_token) = previous_token {
            previous_token.cancel();
        }

        let runtime = self.runtime_handle();
        let db = Arc::clone(&self.db);
        let indexer = Arc::clone(&self.indexer);
        let cache = Arc::clone(&self.analysis_cache);
        runtime.clone().spawn(async move {
            if token.is_cancelled() {
                completion.finish(Ok(SearchOutcome::Cancelled));
                return;
            }

            let result = search_service::execute_search(
                search_service::SearchContext {
                    db,
                    indexer,
                    cache,
                    runtime: runtime.clone(),
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

    pub fn start_search(&self, query: String, filter: ItemQueryFilter) -> Arc<SearchOperation> {
        self.begin_search_operation(query, filter)
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
        save_service::save_text(
            &self.db,
            &self.indexer,
            text,
            source_app,
            source_app_bundle_id,
        )
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
        save_service::save_files(
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
        )
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
        save_service::save_file(
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
        )
    }

    fn save_image(
        &self,
        image_data: Vec<u8>,
        thumbnail: Option<Vec<u8>>,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
        is_animated: bool,
    ) -> Result<i64, ClipKittyError> {
        save_service::save_image(
            &self.db,
            &self.indexer,
            image_data,
            thumbnail,
            source_app,
            source_app_bundle_id,
            is_animated,
        )
    }

    fn update_link_metadata(
        &self,
        item_id: i64,
        title: Option<String>,
        description: Option<String>,
        image_data: Option<Vec<u8>>,
    ) -> Result<(), ClipKittyError> {
        save_service::update_link_metadata(&self.db, item_id, title, description, image_data)
    }

    fn update_image_description(
        &self,
        item_id: i64,
        description: String,
    ) -> Result<(), ClipKittyError> {
        save_service::update_image_description(&self.db, &self.indexer, item_id, description)
    }

    fn update_text_item(&self, item_id: i64, text: String) -> Result<(), ClipKittyError> {
        save_service::update_text_item(&self.db, &self.indexer, item_id, text)
    }

    fn update_timestamp(&self, item_id: i64) -> Result<(), ClipKittyError> {
        save_service::update_timestamp(&self.db, &self.indexer, item_id)
    }

    fn add_tag(&self, item_id: i64, tag: ItemTag) -> Result<(), ClipKittyError> {
        save_service::add_tag(&self.db, item_id, tag)
    }

    fn remove_tag(&self, item_id: i64, tag: ItemTag) -> Result<(), ClipKittyError> {
        save_service::remove_tag(&self.db, item_id, tag)
    }

    fn delete_item(&self, item_id: i64) -> Result<(), ClipKittyError> {
        save_service::delete_item(&self.db, &self.indexer, item_id)
    }

    fn clear(&self) -> Result<(), ClipKittyError> {
        save_service::clear(&self.db, &self.indexer)
    }

    fn prune_to_size(&self, max_bytes: i64, keep_ratio: f64) -> Result<u64, ClipKittyError> {
        save_service::prune_to_size(&self.db, &self.indexer, max_bytes, keep_ratio)
    }
}

#[cfg(feature = "sync")]
#[uniffi::export]
impl ClipboardStore {
    pub fn pending_sync_changes(
        &self,
        limit: u32,
    ) -> Result<Vec<SyncRecordChange>, ClipKittyError> {
        save_service::pending_sync_changes(&self.db, limit)
    }

    pub fn acknowledge_sync_change_uploaded(
        &self,
        global_item_id: String,
        record_change_tag: Option<String>,
    ) -> Result<(), ClipKittyError> {
        save_service::acknowledge_sync_change_uploaded(
            &self.db,
            &global_item_id,
            record_change_tag.as_deref(),
        )
    }

    pub fn apply_remote_sync_changes(
        &self,
        changes: Vec<SyncRecordChange>,
    ) -> Result<SyncApplyReport, ClipKittyError> {
        save_service::apply_remote_sync_changes(&self.db, &self.indexer, changes)
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
    use crate::interface::{
        ClipboardContent, FileStatus, HighlightKind, IconType, ItemIcon, ItemQueryFilter,
        LinkMetadataPayload, LinkMetadataState, StoreBootstrapPlan,
    };
    #[cfg(feature = "sync")]
    use crate::interface::{
        SyncContentPayload, SyncLiveSnapshot, SyncRecordChange, SyncSnapshot,
        SyncTombstoneSnapshot, SyncVersion,
    };
    #[cfg(feature = "sync")]
    use crate::models::StoredItem;
    use once_cell::sync::Lazy;
    use parking_lot::Mutex as TestMutex;
    use std::collections::BTreeSet;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, OnceLock};
    use tempfile::tempdir;

    static SEARCH_HOOK_TEST_LOCK: Lazy<TestMutex<()>> = Lazy::new(|| TestMutex::new(()));

    fn wait_for_operation_registration(operation_slot: &Arc<OnceLock<Arc<SearchOperation>>>) {
        for attempt in 0..100 {
            if operation_slot.get().is_some() {
                return;
            }
            if attempt % 10 == 0 {
                std::thread::sleep(std::time::Duration::from_millis(1));
            } else {
                std::thread::yield_now();
            }
        }

        panic!("search operation should be registered before test hook work begins");
    }

    fn runtime() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
    }

    fn temp_db_path() -> (tempfile::TempDir, String) {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("clipboard.sqlite");
        (dir, db_path.to_string_lossy().to_string())
    }

    #[cfg(feature = "sync")]
    fn sync_version(counter: i64, device_id: &str) -> SyncVersion {
        SyncVersion {
            counter,
            device_id: device_id.to_string(),
        }
    }

    #[cfg(feature = "sync")]
    fn live_change(
        global_item_id: &str,
        content: SyncContentPayload,
        activity_timestamp_unix: i64,
        content_version: SyncVersion,
        bookmark_version: SyncVersion,
        activity_version: SyncVersion,
        delete_version: SyncVersion,
    ) -> SyncRecordChange {
        SyncRecordChange {
            snapshot: SyncSnapshot::Live {
                snapshot: SyncLiveSnapshot {
                    global_item_id: global_item_id.to_string(),
                    content,
                    source_app: None,
                    source_app_bundle_id: None,
                    is_bookmarked: false,
                    activity_timestamp_unix,
                    content_version,
                    bookmark_version,
                    activity_version,
                    delete_version,
                },
            },
            record_change_tag: Some(format!("tag-{global_item_id}-{activity_timestamp_unix}")),
        }
    }

    #[cfg(feature = "sync")]
    fn tombstone_change(
        global_item_id: &str,
        content_version: SyncVersion,
        delete_version: SyncVersion,
    ) -> SyncRecordChange {
        let delete_counter = delete_version.counter;
        SyncRecordChange {
            snapshot: SyncSnapshot::Tombstone {
                snapshot: SyncTombstoneSnapshot {
                    global_item_id: global_item_id.to_string(),
                    content_version,
                    delete_version,
                },
            },
            record_change_tag: Some(format!("tag-{global_item_id}-delete-{}", delete_counter)),
        }
    }

    fn db_ids_matching_query(store: &ClipboardStore, query: &str) -> BTreeSet<i64> {
        let lowered = query.to_lowercase();
        store
            .db
            .fetch_all_items()
            .unwrap()
            .into_iter()
            .filter_map(|item| {
                let item_id = item.id?;
                item.text_content()
                    .to_lowercase()
                    .contains(&lowered)
                    .then_some(item_id)
            })
            .collect()
    }

    #[cfg(feature = "sync")]
    fn db_id_for_exact_text(store: &ClipboardStore, text: &str) -> i64 {
        store
            .db
            .fetch_all_items()
            .unwrap()
            .into_iter()
            .find_map(|item| {
                (item.text_content() == text)
                    .then_some(item.id.expect("stored items should have ids when fetched"))
            })
            .expect("expected to find item by exact text")
    }

    async fn search_ids(store: &ClipboardStore, query: &str) -> Vec<i64> {
        store
            .search(query.to_string())
            .await
            .unwrap()
            .matches
            .into_iter()
            .map(|item| item.item_metadata.item_id)
            .collect()
    }

    async fn assert_search_matches_db_for_query(store: &ClipboardStore, query: &str) {
        let search_ids: BTreeSet<i64> = search_ids(store, query).await.into_iter().collect();
        assert_eq!(search_ids, db_ids_matching_query(store, query));
    }

    #[test]
    fn test_store_creation() {
        let store = ClipboardStore::new_in_memory().unwrap();
        assert!(store.database_size() > 0);
    }

    #[tokio::test]
    async fn test_search_and_filter_roundtrip() {
        let store = ClipboardStore::new_in_memory().unwrap();
        store
            .save_text("Hello World".to_string(), None, None)
            .unwrap();
        store
            .save_text("https://example.com".to_string(), None, None)
            .unwrap();

        let all = store.search("".to_string()).await.unwrap();
        assert_eq!(all.matches.len(), 2);
        assert!(all.first_preview_payload.is_some());

        let links = store
            .search_filtered(
                "".to_string(),
                ItemQueryFilter::ContentType {
                    content_type: crate::interface::ContentTypeFilter::Links,
                },
            )
            .await
            .unwrap();
        assert_eq!(links.matches.len(), 1);
        assert!(links.matches[0]
            .item_metadata
            .snippet
            .contains("example.com"));
    }

    #[tokio::test]
    async fn test_short_caret_query_uses_stripped_prefix_search() {
        let store = ClipboardStore::new_in_memory().unwrap();
        store
            .save_text("sup ^hi how are you".to_string(), None, None)
            .unwrap();
        let prefix_id = store.save_text("hi j".to_string(), None, None).unwrap();
        store.save_text("sup hi".to_string(), None, None).unwrap();

        let result = store.search("^hi".to_string()).await.unwrap();
        let ids: Vec<i64> = result
            .matches
            .iter()
            .map(|item| item.item_metadata.item_id)
            .collect();

        assert_eq!(ids, vec![prefix_id]);
    }

    #[tokio::test]
    async fn test_short_query_returns_prefix_matches_before_recent_anywhere_matches() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let anywhere_oldest = store
            .save_text("zz hi in the middle".to_string(), None, None)
            .unwrap();
        std::thread::sleep(std::time::Duration::from_millis(1100));
        let prefix_newer = store
            .save_text("hi prefix".to_string(), None, None)
            .unwrap();
        std::thread::sleep(std::time::Duration::from_millis(1100));
        let anywhere_newest = store
            .save_text("say hi again".to_string(), None, None)
            .unwrap();

        let result = store.search("hi".to_string()).await.unwrap();
        let ids: Vec<i64> = result
            .matches
            .iter()
            .map(|item| item.item_metadata.item_id)
            .collect();

        assert_eq!(ids, vec![prefix_newer, anywhere_newest, anywhere_oldest]);

        let prefix_match = result.matches[0].row_decoration.as_ref().unwrap();
        assert_eq!(prefix_match.highlights[0].kind, HighlightKind::Prefix);

        let anywhere_match = result.matches[1].row_decoration.as_ref().unwrap();
        assert_eq!(anywhere_match.highlights[0].kind, HighlightKind::Exact);
        assert_eq!(anywhere_match.highlights[0].utf16_start, 4);
    }

    #[tokio::test]
    async fn test_caret_query_ranks_literal_then_prefix_then_contains_for_trigram_queries() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let literal_id = store
            .save_text("sup ^hello there".to_string(), None, None)
            .unwrap();
        let prefix_id = store
            .save_text("hello world".to_string(), None, None)
            .unwrap();
        let contains_id = store
            .save_text("say hello there".to_string(), None, None)
            .unwrap();

        let result = store.search("^hello".to_string()).await.unwrap();
        let ids: Vec<i64> = result
            .matches
            .iter()
            .map(|item| item.item_metadata.item_id)
            .take(3)
            .collect();

        assert_eq!(ids, vec![literal_id, prefix_id, contains_id]);
    }

    #[tokio::test]
    async fn test_trigram_query_surfaces_prefix_before_infix_substring() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let prefix_id = store
            .save_text("port forwarding".to_string(), None, None)
            .unwrap();
        let infix_id = store
            .save_text("import config".to_string(), None, None)
            .unwrap();

        let result = store.search("port".to_string()).await.unwrap();
        let ids: Vec<i64> = result
            .matches
            .iter()
            .map(|item| item.item_metadata.item_id)
            .take(2)
            .collect();

        assert_eq!(ids, vec![prefix_id, infix_id]);
        let decorations = store
            .compute_row_decorations(vec![infix_id], "port".to_string())
            .unwrap();
        assert_eq!(
            decorations[0].decoration.as_ref().unwrap().highlights[0].kind,
            HighlightKind::Substring
        );
    }

    #[tokio::test]
    async fn test_trigram_query_surfaces_prefix_before_subword_prefix() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let prefix_id = store
            .save_text("code review".to_string(), None, None)
            .unwrap();
        let subword_id = store
            .save_text("responseCode".to_string(), None, None)
            .unwrap();

        let result = store.search("code".to_string()).await.unwrap();
        let ids: Vec<i64> = result
            .matches
            .iter()
            .map(|item| item.item_metadata.item_id)
            .take(2)
            .collect();

        assert_eq!(ids, vec![prefix_id, subword_id]);
        let decorations = store
            .compute_row_decorations(vec![subword_id], "code".to_string())
            .unwrap();
        assert_eq!(
            decorations[0].decoration.as_ref().unwrap().highlights[0].kind,
            HighlightKind::SubwordPrefix
        );
    }

    #[tokio::test]
    async fn test_trigram_query_uses_single_char_trailing_prefix_immediately() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let non_prefix_id = store
            .save_text("recent changes to renderer".to_string(), None, None)
            .unwrap();
        let prefix_id = store
            .save_text("recent changes to highlighting".to_string(), None, None)
            .unwrap();

        let result = store
            .search("recent changes to h".to_string())
            .await
            .unwrap();
        let ids: Vec<i64> = result
            .matches
            .iter()
            .map(|item| item.item_metadata.item_id)
            .take(2)
            .collect();

        assert_eq!(ids, vec![prefix_id, non_prefix_id]);
        assert!(result.matches[0]
            .row_decoration
            .as_ref()
            .unwrap()
            .highlights
            .iter()
            .any(|highlight| highlight.kind == HighlightKind::Prefix));
    }

    #[tokio::test]
    async fn test_search_uses_word_sequence_recall_for_long_short_word_queries() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let exact_id = store
            .save_text("A a B b C c D d".to_string(), None, None)
            .unwrap();
        let scattered_id = store
            .save_text("A z B z C z D z".to_string(), None, None)
            .unwrap();

        let result = store.search("A a B b".to_string()).await.unwrap();
        let ids: Vec<i64> = result
            .matches
            .iter()
            .map(|item| item.item_metadata.item_id)
            .collect();

        assert!(
            ids.contains(&exact_id),
            "expected {:?} to contain {}",
            ids,
            exact_id
        );
        assert!(
            !ids.contains(&scattered_id),
            "expected scattered short-word content to stay out of results, got {:?}",
            ids
        );
    }

    #[test]
    fn test_short_query_sync_cancelled() {
        let rt = runtime();
        let store = ClipboardStore::new_in_memory().unwrap();
        store.save_text("Hello".to_string(), None, None).unwrap();

        let token = CancellationToken::new();
        token.cancel();
        let result = search_service::search_short_query_sync(
            &store.db,
            &store.analysis_cache,
            "He",
            purr_core::search_result_builder::ShortQueryMode::PrefixThenContains,
            &token,
            &rt.handle().clone(),
            None,
            None,
        );
        assert!(matches!(result, Err(ClipKittyError::Cancelled)));
    }

    #[tokio::test]
    async fn test_tag_filter_roundtrip() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let bookmarked_id = store.save_text("keep me".to_string(), None, None).unwrap();
        let plain_id = store.save_text("leave me".to_string(), None, None).unwrap();
        store.add_tag(bookmarked_id, ItemTag::Bookmark).unwrap();

        let result = store
            .search_filtered(
                "".to_string(),
                ItemQueryFilter::Tagged {
                    tag: ItemTag::Bookmark,
                },
            )
            .await
            .unwrap();

        let ids: Vec<i64> = result
            .matches
            .iter()
            .map(|item| item.item_metadata.item_id)
            .collect();
        assert_eq!(ids, vec![bookmarked_id]);
        assert!(!ids.contains(&plain_id));
        assert_eq!(
            result.matches[0].item_metadata.tags,
            vec![ItemTag::Bookmark]
        );
    }

    #[test]
    fn test_trigram_search_returns_cancelled_after_token() {
        let rt = runtime();
        let store = ClipboardStore::new_in_memory().unwrap();
        for i in 0..200 {
            store
                .save_text(
                    format!("Item number {i} with repeated search text"),
                    None,
                    None,
                )
                .unwrap();
        }

        let token = CancellationToken::new();
        let query = crate::search::SearchQuery::parse("repeated");
        token.cancel();
        let result = search_service::search_trigram_query_sync(
            &store.db,
            &store.indexer,
            &store.analysis_cache,
            &query,
            &token,
            &rt.handle().clone(),
            None,
            None,
        );
        assert!(matches!(result, Err(ClipKittyError::Cancelled)));
    }

    #[tokio::test]
    async fn test_explicit_search_operation_cancelled() {
        let store = ClipboardStore::new_in_memory().unwrap();
        for i in 0..200 {
            store
                .save_text(
                    format!("Item number {i} with repeated search text"),
                    None,
                    None,
                )
                .unwrap();
        }

        let operation = store.start_search("repeated".to_string(), ItemQueryFilter::All);
        operation.cancel();

        let outcome = operation.await_result().await.unwrap();
        assert_eq!(outcome, SearchOutcome::Cancelled);
    }

    #[tokio::test]
    async fn test_new_search_cancels_previous_running_operation() {
        let store = ClipboardStore::new_in_memory().unwrap();
        for i in 0..400 {
            store
                .save_text(
                    format!("Item number {i} with repeated search text"),
                    None,
                    None,
                )
                .unwrap();
        }

        let first = store.start_search("repeated".to_string(), ItemQueryFilter::All);
        let second = store.start_search("number 399".to_string(), ItemQueryFilter::All);

        assert_eq!(
            first.await_result().await.unwrap(),
            SearchOutcome::Cancelled
        );
        assert!(matches!(
            second.await_result().await.unwrap(),
            SearchOutcome::Success { .. }
        ));
    }

    #[tokio::test]
    async fn test_phase_two_cancellation_stops_work_early() {
        let _lock = SEARCH_HOOK_TEST_LOCK.lock();
        let _phase_two_hook_lock = crate::indexer::test_support::HOOK_TEST_LOCK.lock();
        let store = ClipboardStore::new_in_memory().unwrap();
        for i in 0..1_000 {
            store
                .save_text(
                    format!("Item number {i} with repeated search text and extra ranking words"),
                    None,
                    None,
                )
                .unwrap();
        }

        let processed = Arc::new(AtomicUsize::new(0));
        let operation_slot: Arc<OnceLock<Arc<SearchOperation>>> = Arc::new(OnceLock::new());
        let _hook_guard = crate::indexer::test_support::install_search_hooks(
            crate::indexer::test_support::SearchTestHooks {
                before_phase_two: Some(Arc::new({
                    let operation_slot = Arc::clone(&operation_slot);
                    move || wait_for_operation_registration(&operation_slot)
                })),
                on_phase_two_candidate: Some(Arc::new({
                    let processed = Arc::clone(&processed);
                    let operation_slot = Arc::clone(&operation_slot);
                    move |_| {
                        let seen = processed.fetch_add(1, Ordering::SeqCst);
                        if seen == 0 {
                            if let Some(operation) = operation_slot.get() {
                                operation.cancel();
                            }
                        }
                    }
                })),
            },
        );

        let operation = store.start_search("repeated ranking".to_string(), ItemQueryFilter::All);
        let _ = operation_slot.set(Arc::clone(&operation));

        let outcome = operation.await_result().await.unwrap();
        assert_eq!(outcome, SearchOutcome::Cancelled);
        assert!(
            processed.load(Ordering::SeqCst) < 128,
            "phase-two work should stop early after cancellation"
        );
    }

    #[tokio::test]
    async fn test_eager_match_cancellation_stops_highlight_work_early() {
        let _lock = SEARCH_HOOK_TEST_LOCK.lock();
        let store = ClipboardStore::new_in_memory().unwrap();
        for i in 0..500 {
            store
                .save_text(
                    format!(
                        "repeated search text item {i} with enough body for eager highlighting"
                    ),
                    None,
                    None,
                )
                .unwrap();
        }

        let processed = Arc::new(AtomicUsize::new(0));
        let operation_slot: Arc<OnceLock<Arc<SearchOperation>>> = Arc::new(OnceLock::new());
        let _hook_guard = crate::search_service::test_support::install_search_hooks(
            crate::search_service::test_support::SearchTestHooks {
                before_eager_matches: Some(Arc::new({
                    let operation_slot = Arc::clone(&operation_slot);
                    move || wait_for_operation_registration(&operation_slot)
                })),
                on_eager_match: Some(Arc::new({
                    let processed = Arc::clone(&processed);
                    let operation_slot = Arc::clone(&operation_slot);
                    move |_| {
                        let seen = processed.fetch_add(1, Ordering::SeqCst);
                        if seen == 0 {
                            if let Some(operation) = operation_slot.get() {
                                operation.cancel();
                                std::thread::sleep(std::time::Duration::from_millis(10));
                            }
                        }
                    }
                })),
                ..Default::default()
            },
        );

        let operation = store.start_search("repeated search".to_string(), ItemQueryFilter::All);
        let _ = operation_slot.set(Arc::clone(&operation));

        let outcome = operation.await_result().await.unwrap();
        assert_eq!(outcome, SearchOutcome::Cancelled);
        assert!(
            processed.load(Ordering::SeqCst) < 50,
            "eager highlight work should stop shortly after cancellation"
        );
    }

    #[tokio::test]
    async fn test_rapid_typing_keeps_only_latest_search_running() {
        let store = ClipboardStore::new_in_memory().unwrap();
        for i in 0..500 {
            store
                .save_text(
                    format!("Item number {i} with repeated search text and trailing content"),
                    None,
                    None,
                )
                .unwrap();
        }

        let first = store.start_search("repeated".to_string(), ItemQueryFilter::All);
        let second = store.start_search("repeated s".to_string(), ItemQueryFilter::All);
        let third = store.start_search("repeated se".to_string(), ItemQueryFilter::All);
        let fourth = store.start_search("repeated sea".to_string(), ItemQueryFilter::All);

        assert_eq!(
            first.await_result().await.unwrap(),
            SearchOutcome::Cancelled
        );
        assert_eq!(
            second.await_result().await.unwrap(),
            SearchOutcome::Cancelled
        );
        assert_eq!(
            third.await_result().await.unwrap(),
            SearchOutcome::Cancelled
        );
        assert!(matches!(
            fourth.await_result().await.unwrap(),
            SearchOutcome::Success { .. }
        ));
    }

    #[test]
    fn test_preview_payload_reuses_cached_analysis_from_row_decoration() {
        let _lock = SEARCH_HOOK_TEST_LOCK.lock();
        let store = ClipboardStore::new_in_memory().unwrap();
        let item_id = store
            .save_text("alpha beta gamma".to_string(), None, None)
            .unwrap();

        let computed = Arc::new(AtomicUsize::new(0));
        let cache_hits = Arc::new(AtomicUsize::new(0));
        let _hook_guard = crate::search_service::test_support::install_search_hooks(
            crate::search_service::test_support::SearchTestHooks {
                on_analysis_computed: Some(Arc::new({
                    let computed = Arc::clone(&computed);
                    move |hook_item_id, hook_query| {
                        if hook_item_id == item_id && hook_query == "alpha" {
                            computed.fetch_add(1, Ordering::SeqCst);
                        }
                    }
                })),
                on_analysis_cache_hit: Some(Arc::new({
                    let cache_hits = Arc::clone(&cache_hits);
                    move |hook_item_id, hook_query| {
                        if hook_item_id == item_id && hook_query == "alpha" {
                            cache_hits.fetch_add(1, Ordering::SeqCst);
                        }
                    }
                })),
                ..Default::default()
            },
        );

        let row_results = search_service::compute_row_decorations(
            &store.db,
            &store.analysis_cache,
            vec![item_id],
            "alpha".to_string(),
        )
        .unwrap();
        assert_eq!(row_results.len(), 1);
        assert!(row_results[0].decoration.is_some());

        let payload = search_service::load_preview_payload(
            &store.db,
            &store.analysis_cache,
            item_id,
            "alpha".to_string(),
        )
        .unwrap()
        .expect("preview payload should exist");
        assert!(payload.decoration.is_some());

        assert_eq!(
            computed.load(Ordering::SeqCst),
            1,
            "shared analysis should be computed once"
        );
        assert_eq!(
            cache_hits.load(Ordering::SeqCst),
            1,
            "preview payload should reuse the cached analysis"
        );
    }

    #[test]
    fn test_preview_payload_cache_invalidates_when_item_text_changes() {
        let _lock = SEARCH_HOOK_TEST_LOCK.lock();
        let store = ClipboardStore::new_in_memory().unwrap();
        let item_id = store
            .save_text("alpha beta gamma".to_string(), None, None)
            .unwrap();

        let computed = Arc::new(AtomicUsize::new(0));
        let cache_hits = Arc::new(AtomicUsize::new(0));
        let _hook_guard = crate::search_service::test_support::install_search_hooks(
            crate::search_service::test_support::SearchTestHooks {
                on_analysis_computed: Some(Arc::new({
                    let computed = Arc::clone(&computed);
                    move |hook_item_id, hook_query| {
                        if hook_item_id == item_id && hook_query == "alpha" {
                            computed.fetch_add(1, Ordering::SeqCst);
                        }
                    }
                })),
                on_analysis_cache_hit: Some(Arc::new({
                    let cache_hits = Arc::clone(&cache_hits);
                    move |hook_item_id, hook_query| {
                        if hook_item_id == item_id && hook_query == "alpha" {
                            cache_hits.fetch_add(1, Ordering::SeqCst);
                        }
                    }
                })),
                ..Default::default()
            },
        );

        let _ = search_service::compute_row_decorations(
            &store.db,
            &store.analysis_cache,
            vec![item_id],
            "alpha".to_string(),
        )
        .unwrap();
        let _ = search_service::load_preview_payload(
            &store.db,
            &store.analysis_cache,
            item_id,
            "alpha".to_string(),
        )
        .unwrap()
        .expect("initial preview payload should exist");

        store
            .update_text_item(item_id, "alpha updated delta".to_string())
            .unwrap();

        let payload = search_service::load_preview_payload(
            &store.db,
            &store.analysis_cache,
            item_id,
            "alpha".to_string(),
        )
        .unwrap()
        .expect("updated preview payload should exist");

        match &payload.item.content {
            ClipboardContent::Text { value } => assert_eq!(value, "alpha updated delta"),
            other => panic!("expected text payload, got {other:?}"),
        }
        assert_eq!(
            computed.load(Ordering::SeqCst),
            2,
            "content hash change should force recomputation"
        );
        assert_eq!(
            cache_hits.load(Ordering::SeqCst),
            1,
            "only the unchanged intermediate read should hit the cache"
        );
    }

    #[test]
    fn test_analysis_cache_is_scoped_by_query() {
        let _lock = SEARCH_HOOK_TEST_LOCK.lock();
        let store = ClipboardStore::new_in_memory().unwrap();
        let item_id = store
            .save_text("alpha beta gamma".to_string(), None, None)
            .unwrap();

        let computed = Arc::new(AtomicUsize::new(0));
        let cache_hits = Arc::new(AtomicUsize::new(0));
        let _hook_guard = crate::search_service::test_support::install_search_hooks(
            crate::search_service::test_support::SearchTestHooks {
                on_analysis_computed: Some(Arc::new({
                    let computed = Arc::clone(&computed);
                    move |hook_item_id, _| {
                        if hook_item_id == item_id {
                            computed.fetch_add(1, Ordering::SeqCst);
                        }
                    }
                })),
                on_analysis_cache_hit: Some(Arc::new({
                    let cache_hits = Arc::clone(&cache_hits);
                    move |hook_item_id, _| {
                        if hook_item_id == item_id {
                            cache_hits.fetch_add(1, Ordering::SeqCst);
                        }
                    }
                })),
                ..Default::default()
            },
        );

        let _ = search_service::load_preview_payload(
            &store.db,
            &store.analysis_cache,
            item_id,
            "alpha".to_string(),
        )
        .unwrap()
        .expect("alpha preview payload should exist");
        let _ = search_service::load_preview_payload(
            &store.db,
            &store.analysis_cache,
            item_id,
            "beta".to_string(),
        )
        .unwrap()
        .expect("beta preview payload should exist");

        assert_eq!(
            computed.load(Ordering::SeqCst),
            2,
            "different queries should not share cached analysis"
        );
        assert_eq!(cache_hits.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn test_interruptible_fetch_propagates_interrupted_error() {
        let rt = runtime();
        let store = ClipboardStore::new_in_memory().unwrap();
        let id = store
            .save_text("Test content".to_string(), None, None)
            .unwrap();

        let token = CancellationToken::new();
        let items = store
            .db
            .fetch_items_by_ids_interruptible(&[id], &token, &rt.handle().clone())
            .unwrap();
        assert_eq!(items.len(), 1);
    }

    #[test]
    fn test_text_duplicate_handling() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let id1 = store
            .save_text("Same content".to_string(), None, None)
            .unwrap();
        let id2 = store
            .save_text("Same content".to_string(), None, None)
            .unwrap();
        assert!(id1 > 0);
        assert_eq!(id2, 0);
    }

    #[test]
    fn test_image_duplicate_handling_uses_content_hash() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let id1 = store
            .save_image(vec![1, 2, 3], Some(vec![9]), None, None, false)
            .unwrap();
        let id2 = store
            .save_image(vec![1, 2, 3], Some(vec![8]), None, None, false)
            .unwrap();
        let id3 = store
            .save_image(vec![1, 2, 4], Some(vec![8]), None, None, false)
            .unwrap();

        assert!(id1 > 0);
        assert_eq!(id2, 0);
        assert!(id3 > 0);
    }

    #[test]
    fn test_save_file_roundtrip() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let id = store
            .save_file(
                "/tmp/report.pdf".to_string(),
                "report.pdf".to_string(),
                128,
                "com.adobe.pdf".to_string(),
                vec![1, 2, 3],
                None,
                Some("Finder".to_string()),
                Some("com.apple.finder".to_string()),
            )
            .unwrap();

        let items = store.fetch_by_ids(vec![id]).unwrap();
        match &items[0].content {
            ClipboardContent::File { files, .. } => {
                assert_eq!(files.len(), 1);
                assert_eq!(files[0].filename, "report.pdf");
                assert_eq!(files[0].file_status, FileStatus::Available);
            }
            other => panic!("expected file content, got {other:?}"),
        }
        match &items[0].item_metadata.icon {
            ItemIcon::Symbol { icon_type } => assert_eq!(*icon_type, IconType::File),
            other => panic!("expected file icon, got {other:?}"),
        }
    }

    #[test]
    fn test_link_update_roundtrip() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let id = store
            .save_text("https://example.com".to_string(), None, None)
            .unwrap();

        store
            .update_link_metadata(
                id,
                Some("Example".to_string()),
                Some("Description".to_string()),
                Some(vec![1, 2, 3]),
            )
            .unwrap();

        let items = store.fetch_by_ids(vec![id]).unwrap();
        match &items[0].content {
            ClipboardContent::Link { metadata_state, .. } => {
                assert_eq!(
                    metadata_state,
                    &LinkMetadataState::Loaded {
                        payload: LinkMetadataPayload::TitleAndImage {
                            title: "Example".to_string(),
                            description: Some("Description".to_string()),
                            image_data: vec![1, 2, 3],
                        },
                    }
                );
            }
            other => panic!("expected link content, got {other:?}"),
        }
    }

    #[test]
    fn test_delete_and_clear() {
        let rt = runtime();
        let store = ClipboardStore::new_in_memory().unwrap();
        let id = store
            .save_text("delete me".to_string(), None, None)
            .unwrap();
        store.delete_item(id).unwrap();
        assert!(store.fetch_by_ids(vec![id]).unwrap().is_empty());

        store.save_text("one".to_string(), None, None).unwrap();
        store.save_text("two".to_string(), None, None).unwrap();
        assert_eq!(
            rt.block_on(store.search("".to_string()))
                .unwrap()
                .matches
                .len(),
            2
        );
        store.clear().unwrap();
        assert_eq!(
            rt.block_on(store.search("".to_string()))
                .unwrap()
                .matches
                .len(),
            0
        );
    }

    #[test]
    fn test_search_operation_cancels_on_drop() {
        let token = CancellationToken::new();
        let operation = SearchOperation {
            token: token.clone(),
            completion: Arc::new(SearchCompletionCell::new()),
        };
        assert!(!token.is_cancelled());
        drop(operation);
        assert!(token.is_cancelled());
    }

    #[test]
    fn test_search_without_external_runtime() {
        let store = ClipboardStore::new_in_memory().unwrap();
        store
            .save_text("Hello World".to_string(), None, None)
            .unwrap();
        let result = futures::executor::block_on(store.search("Hello".to_string())).unwrap();
        assert_eq!(result.matches.len(), 1);
    }

    #[tokio::test]
    async fn test_chunked_search_uses_best_chunk_snippet_and_full_preview_offsets() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let leading = "noise ".repeat((crate::indexer::CHUNK_PARENT_THRESHOLD_BYTES / 6) + 4096);
        let query = "alphauniqueterm";
        let item_id = store
            .save_text(format!("{leading}{query} trailing context"), None, None)
            .unwrap();

        let result = store.search(query.to_string()).await.unwrap();
        assert_eq!(result.matches.len(), 1);
        assert_eq!(result.matches[0].item_metadata.item_id, item_id);
        assert!(
            result.matches[0].item_metadata.snippet.contains(query),
            "chunked result snippet should come from the matched chunk"
        );
        assert!(
            result.first_preview_payload.as_ref().is_none(),
            "initial search should skip large chunked preview payload entirely"
        );

        let preview = search_service::load_preview_payload(
            &store.db,
            &store.analysis_cache,
            item_id,
            query.to_string(),
        )
        .unwrap()
        .expect("preview payload should be present");
        let decoration = preview
            .decoration
            .expect("preview decoration should be present");
        let first_highlight = decoration
            .highlights
            .first()
            .expect("preview should include highlights");
        assert!(
            first_highlight.utf16_start >= leading.len() as u64,
            "preview highlights should be mapped back to full-document offsets"
        );
    }

    #[test]
    fn test_bootstrap_inspection_ready_when_index_matches() {
        let (_dir, db_path) = temp_db_path();
        let store = ClipboardStore::new(db_path.clone()).unwrap();
        store
            .save_text("hello world".to_string(), None, None)
            .unwrap();

        let plan = inspect_store_bootstrap(db_path).unwrap();
        assert_eq!(plan, StoreBootstrapPlan::Ready);
    }

    #[test]
    fn test_bootstrap_inspection_requires_rebuild_when_index_missing() {
        let (dir, db_path) = temp_db_path();
        let store = ClipboardStore::new(db_path.clone()).unwrap();
        store
            .save_text("hello world".to_string(), None, None)
            .unwrap();
        drop(store);

        let index_path = dir
            .path()
            .join(format!("tantivy_index_{}", crate::indexer::INDEX_VERSION));
        std::fs::remove_dir_all(index_path).unwrap();

        let plan = inspect_store_bootstrap(db_path).unwrap();
        assert_eq!(plan, StoreBootstrapPlan::RebuildIndex);
    }

    #[test]
    fn test_bootstrap_inspection_ready_for_chunked_index() {
        let (_dir, db_path) = temp_db_path();
        let store = ClipboardStore::new(db_path.clone()).unwrap();
        store
            .save_text(
                "noise ".repeat((crate::indexer::CHUNK_PARENT_THRESHOLD_BYTES / 6) + 4096),
                None,
                None,
            )
            .unwrap();

        let plan = inspect_store_bootstrap(db_path).unwrap();
        assert_eq!(plan, StoreBootstrapPlan::Ready);
    }

    #[tokio::test]
    async fn test_explicit_rebuild_restores_search_results_after_missing_index() {
        let (dir, db_path) = temp_db_path();
        let store = ClipboardStore::new(db_path.clone()).unwrap();
        let item_id = store
            .save_text("needle in haystack".to_string(), None, None)
            .unwrap();
        drop(store);

        let index_path = dir
            .path()
            .join(format!("tantivy_index_{}", crate::indexer::INDEX_VERSION));
        std::fs::remove_dir_all(index_path).unwrap();

        let store = ClipboardStore::new(db_path.clone()).unwrap();
        let before = store.search("needle".to_string()).await.unwrap();
        assert!(before.matches.is_empty());

        store.rebuild_index().unwrap();

        let after = store.search("needle".to_string()).await.unwrap();
        let ids: Vec<i64> = after
            .matches
            .iter()
            .map(|item| item.item_metadata.item_id)
            .collect();
        assert_eq!(ids, vec![item_id]);
    }

    #[test]
    #[cfg(feature = "sync")]
    fn test_pending_sync_changes_backfill_supported_items_and_skip_files() {
        let store = ClipboardStore::new_in_memory().unwrap();

        let text_item = StoredItem::new_text("syncprobe backfill text".to_string(), None, None);
        let text_id = store.db.insert_item(&text_item).unwrap();
        store
            .indexer
            .add_document(text_id, text_item.text_content(), text_item.timestamp_unix)
            .unwrap();

        let file_item = StoredItem::new_file(
            "/tmp/syncprobe.txt".to_string(),
            "syncprobe.txt".to_string(),
            42,
            "public.plain-text".to_string(),
            vec![1, 2, 3],
            None,
            None,
            None,
        );
        let file_id = store.db.insert_item(&file_item).unwrap();
        store
            .indexer
            .add_document(
                file_id,
                &file_item.file_index_text().unwrap(),
                file_item.timestamp_unix,
            )
            .unwrap();
        store.indexer.commit().unwrap();

        let changes = store.pending_sync_changes(10).unwrap();
        assert_eq!(changes.len(), 1);
        match &changes[0].snapshot {
            SyncSnapshot::Live { snapshot } => {
                assert_eq!(
                    snapshot.content,
                    SyncContentPayload::Text {
                        value: "syncprobe backfill text".to_string(),
                    }
                );
            }
            other => panic!("expected live snapshot, got {other:?}"),
        }

        assert!(crate::sync_db::get_sync_shadow_by_item_id(&store.db, text_id)
            .unwrap()
            .is_some());
        assert!(crate::sync_db::get_sync_shadow_by_item_id(&store.db, file_id)
            .unwrap()
            .is_none());
    }

    #[tokio::test]
    async fn test_local_mutations_keep_database_and_index_in_sync() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let first_id = store
            .save_text("syncprobe local first".to_string(), None, None)
            .unwrap();
        let second_id = store
            .save_text("syncprobe local second".to_string(), None, None)
            .unwrap();

        assert_search_matches_db_for_query(&store, "syncprobe").await;

        store
            .update_text_item(first_id, "syncprobe local edited".to_string())
            .unwrap();
        assert!(search_ids(&store, "edited").await.contains(&first_id));
        assert_search_matches_db_for_query(&store, "syncprobe").await;

        store.delete_item(second_id).unwrap();
        assert!(search_ids(&store, "second").await.is_empty());
        assert_search_matches_db_for_query(&store, "syncprobe").await;

        store.rebuild_index().unwrap();
        assert_search_matches_db_for_query(&store, "syncprobe").await;
    }

    #[test]
    #[cfg(feature = "sync")]
    fn test_acknowledge_bookmark_and_delete_update_pending_sync_snapshot() {
        let store = ClipboardStore::new_in_memory().unwrap();
        let item_id = store
            .save_text("syncprobe sync row".to_string(), None, None)
            .unwrap();

        let pending = store.pending_sync_changes(10).unwrap();
        assert_eq!(pending.len(), 1);
        let global_item_id = match &pending[0].snapshot {
            SyncSnapshot::Live { snapshot } => snapshot.global_item_id.clone(),
            other => panic!("expected live snapshot, got {other:?}"),
        };

        store
            .acknowledge_sync_change_uploaded(
                global_item_id.clone(),
                Some("server-tag-1".to_string()),
            )
            .unwrap();
        assert!(store.pending_sync_changes(10).unwrap().is_empty());

        store.add_tag(item_id, ItemTag::Bookmark).unwrap();
        let pending = store.pending_sync_changes(10).unwrap();
        assert_eq!(pending.len(), 1);
        match &pending[0].snapshot {
            SyncSnapshot::Live { snapshot } => {
                assert_eq!(snapshot.global_item_id, global_item_id);
                assert!(snapshot.is_bookmarked);
            }
            other => panic!("expected live snapshot, got {other:?}"),
        }

        store.delete_item(item_id).unwrap();
        let pending = store.pending_sync_changes(10).unwrap();
        assert_eq!(pending.len(), 1);
        match &pending[0].snapshot {
            SyncSnapshot::Tombstone { snapshot } => {
                assert_eq!(snapshot.global_item_id, global_item_id);
            }
            other => panic!("expected tombstone snapshot, got {other:?}"),
        }
    }

    #[tokio::test]
    #[cfg(feature = "sync")]
    async fn test_remote_live_insert_and_activity_update_stay_in_sync() {
        let store = ClipboardStore::new_in_memory().unwrap();

        let device = "remote-a";
        store
            .apply_remote_sync_changes(vec![
                live_change(
                    "remote-alpha",
                    SyncContentPayload::Text {
                        value: "rankprobe alpha".to_string(),
                    },
                    100,
                    sync_version(1, device),
                    sync_version(0, device),
                    sync_version(1, device),
                    sync_version(0, device),
                ),
                live_change(
                    "remote-beta",
                    SyncContentPayload::Text {
                        value: "rankprobe beta".to_string(),
                    },
                    200,
                    sync_version(1, device),
                    sync_version(0, device),
                    sync_version(1, device),
                    sync_version(0, device),
                ),
            ])
            .unwrap();

        assert!(store.pending_sync_changes(10).unwrap().is_empty());
        assert_search_matches_db_for_query(&store, "rankprobe").await;

        let alpha_id = db_id_for_exact_text(&store, "rankprobe alpha");
        let beta_id = db_id_for_exact_text(&store, "rankprobe beta");
        assert_eq!(search_ids(&store, "").await[..2], [beta_id, alpha_id]);

        store
            .apply_remote_sync_changes(vec![live_change(
                "remote-alpha",
                SyncContentPayload::Text {
                    value: "rankprobe alpha".to_string(),
                },
                300,
                sync_version(1, device),
                sync_version(0, device),
                sync_version(2, device),
                sync_version(0, device),
            )])
            .unwrap();

        assert!(store.pending_sync_changes(10).unwrap().is_empty());
        assert_search_matches_db_for_query(&store, "rankprobe").await;
        assert_eq!(search_ids(&store, "").await[0], alpha_id);

        store.rebuild_index().unwrap();
        assert_search_matches_db_for_query(&store, "rankprobe").await;
        assert_eq!(search_ids(&store, "").await[0], alpha_id);
    }

    #[tokio::test]
    #[cfg(feature = "sync")]
    async fn test_remote_content_update_and_tombstone_update_sqlite_and_index_together() {
        let store = ClipboardStore::new_in_memory().unwrap();

        store
            .apply_remote_sync_changes(vec![live_change(
                "remote-doc",
                SyncContentPayload::Text {
                    value: "syncprobe oldterm".to_string(),
                },
                100,
                sync_version(1, "remote-a"),
                sync_version(0, "remote-a"),
                sync_version(1, "remote-a"),
                sync_version(0, "remote-a"),
            )])
            .unwrap();

        let item_id = db_id_for_exact_text(&store, "syncprobe oldterm");
        assert_eq!(search_ids(&store, "oldterm").await, vec![item_id]);

        store
            .apply_remote_sync_changes(vec![live_change(
                "remote-doc",
                SyncContentPayload::Text {
                    value: "syncprobe newterm".to_string(),
                },
                100,
                sync_version(2, "remote-b"),
                sync_version(0, "remote-a"),
                sync_version(1, "remote-a"),
                sync_version(0, "remote-a"),
            )])
            .unwrap();

        assert!(search_ids(&store, "oldterm").await.is_empty());
        assert_eq!(search_ids(&store, "newterm").await, vec![item_id]);
        assert_search_matches_db_for_query(&store, "syncprobe").await;

        store
            .apply_remote_sync_changes(vec![tombstone_change(
                "remote-doc",
                sync_version(2, "remote-b"),
                sync_version(1, "remote-b"),
            )])
            .unwrap();

        assert!(search_ids(&store, "newterm").await.is_empty());
        assert!(store.pending_sync_changes(10).unwrap().is_empty());
        assert_eq!(db_ids_matching_query(&store, "syncprobe"), BTreeSet::new());

        store.rebuild_index().unwrap();
        assert!(search_ids(&store, "newterm").await.is_empty());
    }

    #[tokio::test]
    #[cfg(feature = "sync")]
    async fn test_remote_conflicting_content_edit_forks_local_copy() {
        let store = ClipboardStore::new_in_memory().unwrap();

        store
            .apply_remote_sync_changes(vec![live_change(
                "shared-item",
                SyncContentPayload::Text {
                    value: "forkprobe seed".to_string(),
                },
                100,
                sync_version(1, "remote-a"),
                sync_version(0, "remote-a"),
                sync_version(1, "remote-a"),
                sync_version(0, "remote-a"),
            )])
            .unwrap();

        let shared_id = db_id_for_exact_text(&store, "forkprobe seed");
        store
            .update_text_item(shared_id, "forkprobe local edit".to_string())
            .unwrap();

        let report = store
            .apply_remote_sync_changes(vec![live_change(
                "shared-item",
                SyncContentPayload::Text {
                    value: "forkprobe remote edit".to_string(),
                },
                100,
                sync_version(2, "remote-b"),
                sync_version(0, "remote-a"),
                sync_version(1, "remote-a"),
                sync_version(0, "remote-a"),
            )])
            .unwrap();

        assert_eq!(report.applied_change_count, 1);
        assert_eq!(report.fork_count, 1);
        assert_search_matches_db_for_query(&store, "forkprobe").await;
        let remote_id = db_id_for_exact_text(&store, "forkprobe remote edit");
        let local_id = db_id_for_exact_text(&store, "forkprobe local edit");
        assert!(search_ids(&store, "forkprobe remote")
            .await
            .contains(&remote_id));
        assert!(search_ids(&store, "forkprobe local")
            .await
            .contains(&local_id));

        let pending = store.pending_sync_changes(10).unwrap();
        assert_eq!(pending.len(), 1);
        match &pending[0].snapshot {
            SyncSnapshot::Live { snapshot } => {
                assert_ne!(snapshot.global_item_id, "shared-item");
                assert_eq!(
                    snapshot.content,
                    SyncContentPayload::Text {
                        value: "forkprobe local edit".to_string(),
                    }
                );
            }
            other => panic!("expected forked live snapshot, got {other:?}"),
        }

        store.rebuild_index().unwrap();
        assert_search_matches_db_for_query(&store, "forkprobe").await;
    }
}
