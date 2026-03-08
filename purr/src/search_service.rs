use crate::database::Database;
use crate::indexer::Indexer;
use crate::interface::{
    ClipboardItem, ClipKittyError, ContentTypeFilter, ItemMatch, MatchData, SearchResult,
};
use crate::models::StoredItem;
use crate::search::{self, MIN_TRIGRAM_QUERY_LEN, MAX_RESULTS};
use std::sync::Arc;
use tokio_util::sync::CancellationToken;

/// Number of results to eagerly compute MatchData for (the rest are lazy).
const EAGER_MATCH_DATA_COUNT: usize = 25;
/// Content length threshold for "short" items that get eager highlights.
const SHORT_CONTENT_THRESHOLD: usize = 1024;
/// Skip eager short-item highlights when results exceed this count.
const EAGER_SHORT_RESULT_LIMIT: usize = 200;

pub(crate) struct SearchContext {
    pub(crate) db: Arc<Database>,
    pub(crate) indexer: Arc<Indexer>,
    pub(crate) runtime: tokio::runtime::Handle,
    pub(crate) token: CancellationToken,
}

pub(crate) async fn execute_search(
    context: SearchContext,
    query: String,
    filter: Option<ContentTypeFilter>,
) -> Result<SearchResult, ClipKittyError> {
    let trimmed = query.trim().to_string();
    if context.token.is_cancelled() {
        return Err(ClipKittyError::Cancelled);
    }

    if trimmed.is_empty() {
        return execute_empty_query(&context, filter.as_ref());
    }

    let SearchContext {
        db,
        indexer,
        runtime,
        token,
    } = context;
    let query_owned = query.clone();
    let trimmed_owned = trimmed.clone();
    let filter_copy = filter;
    let runtime_for_closure = runtime.clone();
    let db_for_closure = Arc::clone(&db);
    let indexer_for_closure = Arc::clone(&indexer);
    let token_for_closure = token.clone();

    let handle = runtime.spawn_blocking(move || {
        execute_search_sync(
            &db_for_closure,
            &indexer_for_closure,
            &query_owned,
            &trimmed_owned,
            filter_copy.as_ref(),
            &token_for_closure,
            &runtime_for_closure,
        )
    });

    let (matches, total_count) = match handle.await {
        Ok(Ok(result)) => result,
        Ok(Err(error)) => return Err(error),
        Err(_join_error) => return Err(ClipKittyError::Cancelled),
    };

    let first_item = fetch_first_item(
        &db,
        matches.first().map(|item| item.item_metadata.item_id),
        &token,
        &runtime,
    )?;

    Ok(SearchResult {
        matches,
        total_count,
        first_item,
    })
}

pub(crate) fn compute_highlights(
    db: &Database,
    item_ids: Vec<i64>,
    query: String,
) -> Result<Vec<MatchData>, ClipKittyError> {
    if item_ids.is_empty() {
        return Ok(Vec::new());
    }

    let items = db.fetch_items_by_ids(&item_ids)?;
    let item_map: std::collections::HashMap<i64, StoredItem> = items
        .into_iter()
        .filter_map(|item| item.id.map(|id| (id, item)))
        .collect();

    let trimmed = query.trim();
    let is_prefix_query = trimmed.len() < search::MIN_TRIGRAM_QUERY_LEN;

    use rayon::prelude::*;
    let results: Vec<MatchData> = item_ids
        .par_iter()
        .map(|id| {
            if let Some(item) = item_map.get(id) {
                let content = item.content.text_content();
                if is_prefix_query {
                    search::compute_prefix_match_data(content, trimmed.chars().count())
                } else {
                    search::compute_item_highlights(content, &query)
                }
            } else {
                MatchData::default()
            }
        })
        .collect();

    Ok(results)
}

