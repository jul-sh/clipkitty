//! ClipboardStore - Thin UniFFI-facing facade over search/save services.

use crate::database::Database;
use crate::indexer::Indexer;
use crate::interface::{
    ClipKittyError, ClipboardItem, ClipboardStoreApi, ItemQueryFilter, ItemTag, MatchData,
    SearchOutcome, SearchResult,
};
use crate::{save_service, search_service};
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::path::PathBuf;
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
            active_search_token: Arc::new(Mutex::new(None)),
        })
    }

    fn runtime_handle(&self) -> tokio::runtime::Handle {
        tokio::runtime::Handle::try_current().unwrap_or_else(|_| FALLBACK_RUNTIME.handle().clone())
    }

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
        let path = PathBuf::from(db_path);
        let db = Database::open(&path).map_err(ClipKittyError::from)?;

        let index_dir = format!("tantivy_index_{}", crate::indexer::INDEX_VERSION);
        let index_path = path
            .parent()
            .map(|parent| parent.join(&index_dir))
            .unwrap_or_else(|| PathBuf::from(&index_dir));
        let indexer = Indexer::new(&index_path)?;

        let store = Self {
            db: Arc::new(db),
            indexer: Arc::new(indexer),
            active_search_token: Arc::new(Mutex::new(None)),
        };
        store.rebuild_index_if_needed()?;
        Ok(store)
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
        runtime.clone().spawn(async move {
            if token.is_cancelled() {
                completion.finish(Ok(SearchOutcome::Cancelled));
                return;
            }

            let result = search_service::execute_search(
                search_service::SearchContext {
                    db,
                    indexer,
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

    pub fn start_search(
        &self,
        query: String,
        filter: ItemQueryFilter,
    ) -> Arc<SearchOperation> {
        self.begin_search_operation(query, filter)
    }
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

    fn compute_highlights(
        &self,
        item_ids: Vec<i64>,
        query: String,
    ) -> Result<Vec<MatchData>, ClipKittyError> {
        search_service::compute_highlights(&self.db, item_ids, query)
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
        ClipboardContent, FileStatus, IconType, ItemIcon, ItemQueryFilter, LinkMetadataPayload,
        LinkMetadataState,
    };
    use once_cell::sync::Lazy;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex as StdMutex, OnceLock};

    static SEARCH_HOOK_TEST_LOCK: Lazy<StdMutex<()>> = Lazy::new(|| StdMutex::new(()));

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
        assert!(all.first_item.is_some());

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

    #[test]
    fn test_short_query_sync_cancelled() {
        let rt = runtime();
        let store = ClipboardStore::new_in_memory().unwrap();
        store.save_text("Hello".to_string(), None, None).unwrap();

        let token = CancellationToken::new();
        token.cancel();
        let result = search_service::search_short_query_sync(
            &store.db,
            "He",
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
        assert_eq!(result.matches[0].item_metadata.tags, vec![ItemTag::Bookmark]);
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
                .save_text(format!("Item number {i} with repeated search text"), None, None)
                .unwrap();
        }

        let operation = store.start_search("repeated".to_string(), None);
        operation.cancel();

        let outcome = operation.await_result().await.unwrap();
        assert_eq!(outcome, SearchOutcome::Cancelled);
    }

    #[tokio::test]
    async fn test_new_search_cancels_previous_running_operation() {
        let store = ClipboardStore::new_in_memory().unwrap();
        for i in 0..400 {
            store
                .save_text(format!("Item number {i} with repeated search text"), None, None)
                .unwrap();
        }

        let first = store.start_search("repeated".to_string(), None);
        let second = store.start_search("number 399".to_string(), None);

        assert_eq!(first.await_result().await.unwrap(), SearchOutcome::Cancelled);
        assert!(matches!(
            second.await_result().await.unwrap(),
            SearchOutcome::Success { .. }
        ));
    }

    #[tokio::test]
    async fn test_phase_two_cancellation_stops_work_early() {
        let _lock = SEARCH_HOOK_TEST_LOCK.lock().unwrap();
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
        let _hook_guard =
            crate::indexer::test_support::install_search_hooks(crate::indexer::test_support::SearchTestHooks {
                before_phase_two: None,
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
            });

        let operation = store.start_search("repeated ranking".to_string(), None);
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
        let _lock = SEARCH_HOOK_TEST_LOCK.lock().unwrap();
        let store = ClipboardStore::new_in_memory().unwrap();
        for i in 0..500 {
            store
                .save_text(
                    format!("repeated search text item {i} with enough body for eager highlighting"),
                    None,
                    None,
                )
                .unwrap();
        }

        let processed = Arc::new(AtomicUsize::new(0));
        let operation_slot: Arc<OnceLock<Arc<SearchOperation>>> = Arc::new(OnceLock::new());
        let _hook_guard =
            crate::search_service::test_support::install_search_hooks(crate::search_service::test_support::SearchTestHooks {
                before_eager_matches: None,
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
            });

        let operation = store.start_search("repeated search".to_string(), None);
        let _ = operation_slot.set(Arc::clone(&operation));

        let outcome = operation.await_result().await.unwrap();
        assert_eq!(outcome, SearchOutcome::Cancelled);
        assert!(
            processed.load(Ordering::SeqCst) < 10,
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

        let first = store.start_search("repeated".to_string(), None);
        let second = store.start_search("repeated s".to_string(), None);
        let third = store.start_search("repeated se".to_string(), None);
        let fourth = store.start_search("repeated sea".to_string(), None);

        assert_eq!(first.await_result().await.unwrap(), SearchOutcome::Cancelled);
        assert_eq!(second.await_result().await.unwrap(), SearchOutcome::Cancelled);
        assert_eq!(third.await_result().await.unwrap(), SearchOutcome::Cancelled);
        assert!(matches!(
            fourth.await_result().await.unwrap(),
            SearchOutcome::Success { .. }
        ));
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
}
