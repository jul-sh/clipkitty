use crate::candidate::SearchMatchContext;
use crate::database::{Database, SearchItemMetadata};
use crate::indexer::Indexer;
use crate::interface::{
    ClipKittyError, ClipboardItem, ContentTypeFilter, ItemMatch, ItemMetadata, ItemQueryFilter, ItemTag,
    PreviewPayload, RowDecoration, RowDecorationResult, SearchResult,
};
use crate::models::StoredItem;
use crate::search::{self, MIN_TRIGRAM_QUERY_LEN};
use parking_lot::Mutex;
use std::collections::{HashMap, HashSet, VecDeque};
use std::hash::{DefaultHasher, Hash, Hasher};
use std::sync::Arc;
use tokio_util::sync::CancellationToken;

#[cfg(test)]
pub(crate) mod test_support {
    use once_cell::sync::Lazy;
    use parking_lot::Mutex;
    use std::sync::Arc;

    #[derive(Default, Clone)]
    pub(crate) struct SearchTestHooks {
        pub(crate) before_eager_matches: Option<Arc<dyn Fn() + Send + Sync>>,
        pub(crate) on_eager_match: Option<Arc<dyn Fn(usize) + Send + Sync>>,
        pub(crate) on_analysis_cache_hit: Option<Arc<dyn Fn(i64, String) + Send + Sync>>,
        pub(crate) on_analysis_computed: Option<Arc<dyn Fn(i64, String) + Send + Sync>>,
    }

    static HOOKS: Lazy<Mutex<SearchTestHooks>> =
        Lazy::new(|| Mutex::new(SearchTestHooks::default()));

    pub(crate) struct SearchTestHookGuard;

    impl Drop for SearchTestHookGuard {
        fn drop(&mut self) {
            *HOOKS.lock() = SearchTestHooks::default();
        }
    }

    pub(crate) fn install_search_hooks(hooks: SearchTestHooks) -> SearchTestHookGuard {
        *HOOKS.lock() = hooks;
        SearchTestHookGuard
    }

    pub(crate) fn before_eager_matches() {
        let callback = HOOKS.lock().before_eager_matches.clone();
        if let Some(callback) = callback {
            callback();
        }
    }

    pub(crate) fn on_eager_match(index: usize) {
        let callback = HOOKS.lock().on_eager_match.clone();
        if let Some(callback) = callback {
            callback(index);
        }
    }

    pub(crate) fn on_analysis_cache_hit(item_id: i64, query: &str) {
        let callback = HOOKS.lock().on_analysis_cache_hit.clone();
        if let Some(callback) = callback {
            callback(item_id, query.to_string());
        }
    }

    pub(crate) fn on_analysis_computed(item_id: i64, query: &str) {
        let callback = HOOKS.lock().on_analysis_computed.clone();
        if let Some(callback) = callback {
            callback(item_id, query.to_string());
        }
    }
}

/// Number of results to eagerly compute row decoration for (the rest are lazy).
const EAGER_MATCH_DATA_COUNT: usize = 1;
/// Content length threshold for "short" items that get eager row decoration.
const SHORT_CONTENT_THRESHOLD: usize = 1024;
/// Skip eager short-item decoration when results exceed this count.
const EAGER_SHORT_RESULT_LIMIT: usize = 0;
const SHORT_QUERY_MAX_RESULTS: usize = 50;
const SHORT_QUERY_RECENT_WINDOW: usize = 5000;
const SHORT_QUERY_CONTENT_CAP: usize = 512;
const MAX_CACHED_QUERIES: usize = 4;
const MAX_CACHED_ITEMS_PER_QUERY: usize = 256;

#[derive(Clone)]
struct CachedHighlightAnalysis {
    content_hash: u64,
    analysis: Arc<search::HighlightAnalysis>,
}