pub(crate) fn search_short_query_sync(
    db: &Database,
    query: &str,
    token: &CancellationToken,
    runtime: &tokio::runtime::Handle,
    filter: Option<&ContentTypeFilter>,
) -> Result<Vec<ItemMatch>, ClipKittyError> {
    if token.is_cancelled() {
        return Err(ClipKittyError::Cancelled);
    }

    let candidates = db.search_prefix_query(query, MAX_RESULTS, filter)?;
    if candidates.is_empty() {
        return Ok(Vec::new());
    }

    if token.is_cancelled() {
        return Err(ClipKittyError::Cancelled);
    }

    let ids: Vec<i64> = candidates.iter().map(|(id, _, _)| *id).collect();
    let stored_items = db.fetch_items_by_ids_interruptible(&ids, token, runtime)?;
    let query_char_len = query.chars().count();

    let results: Vec<ItemMatch> = ids
        .iter()
        .filter_map(|id| {
            stored_items
                .iter()
                .find(|item| item.id == Some(*id))
                .map(|item| ItemMatch {
                    item_metadata: item.to_metadata(),
                    match_data: Some(search::compute_prefix_match_data(
                        item.content.text_content(),
                        query_char_len,
                    )),
                })
        })
        .collect();

    Ok(results)
}

pub(crate) fn search_trigram_query_sync(
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

    let fuzzy_matches = search::search_trigram_lazy(indexer, query, token)?;
    if fuzzy_matches.is_empty() {
        return Ok(Vec::new());
    }

    let ids: Vec<i64> = fuzzy_matches.iter().map(|m| m.id).collect();
    let stored_items = db.fetch_items_by_ids_interruptible(&ids, token, runtime)?;
    if token.is_cancelled() {
        return Err(ClipKittyError::Cancelled);
    }

    let item_map: std::collections::HashMap<i64, StoredItem> = stored_items
        .into_iter()
        .filter_map(|item| item.id.map(|id| (id, item)))
        .filter(|(_, item)| match filter {
            Some(filter) => filter.matches_db_type(item.content.database_type()),
            None => true,
        })
        .collect();

    let few_results = fuzzy_matches.len() <= EAGER_SHORT_RESULT_LIMIT;
    let results = fuzzy_matches
        .into_iter()
        .enumerate()
        .filter_map(|(index, fuzzy_match)| {
            item_map.get(&fuzzy_match.id).map(|item| {
                let content = item.content.text_content();
                let is_short = content.len() <= SHORT_CONTENT_THRESHOLD;
                if index < EAGER_MATCH_DATA_COUNT || (is_short && few_results) {
                    search::create_item_match(item, query)
                } else {
                    search::create_lazy_item_match(item)
                }
            })
        })
        .collect();

    Ok(results)
}

fn execute_empty_query(
    context: &SearchContext,
    filter: Option<&ContentTypeFilter>,
) -> Result<SearchResult, ClipKittyError> {
    let (items, total_count) = context.db.fetch_item_metadata(None, 1000, filter)?;
    let first_item = fetch_first_item(
        &context.db,
        items.first().map(|item| item.item_id),
        &context.token,
        &context.runtime,
    )?;
    let matches = items
        .into_iter()
        .map(|item_metadata| ItemMatch {
            item_metadata,
            match_data: None,
        })
        .collect();

    Ok(SearchResult {
        matches,
        total_count,
        first_item,
    })
}

fn execute_search_sync(
    db: &Database,
    indexer: &Indexer,
    query: &str,
    trimmed: &str,
    filter: Option<&ContentTypeFilter>,
    token: &CancellationToken,
    runtime: &tokio::runtime::Handle,
) -> Result<(Vec<ItemMatch>, u64), ClipKittyError> {
    let matches = if trimmed.len() < MIN_TRIGRAM_QUERY_LEN {
        search_short_query_sync(db, trimmed, token, runtime, filter)?
    } else {
        search_trigram_query_sync(db, indexer, query, token, runtime, filter)?
    };
    let total_count = matches.len() as u64;
    Ok((matches, total_count))
}

fn fetch_first_item(
    db: &Database,
    first_item_id: Option<i64>,
    token: &CancellationToken,
    runtime: &tokio::runtime::Handle,
) -> Result<Option<ClipboardItem>, ClipKittyError> {
    let Some(first_item_id) = first_item_id else {
        return Ok(None);
    };
    let item = db
        .fetch_items_by_ids_interruptible(&[first_item_id], token, runtime)?
        .into_iter()
        .next()
        .map(|item| item.to_clipboard_item());
    Ok(item)
}
