use crate::candidate::{ScoringPhase, SearchMatchContext};
use crate::database::{Database, SearchItemMetadata};
use crate::interface::{
    ClipKittyError, ClipboardItem, ItemMetadata, ListDecoration, ListDecorationResult,
    ListPresentationProfile, PreviewPayload,
};
use crate::models::StoredItem;
use crate::search::{self, HighlightAnalysis};
use parking_lot::Mutex;
use std::collections::{HashMap, VecDeque};
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

const MAX_CACHED_QUERIES: usize = 4;
const MAX_CACHED_ITEMS_PER_QUERY: usize = 256;

#[derive(Clone)]
struct CachedHighlightAnalysis {
    content_hash: u64,
    analysis: Arc<HighlightAnalysis>,
}

/// What kind of highlight analysis to use for this match context.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum HighlightStrategy {
    /// Full analysis: fuzzy, subsequence, subword matching (Phase 2 items).
    Full,
    /// Exact + prefix word matching only (Phase 1-only tail items).
    WordMatch,
}

/// Whether highlights have been computed yet.
#[derive(Clone)]
pub(crate) enum HighlightReadiness {
    Pending,
    Ready(Arc<HighlightAnalysis>),
}

#[derive(Clone)]
pub(crate) enum CachedMatchContext {
    WholeContent {
        parent_content_hash: String,
        content: Arc<str>,
        strategy: HighlightStrategy,
        readiness: HighlightReadiness,
    },
    ChunkRegion {
        parent_content_hash: String,
        chunk_content: Arc<str>,
        chunk_start: usize,
        chunk_end: usize,
        strategy: HighlightStrategy,
        readiness: HighlightReadiness,
    },
}

impl CachedMatchContext {
    fn from_search_match_context(
        parent_content_hash: String,
        match_context: &SearchMatchContext,
        scoring_phase: ScoringPhase,
    ) -> Self {
        let strategy = match scoring_phase {
            ScoringPhase::PhaseTwoScored => HighlightStrategy::Full,
            ScoringPhase::PhaseOneOnly => HighlightStrategy::WordMatch,
        };
        match match_context {
            SearchMatchContext::WholeItem(ctx) => Self::WholeContent {
                parent_content_hash,
                content: Arc::from(ctx.content()),
                strategy,
                readiness: HighlightReadiness::Pending,
            },
            SearchMatchContext::Chunk(ctx) => Self::ChunkRegion {
                parent_content_hash,
                chunk_content: Arc::from(ctx.content()),
                chunk_start: ctx.chunk_start(),
                chunk_end: ctx.chunk_end(),
                strategy,
                readiness: HighlightReadiness::Pending,
            },
        }
    }

    fn content(&self) -> &str {
        match self {
            Self::WholeContent { content, .. } => content,
            Self::ChunkRegion { chunk_content, .. } => chunk_content,
        }
    }

    fn strategy(&self) -> HighlightStrategy {
        match self {
            Self::WholeContent { strategy, .. } | Self::ChunkRegion { strategy, .. } => *strategy,
        }
    }

    fn analysis(&self) -> Option<Arc<HighlightAnalysis>> {
        match self {
            Self::WholeContent { readiness, .. } | Self::ChunkRegion { readiness, .. } => {
                match readiness {
                    HighlightReadiness::Ready(analysis) => Some(Arc::clone(analysis)),
                    HighlightReadiness::Pending => None,
                }
            }
        }
    }