#[derive(Clone)]
enum CachedMatchContext {
    WholeContent {
        parent_content_hash: String,
        content: Arc<str>,
        analysis: Option<Arc<search::HighlightAnalysis>>,
    },
    ChunkRegion {
        parent_content_hash: String,
        chunk_content: Arc<str>,
        chunk_start: usize,
        chunk_end: usize,
        analysis: Option<Arc<search::HighlightAnalysis>>,
    },
}

impl CachedMatchContext {
    fn from_search_match_context(
        parent_content_hash: String,
        match_context: &SearchMatchContext,
    ) -> Self {
        match match_context {
            SearchMatchContext::WholeItem(ctx) => Self::WholeContent {
                parent_content_hash,
                content: Arc::from(ctx.content()),
                analysis: None,
            },
            SearchMatchContext::Chunk(ctx) => Self::ChunkRegion {
                parent_content_hash,
                chunk_content: Arc::from(ctx.content()),
                chunk_start: ctx.chunk_start(),
                chunk_end: ctx.chunk_end(),
                analysis: None,
            },
        }
    }

    fn content(&self) -> &str {
        match self {
            Self::WholeContent { content, .. } => content,
            Self::ChunkRegion { chunk_content, .. } => chunk_content,
        }
    }

    fn analysis(&self) -> Option<Arc<search::HighlightAnalysis>> {
        match self {
            Self::WholeContent { analysis, .. } | Self::ChunkRegion { analysis, .. } => {
                analysis.clone()
            }
        }
    }

    fn set_analysis(&mut self, analysis: Arc<search::HighlightAnalysis>) {
        match self {
            Self::WholeContent {
                analysis: slot, ..
            }
            | Self::ChunkRegion {
                analysis: slot, ..
            } => *slot = Some(analysis),
        }
    }

    fn matches_parent_hash(&self, parent_content_hash: &str) -> bool {
        match self {
            Self::WholeContent {
                parent_content_hash: cached,
                ..
            }
            | Self::ChunkRegion {
                parent_content_hash: cached,
                ..
            } => cached == parent_content_hash,
        }
    }

    fn preview_decoration(
        &self,
        full_content: &str,
        analysis: &search::HighlightAnalysis,
    ) -> Option<crate::interface::PreviewDecoration> {
        match self {
            Self::WholeContent { .. } => Some(search::create_preview_decoration(full_content, analysis)),
            Self::ChunkRegion {
                chunk_start,
                chunk_end,
                ..
            } if *chunk_start <= *chunk_end
                && *chunk_end <= full_content.len()
                && full_content.is_char_boundary(*chunk_start)
                && full_content.is_char_boundary(*chunk_end) =>
            {
                let char_offset = full_content[..*chunk_start].chars().count();
                Some(search::create_preview_decoration_with_char_offset(
                    full_content,
                    analysis,
                    char_offset,
                ))
            }
            _ => None,
        }
    }
}

#[derive(Default)]
struct HighlightAnalysisCacheState {
    query_order: VecDeque<String>,
    entries_by_query: HashMap<String, HashMap<i64, CachedHighlightAnalysis>>,
    match_contexts_by_query: HashMap<String, HashMap<i64, CachedMatchContext>>,
}

#[derive(Default)]
pub(crate) struct HighlightAnalysisCache {
    state: Mutex<HighlightAnalysisCacheState>,
}

