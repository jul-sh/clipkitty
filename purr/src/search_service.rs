use crate::database::Database;
use crate::indexer::Indexer;
use crate::interface::{
    ClipKittyError, ItemMatch, ItemQueryFilter, ListDecorationResult, ListPresentationProfile,
    PreviewPayload, SearchResult,
};
use crate::match_presentation::{HighlightAnalysisCache, MatchPresentation};
use crate::search;
use crate::search_result_builder::{uses_short_query_path, SearchResultAssembler, ShortQueryMode};
use std::sync::Arc;
use tokio_util::sync::CancellationToken;

#[cfg(test)]
use crate::interface::{ContentTypeFilter, ItemTag};

#[cfg(test)]
#[allow(unused_imports)]
pub(crate) mod test_support {
    pub(crate) use crate::match_presentation::test_support::*;
}

pub(crate) struct SearchContext {
    pub(crate) db: Arc<Database>,
    pub(crate) indexer: Arc<Indexer>,
    pub(crate) cache: Arc<HighlightAnalysisCache>,
    pub(crate) runtime: tokio::runtime::Handle,
    pub(crate) token: CancellationToken,
    pub(crate) presentation: ListPresentationProfile,
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

    let presentation = context.presentation;

    if parsed_query.raw_text().is_empty() {
        return SearchResultAssembler::new(
            &context.db,
            &context.cache,
            &context.token,
            &context.runtime,
            presentation,
        )
        .build_empty_query_result(filter);
    }

    let SearchContext {
        db,
        indexer,
        cache,
        runtime,
        token,
        presentation,
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
            presentation,
        )
    });

    let matches = match handle.await {
        Ok(Ok(result)) => result,
        Ok(Err(error)) => return Err(error),
        Err(_join_error) => return Err(ClipKittyError::Cancelled),
    };

    SearchResultAssembler::new(&db, &cache, &token, &runtime, presentation)
        .build_search_result(parsed_query.raw_text(), matches)
}

pub(crate) fn compute_list_decorations(
    db: &Database,
    cache: &HighlightAnalysisCache,
    item_ids: Vec<String>,
    query: String,
    presentation: ListPresentationProfile,
) -> Result<Vec<ListDecorationResult>, ClipKittyError> {
    MatchPresentation::new(db, cache).compute_list_decorations(item_ids, query, presentation)
}

pub(crate) fn load_preview_payload(
    db: &Database,
    cache: &HighlightAnalysisCache,
    item_id: String,
    query: String,
) -> Result<Option<PreviewPayload>, ClipKittyError> {
    MatchPresentation::new(db, cache).load_preview_payload(item_id, query)
}

#[cfg(test)]
#[allow(dead_code)]
pub(crate) fn search_short_query_sync(
    db: &Database,
    cache: &HighlightAnalysisCache,
    query: &str,
    mode: ShortQueryMode,
    token: &CancellationToken,
    runtime: &tokio::runtime::Handle,
    filter: Option<&ContentTypeFilter>,
    tag: Option<ItemTag>,
) -> Result<Vec<ItemMatch>, ClipKittyError> {
    SearchResultAssembler::new(
        db,
        cache,
        token,
        runtime,
        ListPresentationProfile::CompactRow,
    )
    .search_short_query(query, mode, filter, tag)
}

#[cfg(test)]
#[allow(dead_code)]
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
    SearchResultAssembler::new(
        db,
        cache,
        token,
        runtime,
        ListPresentationProfile::CompactRow,
    )
    .search_trigram_query(indexer, query, filter, tag)
}

fn execute_search_sync(
    db: &Database,
    indexer: &Indexer,
    cache: &HighlightAnalysisCache,
    parsed_query: &search::SearchQuery,
    filter: ItemQueryFilter,
    token: &CancellationToken,
    runtime: &tokio::runtime::Handle,
    presentation: ListPresentationProfile,
) -> Result<Vec<ItemMatch>, ClipKittyError> {
    let assembler = SearchResultAssembler::new(db, cache, token, runtime, presentation);
    let (content_type_filter, tag_filter) = crate::search_result_builder::split_filter(filter);

    if uses_short_query_path(parsed_query) {
        return match parsed_query {
            search::SearchQuery::Plain { text } => assembler.search_short_query(
                text,
                ShortQueryMode::PrefixThenContains,
                content_type_filter.as_ref(),
                tag_filter,
            ),
            search::SearchQuery::PreferPrefix { stripped_text, .. } => assembler
                .search_short_query(
                    stripped_text,
                    ShortQueryMode::PrefixOnly,
                    content_type_filter.as_ref(),
                    tag_filter,
                ),
        };
    }

    assembler.search_trigram_query(
        indexer,
        parsed_query,
        content_type_filter.as_ref(),
        tag_filter,
    )
}