    fn set_analysis(&mut self, analysis: Arc<HighlightAnalysis>) {
        match self {
            Self::WholeContent {
                readiness: slot, ..
            }
            | Self::ChunkRegion {
                readiness: slot, ..
            } => *slot = HighlightReadiness::Ready(analysis),
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
        analysis: &HighlightAnalysis,
    ) -> Option<crate::interface::PreviewDecoration> {
        match self {
            Self::WholeContent { .. } => {
                Some(search::create_preview_decoration(full_content, analysis))
            }
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
        if let Some(position) = state
            .query_order
            .iter()
            .position(|entry| entry == query_key)
        {
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

    pub(crate) fn get(
        &self,
        query: &str,
        item_id: i64,
        content: &str,
    ) -> Option<Arc<HighlightAnalysis>> {
        let query_key = Self::normalized_query(query)?;
        let content_hash = Self::content_hash(content);
        let mut state = self.state.lock();
        let cached = state
            .entries_by_query
            .get_mut(&query_key)
            .and_then(|entries| match entries.get(&item_id) {
                Some(entry) if entry.content_hash == content_hash => {
                    Some(Arc::clone(&entry.analysis))
                }
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

    pub(crate) fn insert(
        &self,
        query: &str,
        item_id: i64,
        content: &str,
        analysis: Arc<HighlightAnalysis>,
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

    pub(crate) fn get_match_context(
        &self,
        query: &str,
        item_id: i64,
    ) -> Option<CachedMatchContext> {
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

    pub(crate) fn insert_match_context(
        &self,
        query: &str,
        item_id: i64,
        parent_content_hash: String,
        match_context: &SearchMatchContext,
        scoring_phase: ScoringPhase,
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
            CachedMatchContext::from_search_match_context(
                parent_content_hash,
                match_context,
                scoring_phase,
            ),
        );
    }

    pub(crate) fn set_match_context_analysis(
        &self,
        query: &str,
        item_id: i64,
        analysis: Arc<HighlightAnalysis>,
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

pub(crate) enum PreviewLoadMode {
    InitialSearch,
    ExplicitPreview,
}

pub(crate) struct MatchPresentation<'a> {
    db: &'a Database,
    cache: &'a HighlightAnalysisCache,
}

impl<'a> MatchPresentation<'a> {
    pub(crate) fn new(db: &'a Database, cache: &'a HighlightAnalysisCache) -> Self {
        Self { db, cache }
    }

    pub(crate) fn compute_list_decorations(
        &self,
        item_ids: Vec<i64>,
        query: String,
        profile: ListPresentationProfile,
    ) -> Result<Vec<ListDecorationResult>, ClipKittyError> {
        if item_ids.is_empty() {
            return Ok(Vec::new());
        }

        let metadata_rows = self.db.fetch_search_item_metadata_by_ids(&item_ids)?;
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
                match self.cache.get_match_context(&query, *id) {
                    Some(context) => !context.matches_parent_hash(&metadata.content_hash),
                    None => true,
                }
            })
            .collect();
        let items = self.db.fetch_items_by_ids(&missing_ids)?;
        let item_map: HashMap<i64, StoredItem> = items
            .into_iter()
            .filter_map(|item| item.id.map(|id| (id, item)))
            .collect();

        use rayon::prelude::*;
        Ok(item_ids
            .par_iter()
            .map(|id| {
                let cached_context = metadata_map.get(id).and_then(|metadata| {
                    self.cache
                        .get_match_context(&query, *id)
                        .filter(|context| context.matches_parent_hash(&metadata.content_hash))
                });
                let decoration = if cached_context.is_some() {
                    Some(self.list_decoration_for_cached_match(*id, &query, profile))
                } else {
                    item_map.get(id).map(|item| {
                        self.list_decoration_for_item(
                            *id,
                            item.content.text_content(),
                            &query,
                            profile,
                        )
                    })
                };
                ListDecorationResult {
                    item_id: *id,
                    decoration,
                }
            })
            .collect())
    }

    pub(crate) fn load_preview_payload(
        &self,
        item_id: i64,
        query: String,
    ) -> Result<Option<PreviewPayload>, ClipKittyError> {
        let Some(item) = self.db.fetch_items_by_ids(&[item_id])?.into_iter().next() else {
            return Ok(None);
        };
        Ok(Some(self.preview_payload_from_stored_item(
            item_id,
            item,
            &query,
            PreviewLoadMode::ExplicitPreview,
        )?))
    }

    pub(crate) fn load_first_preview_payload(
        &self,
        first_item_id: Option<i64>,
        query: &str,
        token: &CancellationToken,
        runtime: &tokio::runtime::Handle,
    ) -> Result<Option<PreviewPayload>, ClipKittyError> {
        let Some(first_item_id) = first_item_id else {
            return Ok(None);
        };
        if matches!(
            self.cache.get_match_context(query, first_item_id),
            Some(CachedMatchContext::ChunkRegion { .. })
        ) {
            return Ok(None);
        }
        let item = self
            .db
            .fetch_items_by_ids_interruptible(&[first_item_id], token, runtime)?
            .into_iter()
            .next();
        let Some(item) = item else {
            return Ok(None);
        };
        Ok(Some(self.preview_payload_from_stored_item(
            first_item_id,
            item,
            query,
            PreviewLoadMode::InitialSearch,
        )?))
    }

    pub(crate) fn cache_match_context(
        &self,
        query: &str,
        item_id: i64,
        parent_content_hash: String,
        match_context: &SearchMatchContext,
        scoring_phase: ScoringPhase,
    ) {
        self.cache.insert_match_context(
            query,
            item_id,
            parent_content_hash,
            match_context,
            scoring_phase,
        );
    }

    pub(crate) fn apply_match_context_snippet(
        &self,
        item_id: i64,
        query: &str,
        item_metadata: &mut ItemMetadata,
        match_context: &SearchMatchContext,
        profile: ListPresentationProfile,
    ) {
        if matches!(match_context, SearchMatchContext::Chunk(_)) {
            item_metadata.snippet = self
                .analysis_for_cached_match_context(item_id, query)
                .map(|(context, analysis)| {
                    search::create_list_decoration(
                        context.content(),
                        &analysis.highlights,
                        profile,
                    )
                    .text
                })
                .unwrap_or_else(|| {
                    search::generate_preview_for_profile(match_context.content(), profile)
                });
        }
    }

    pub(crate) fn list_decoration_for_cached_match(
        &self,
        item_id: i64,
        query: &str,
        profile: ListPresentationProfile,
    ) -> ListDecoration {
        if let Some((context, analysis)) = self.analysis_for_cached_match_context(item_id, query) {
            search::create_list_decoration(context.content(), &analysis.highlights, profile)
        } else {
            ListDecoration {
                text: String::new(),
                highlights: Vec::new(),
                line_number: 0,
            }
        }
    }

    pub(crate) fn list_decoration_for_item(
        &self,
        item_id: i64,
        content: &str,
        query: &str,
        profile: ListPresentationProfile,
    ) -> ListDecoration {
        if let Some(analysis) = self.analysis_for_item(item_id, content, query) {
            search::create_list_decoration(content, &analysis.highlights, profile)
        } else {
            search::compute_list_decoration(content, query, profile)
        }
    }

    fn preview_payload_from_stored_item(
        &self,
        item_id: i64,
        stored_item: StoredItem,
        query: &str,
        mode: PreviewLoadMode,
    ) -> Result<PreviewPayload, ClipKittyError> {
        let parent_content_hash = stored_item.content_hash.clone();
        let mut item = stored_item.to_clipboard_item();
        hydrate_clipboard_item_tags(self.db, &mut item)?;

        let cached_match_context = self
            .cache
            .get_match_context(query, item_id)
            .filter(|context| context.matches_parent_hash(&parent_content_hash));
        if matches!(
            (mode, cached_match_context.as_ref()),
            (
                PreviewLoadMode::InitialSearch,
                Some(CachedMatchContext::ChunkRegion { .. })
            )
        ) {
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
                    self.cache
                        .set_match_context_analysis(query, item_id, Arc::clone(&analysis));
                    Some(analysis)
                })?;
                #[cfg(test)]
                if context.analysis().is_some() {
                    test_support::on_analysis_cache_hit(item_id, query);
                }
                context.preview_decoration(item.content.text_content(), &analysis)
            })
            .or_else(|| self.preview_decoration_for_item(item_id, &item, query));

        Ok(PreviewPayload { item, decoration })
    }

    fn preview_decoration_for_item(
        &self,
        item_id: i64,
        item: &ClipboardItem,
        query: &str,
    ) -> Option<crate::interface::PreviewDecoration> {
        self.analysis_for_item(item_id, item.content.text_content(), query)
            .map(|analysis| {
                search::create_preview_decoration(item.content.text_content(), &analysis)
            })
    }

    fn analysis_for_item(
        &self,
        item_id: i64,
        content: &str,
        query: &str,
    ) -> Option<Arc<HighlightAnalysis>> {
        if let Some(cached) = self.cache.get(query, item_id, content) {
            #[cfg(test)]
            test_support::on_analysis_cache_hit(item_id, query);
            return Some(cached);
        }

        let analysis = search::analyze_content_for_query(content, query)?;
        #[cfg(test)]
        test_support::on_analysis_computed(item_id, query);
        let analysis = Arc::new(analysis);
        self.cache
            .insert(query, item_id, content, Arc::clone(&analysis));
        Some(analysis)
    }

    fn analysis_for_cached_match_context(
        &self,
        item_id: i64,
        query: &str,
    ) -> Option<(CachedMatchContext, Arc<HighlightAnalysis>)> {
        let context = self.cache.get_match_context(query, item_id)?;
        if let Some(analysis) = context.analysis() {
            #[cfg(test)]
            test_support::on_analysis_cache_hit(item_id, query);
            return Some((context, analysis));
        }

        let analysis = match context.strategy() {
            HighlightStrategy::Full => search::analyze_content_for_query(context.content(), query),
            HighlightStrategy::WordMatch => {
                search::analyze_content_word_match(context.content(), query)
            }
        }?;
        #[cfg(test)]
        test_support::on_analysis_computed(item_id, query);
        let analysis = Arc::new(analysis);
        self.cache
            .set_match_context_analysis(query, item_id, Arc::clone(&analysis));
        Some((
            self.cache
                .get_match_context(query, item_id)
                .unwrap_or(context),
            analysis,
        ))
    }
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