impl HighlightAnalysisCache {
    fn normalized_query(query: &str) -> Option<String> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return None;
        }
        Some(trimmed.to_string())
    }

    fn content_hash(content: &str) -> u64 {
        let mut hasher = DefaultHasher::new();
        content.hash(&mut hasher);
        hasher.finish()
    }

    fn touch_query(state: &mut HighlightAnalysisCacheState, query_key: &str) {
        if let Some(position) = state.query_order.iter().position(|entry| entry == query_key) {
            state.query_order.remove(position);
        }
        state.query_order.push_back(query_key.to_string());
        while state.query_order.len() > MAX_CACHED_QUERIES {
            if let Some(oldest) = state.query_order.pop_front() {
                state.entries_by_query.remove(&oldest);
                state.match_contexts_by_query.remove(&oldest);
            }
        }
    }

    fn get(&self, query: &str, item_id: i64, content: &str) -> Option<Arc<search::HighlightAnalysis>> {
        let query_key = Self::normalized_query(query)?;
        let content_hash = Self::content_hash(content);
        let mut state = self.state.lock();
        let cached = state
            .entries_by_query
            .get_mut(&query_key)
            .and_then(|entries| match entries.get(&item_id) {
                Some(entry) if entry.content_hash == content_hash => Some(Arc::clone(&entry.analysis)),
                Some(_) => {
                    entries.remove(&item_id);
                    None
                }
                None => None,
            });
        if cached.is_some() {
            Self::touch_query(&mut state, &query_key);
        }
        cached
    }

    fn insert(
        &self,
        query: &str,
        item_id: i64,
        content: &str,
        analysis: Arc<search::HighlightAnalysis>,
    ) {
        let Some(query_key) = Self::normalized_query(query) else {
            return;
        };
        let content_hash = Self::content_hash(content);
        let mut state = self.state.lock();
        Self::touch_query(&mut state, &query_key);
        let entries = state.entries_by_query.entry(query_key).or_default();
        if !entries.contains_key(&item_id) && entries.len() >= MAX_CACHED_ITEMS_PER_QUERY {
            return;
        }
        entries.insert(
            item_id,
            CachedHighlightAnalysis {
                content_hash,
                analysis,
            },
        );
    }

    fn get_match_context(&self, query: &str, item_id: i64) -> Option<CachedMatchContext> {
        let query_key = Self::normalized_query(query)?;
        let mut state = self.state.lock();
        let cached = state
            .match_contexts_by_query
            .get(&query_key)
            .and_then(|entries| entries.get(&item_id).cloned());
        if cached.is_some() {
            Self::touch_query(&mut state, &query_key);
        }
        cached
    }

    fn insert_match_context(
        &self,
        query: &str,
        item_id: i64,
        parent_content_hash: String,
        match_context: &SearchMatchContext,
    ) {
        let Some(query_key) = Self::normalized_query(query) else {
            return;
        };
        let mut state = self.state.lock();
        Self::touch_query(&mut state, &query_key);
        let entries = state.match_contexts_by_query.entry(query_key).or_default();
        if !entries.contains_key(&item_id) && entries.len() >= MAX_CACHED_ITEMS_PER_QUERY {
            return;
        }
        entries.insert(
            item_id,
            CachedMatchContext::from_search_match_context(parent_content_hash, match_context),
        );
    }

    fn set_match_context_analysis(
        &self,
        query: &str,
        item_id: i64,
        analysis: Arc<search::HighlightAnalysis>,
    ) {
        let Some(query_key) = Self::normalized_query(query) else {
            return;
        };
        let mut state = self.state.lock();
        let Some(entries) = state.match_contexts_by_query.get_mut(&query_key) else {
            return;
        };
        if let Some(entry) = entries.get_mut(&item_id) {
            entry.set_analysis(analysis);
            Self::touch_query(&mut state, &query_key);
        }
    }
}

pub(crate) struct SearchContext {
    pub(crate) db: Arc<Database>,
    pub(crate) indexer: Arc<Indexer>,
    pub(crate) cache: Arc<HighlightAnalysisCache>,
    pub(crate) runtime: tokio::runtime::Handle,
    pub(crate) token: CancellationToken,
}

pub(crate) async fn execute_search(
    context: SearchContext,
    query: String,
    filter: ItemQueryFilter,
) -> Result<SearchResult, ClipKittyError> {
    let parsed_query = search::SearchQuery::parse(&query);
    if context.token.is_cancelled() {
        return Err(ClipKittyError::Cancelled);
    }

    if parsed_query.raw_text().is_empty() {
        return execute_empty_query(&context, filter);
    }

    let SearchContext {
        db,
        indexer,
        cache,
        runtime,
        token,
    } = context;
    let parsed_query_owned = parsed_query.clone();
    let filter_copy = filter;
    let runtime_for_closure = runtime.clone();
    let db_for_closure = Arc::clone(&db);
    let indexer_for_closure = Arc::clone(&indexer);
    let cache_for_closure = Arc::clone(&cache);
    let token_for_closure = token.clone();

    let handle = runtime.spawn_blocking(move || {
        execute_search_sync(
            &db_for_closure,
            &indexer_for_closure,
            &cache_for_closure,
            &parsed_query_owned,
            filter_copy,
            &token_for_closure,
            &runtime_for_closure,
        )
    });

    let (matches, total_count) = match handle.await {
        Ok(Ok(result)) => result,
        Ok(Err(error)) => return Err(error),
        Err(_join_error) => return Err(ClipKittyError::Cancelled),
    };

    let first_preview_payload = fetch_preview_payload(
        &db,
        &cache,
        matches.first().map(|item| item.item_metadata.item_id),
        parsed_query.raw_text(),
        &token,
        &runtime,
    )?;

    Ok(SearchResult {
        matches,
        total_count,
        first_preview_payload,
    })
}

pub(crate) fn compute_row_decorations(
    db: &Database,
    cache: &HighlightAnalysisCache,
    item_ids: Vec<i64>,
    query: String,
) -> Result<Vec<RowDecorationResult>, ClipKittyError> {
    if item_ids.is_empty() {
        return Ok(Vec::new());
    }

    let metadata_rows = db.fetch_search_item_metadata_by_ids(&item_ids)?;
    let metadata_map: HashMap<i64, SearchItemMetadata> = metadata_rows
        .into_iter()
        .map(|metadata| (metadata.item_metadata.item_id, metadata))
        .collect();
    let missing_ids: Vec<i64> = item_ids
        .iter()
        .copied()
        .filter(|id| {
            let Some(metadata) = metadata_map.get(id) else {
                return true;
            };
            match cache.get_match_context(&query, *id) {
                Some(context) => !context.matches_parent_hash(&metadata.content_hash),
                None => true,
            }
        })
        .collect();
    let items = db.fetch_items_by_ids(&missing_ids)?;
    let item_map: HashMap<i64, StoredItem> = items
        .into_iter()
        .filter_map(|item| item.id.map(|id| (id, item)))
        .collect();

    use rayon::prelude::*;
    let results: Vec<RowDecorationResult> = item_ids
        .par_iter()
        .map(|id| {
            let cached_context = metadata_map.get(id).and_then(|metadata| {
                cache
                    .get_match_context(&query, *id)
                    .filter(|context| context.matches_parent_hash(&metadata.content_hash))
            });
            let decoration = if cached_context.is_some() {
                Some(row_decoration_for_cached_match(cache, *id, &query))
            } else {
                item_map.get(id).map(|item| {
                    let content = item.content.text_content();
                    row_decoration_for_item(cache, *id, content, &query)
                })
            };
            RowDecorationResult {
                item_id: *id,
                decoration,
            }
        })
        .collect();

    Ok(results)
}

pub(crate) fn load_preview_payload(
    db: &Database,
    cache: &HighlightAnalysisCache,
    item_id: i64,
    query: String,
) -> Result<Option<PreviewPayload>, ClipKittyError> {
    let Some(item) = db.fetch_items_by_ids(&[item_id])?.into_iter().next() else {
        return Ok(None);
    };
    Ok(Some(preview_payload_from_stored_item(
        cache, db, item_id, item, &query, true,
    )?))
}

pub(crate) fn search_short_query_sync(
    db: &Database,
    cache: &HighlightAnalysisCache,
    query: &str,
    prefix_only: bool,
    token: &CancellationToken,
    runtime: &tokio::runtime::Handle,
    filter: Option<&ContentTypeFilter>,
    tag: Option<ItemTag>,
) -> Result<Vec<ItemMatch>, ClipKittyError> {
    if token.is_cancelled() {
        return Err(ClipKittyError::Cancelled);
    }

    let trimmed = query.trim();
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }

    let query_lower = trimmed.to_lowercase();
    let mut ordered_ids = Vec::with_capacity(SHORT_QUERY_MAX_RESULTS);
    let mut prefix_ids = std::collections::HashSet::new();
    let prefix_candidates =
        db.search_prefix_query(trimmed, SHORT_QUERY_MAX_RESULTS, filter, tag.as_ref())?;

    for (id, _, _) in prefix_candidates {
        if prefix_ids.insert(id) {
            ordered_ids.push(id);
        }
        if ordered_ids.len() >= SHORT_QUERY_MAX_RESULTS {
            break;
        }
    }

    if !prefix_only && ordered_ids.len() < SHORT_QUERY_MAX_RESULTS {
        let recent_candidates =
            db.fetch_recent_items_for_short_query(SHORT_QUERY_RECENT_WINDOW, filter, tag.as_ref())?;
        for (id, content, _) in recent_candidates {
            if prefix_ids.contains(&id) {
                continue;
            }
            let content_prefix: String = content.chars().take(SHORT_QUERY_CONTENT_CAP).collect();
            if content_prefix.to_lowercase().contains(&query_lower) {
                ordered_ids.push(id);
            }
            if ordered_ids.len() >= SHORT_QUERY_MAX_RESULTS {
                break;
            }
        }
    }

    if ordered_ids.is_empty() {
        return Ok(Vec::new());
    }

    if token.is_cancelled() {
        return Err(ClipKittyError::Cancelled);
    }

    let stored_items = db.fetch_items_by_ids_interruptible(&ordered_ids, token, runtime)?;
    let item_map: HashMap<i64, StoredItem> = stored_items
        .into_iter()
        .filter_map(|item| item.id.map(|id| (id, item)))
        .collect();

    let results: Vec<ItemMatch> = ordered_ids
        .iter()
        .filter_map(|id| {
            item_map.get(id).map(|item| {
                let content = item.content.text_content();
                ItemMatch {
                    item_metadata: item.to_metadata(),
                    row_decoration: Some(row_decoration_for_item(cache, *id, content, trimmed)),
                }
            })
        })
        .collect();

    Ok(results)
}

fn metadata_matches_filter(
    metadata: &SearchItemMetadata,
    filter: Option<&ContentTypeFilter>,
) -> bool {
    match filter {
        Some(filter) => filter.matches_db_type(&metadata.db_type),
        None => true,
    }
}

fn apply_match_context_snippet(
    cache: &HighlightAnalysisCache,
    item_id: i64,
    query: &str,
    item_metadata: &mut ItemMetadata,
    match_context: &SearchMatchContext,
) {
    if matches!(match_context, SearchMatchContext::Chunk(_)) {
        item_metadata.snippet = analysis_for_cached_match_context(cache, item_id, query)
            .map(|(context, analysis)| {
                search::create_row_decoration(context.content(), &analysis.highlights).text
            })
            .unwrap_or_else(|| {
                search::generate_preview(match_context.content(), search::SNIPPET_CONTEXT_CHARS * 2)
            });
    }
}

pub(crate) fn search_trigram_query_sync(
    db: &Database,
    indexer: &Indexer,
    cache: &HighlightAnalysisCache,
    query: &search::SearchQuery,
    token: &CancellationToken,
    runtime: &tokio::runtime::Handle,
    filter: Option<&ContentTypeFilter>,
    tag: Option<ItemTag>,
) -> Result<Vec<ItemMatch>, ClipKittyError> {
    if token.is_cancelled() {
        return Err(ClipKittyError::Cancelled);
    }

    let candidates = search::search_trigram_lazy(indexer, query, token)?;
    if candidates.is_empty() {
        return Ok(Vec::new());
    }
    let _ = runtime;

    let ids: Vec<i64> = candidates.iter().map(|candidate| candidate.id).collect();
    let metadata_rows = db.fetch_search_item_metadata_by_ids(&ids)?;
    if token.is_cancelled() {
        return Err(ClipKittyError::Cancelled);
    }

    let tagged_ids = if let Some(tag) = tag {
        Some(db.filter_ids_by_tag(&ids, tag)?.into_iter().collect::<HashSet<_>>())
    } else {
        None
    };

    let metadata_map: HashMap<i64, SearchItemMetadata> = metadata_rows
        .into_iter()
        .filter(|metadata| match &tagged_ids {
            Some(tagged_ids) => tagged_ids.contains(&metadata.item_metadata.item_id),
            None => true,
        })
        .filter(|metadata| metadata_matches_filter(metadata, filter))
        .map(|metadata| (metadata.item_metadata.item_id, metadata))
        .collect();

    let few_results = metadata_map.len() <= EAGER_SHORT_RESULT_LIMIT;
    #[cfg(test)]
    test_support::before_eager_matches();
    let mut results = Vec::with_capacity(metadata_map.len());
    let mut eager_index = 0usize;
    for candidate in candidates {
        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }
        let Some(metadata) = metadata_map.get(&candidate.id) else {
            continue;
        };
        cache.insert_match_context(
            query.raw_text(),
            candidate.id,
            metadata.content_hash.clone(),
            candidate.match_context(),
        );

        let mut item_metadata = metadata.item_metadata.clone();
        apply_match_context_snippet(
            cache,
            candidate.id,
            query.raw_text(),
            &mut item_metadata,
            candidate.match_context(),
        );
        let is_short = candidate.content().len() <= SHORT_CONTENT_THRESHOLD;
        let item_match = if eager_index < EAGER_MATCH_DATA_COUNT || (is_short && few_results) {
            #[cfg(test)]
            test_support::on_eager_match(eager_index);
            if token.is_cancelled() {
                return Err(ClipKittyError::Cancelled);
            }
            ItemMatch {
                item_metadata,
                row_decoration: Some(row_decoration_for_cached_match(
                    cache,
                    candidate.id,
                    query.raw_text(),
                )),
            }
        } else {
            search::create_lazy_item_match_with_metadata(item_metadata)
        };
        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }
        results.push(item_match);
        eager_index += 1;
    }

    Ok(results)
}

fn execute_empty_query(
    context: &SearchContext,
    filter: ItemQueryFilter,
) -> Result<SearchResult, ClipKittyError> {
    let (content_type_filter, tag_filter) = split_filter(filter);
    let (mut items, total_count) = context.db.fetch_item_metadata(
        None,
        1000,
        content_type_filter.as_ref(),
        tag_filter.as_ref(),
    )?;
    hydrate_item_metadata_tags(&context.db, &mut items)?;
    let first_preview_payload = fetch_preview_payload(
        &context.db,
        &context.cache,
        items.first().map(|item| item.item_id),
        "",
        &context.token,
        &context.runtime,
    )?;
    let matches = items
        .into_iter()
        .map(|item_metadata| ItemMatch {
            item_metadata,
            row_decoration: None,
        })
        .collect();

    Ok(SearchResult {
        matches,
        total_count,
        first_preview_payload,
    })
}

fn execute_search_sync(
    db: &Database,
    indexer: &Indexer,
    cache: &HighlightAnalysisCache,
    parsed_query: &search::SearchQuery,
    filter: ItemQueryFilter,
    token: &CancellationToken,
    runtime: &tokio::runtime::Handle,
) -> Result<(Vec<ItemMatch>, u64), ClipKittyError> {
    let (content_type_filter, tag_filter) = split_filter(filter);
    let matches = if parsed_query.recall_text().len() < MIN_TRIGRAM_QUERY_LEN {
        match parsed_query {
            search::SearchQuery::Plain { text } => search_short_query_sync(
                db,
                cache,
                text,
                false,
                token,
                runtime,
                content_type_filter.as_ref(),
                tag_filter,
            )?,
            search::SearchQuery::PreferPrefix { stripped_text, .. } => search_short_query_sync(
                db,
                cache,
                stripped_text,
                true,
                token,
                runtime,
                content_type_filter.as_ref(),
                tag_filter,
            )?,
        }
    } else {
        search_trigram_query_sync(
            db,
            indexer,
            cache,
            parsed_query,
            token,
            runtime,
            content_type_filter.as_ref(),
            tag_filter,
        )?
    };
    let total_count = matches.len() as u64;
    let mut matches = matches;
    hydrate_item_match_tags(db, &mut matches)?;
    Ok((matches, total_count))
}

fn fetch_preview_payload(
    db: &Database,
    cache: &HighlightAnalysisCache,
    first_item_id: Option<i64>,
    query: &str,
    token: &CancellationToken,
    runtime: &tokio::runtime::Handle,
) -> Result<Option<PreviewPayload>, ClipKittyError> {
    let Some(first_item_id) = first_item_id else {
        return Ok(None);
    };
    if matches!(
        cache.get_match_context(query, first_item_id),
        Some(CachedMatchContext::ChunkRegion { .. })
    ) {
        return Ok(None);
    }
    let item = db
        .fetch_items_by_ids_interruptible(&[first_item_id], token, runtime)?
        .into_iter()
        .next();
    let Some(item) = item else {
        return Ok(None);
    };
    Ok(Some(preview_payload_from_stored_item(
        cache,
        db,
        first_item_id,
        item,
        query,
        false,
    )?))
}

fn split_filter(filter: ItemQueryFilter) -> (Option<ContentTypeFilter>, Option<ItemTag>) {
    match filter {
        ItemQueryFilter::All => (None, None),
        ItemQueryFilter::ContentType { content_type } => (Some(content_type), None),
        ItemQueryFilter::Tagged { tag } => (None, Some(tag)),
    }
}

fn hydrate_item_match_tags(db: &Database, matches: &mut [ItemMatch]) -> Result<(), ClipKittyError> {
    let ids: Vec<i64> = matches
        .iter()
        .map(|item| item.item_metadata.item_id)
        .collect();
    let tags_by_id = db.get_tags_for_ids(&ids)?;
    for item in matches {
        item.item_metadata.tags = tags_by_id
            .get(&item.item_metadata.item_id)
            .cloned()
            .unwrap_or_default();
    }
    Ok(())
}

fn hydrate_item_metadata_tags(
    db: &Database,
    items: &mut [crate::interface::ItemMetadata],
) -> Result<(), ClipKittyError> {
    let ids: Vec<i64> = items.iter().map(|item| item.item_id).collect();
    let tags_by_id = db.get_tags_for_ids(&ids)?;
    for item in items {
        item.tags = tags_by_id.get(&item.item_id).cloned().unwrap_or_default();
    }
    Ok(())
}

fn hydrate_clipboard_item_tags(
    db: &Database,
    item: &mut ClipboardItem,
) -> Result<(), ClipKittyError> {
    let tags_by_id = db.get_tags_for_ids(&[item.item_metadata.item_id])?;
    item.item_metadata.tags = tags_by_id
        .get(&item.item_metadata.item_id)
        .cloned()
        .unwrap_or_default();
    Ok(())
}

fn analysis_for_item(
    cache: &HighlightAnalysisCache,
    item_id: i64,
    content: &str,
    query: &str,
) -> Option<Arc<search::HighlightAnalysis>> {
    if let Some(cached) = cache.get(query, item_id, content) {
        #[cfg(test)]
        test_support::on_analysis_cache_hit(item_id, query);
        return Some(cached);
    }

    let analysis = search::analyze_content_for_query(content, query)?;
    #[cfg(test)]
    test_support::on_analysis_computed(item_id, query);
    let analysis = Arc::new(analysis);
    cache.insert(query, item_id, content, Arc::clone(&analysis));
    Some(analysis)
}

fn analysis_for_cached_match_context(
    cache: &HighlightAnalysisCache,
    item_id: i64,
    query: &str,
) -> Option<(CachedMatchContext, Arc<search::HighlightAnalysis>)> {
    let context = cache.get_match_context(query, item_id)?;
    if let Some(analysis) = context.analysis() {
        #[cfg(test)]
        test_support::on_analysis_cache_hit(item_id, query);
        return Some((context, analysis));
    }

    let analysis = search::analyze_content_for_query(context.content(), query)?;
    #[cfg(test)]
    test_support::on_analysis_computed(item_id, query);
    let analysis = Arc::new(analysis);
    cache.set_match_context_analysis(query, item_id, Arc::clone(&analysis));
    Some((cache.get_match_context(query, item_id).unwrap_or(context), analysis))
}

fn row_decoration_for_cached_match(
    cache: &HighlightAnalysisCache,
    item_id: i64,
    query: &str,
) -> RowDecoration {
    if let Some((context, analysis)) = analysis_for_cached_match_context(cache, item_id, query) {
        search::create_row_decoration(context.content(), &analysis.highlights)
    } else {
        RowDecoration {
            text: String::new(),
            highlights: Vec::new(),
            line_number: 0,
        }
    }
}

fn row_decoration_for_item(
    cache: &HighlightAnalysisCache,
    item_id: i64,
    content: &str,
    query: &str,
) -> RowDecoration {
    if let Some(analysis) = analysis_for_item(cache, item_id, content, query) {
        search::create_row_decoration(content, &analysis.highlights)
    } else {
        search::compute_row_decoration(content, query)
    }
}

fn preview_decoration_for_item(
    cache: &HighlightAnalysisCache,
    item_id: i64,
    item: &ClipboardItem,
    query: &str,
) -> Option<crate::interface::PreviewDecoration> {
    analysis_for_item(cache, item_id, item.content.text_content(), query)
        .map(|analysis| search::create_preview_decoration(item.content.text_content(), &analysis))
}

fn preview_payload_from_stored_item(
    cache: &HighlightAnalysisCache,
    db: &Database,
    item_id: i64,
    stored_item: StoredItem,
    query: &str,
    allow_large_chunk_decoration: bool,
) -> Result<PreviewPayload, ClipKittyError> {
    let parent_content_hash = stored_item.content_hash.clone();
    let mut item = stored_item.to_clipboard_item();
    hydrate_clipboard_item_tags(db, &mut item)?;

    let cached_match_context = cache
        .get_match_context(query, item_id)
        .filter(|context| context.matches_parent_hash(&parent_content_hash));
    if !allow_large_chunk_decoration
        && matches!(cached_match_context, Some(CachedMatchContext::ChunkRegion { .. }))
    {
        return Ok(PreviewPayload {
            item,
            decoration: None,
        });
    }

    let decoration = cached_match_context
        .and_then(|context| {
            let analysis = context.analysis().or_else(|| {
                let analysis = search::analyze_content_for_query(context.content(), query)?;
                #[cfg(test)]
                test_support::on_analysis_computed(item_id, query);
                let analysis = Arc::new(analysis);
                cache.set_match_context_analysis(query, item_id, Arc::clone(&analysis));
                Some(analysis)
            })?;
            #[cfg(test)]
            if context.analysis().is_some() {
                test_support::on_analysis_cache_hit(item_id, query);
            }
            context.preview_decoration(item.content.text_content(), &analysis)
        })
        .or_else(|| preview_decoration_for_item(cache, item_id, &item, query));

    Ok(PreviewPayload { item, decoration })
}
