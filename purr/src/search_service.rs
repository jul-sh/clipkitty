use crate::database::Database;
use crate::indexer::Indexer;
use crate::interface::{
    ClipKittyError, ClipboardItem, ContentTypeFilter, ItemMatch, ItemQueryFilter, ItemTag,
    MatchData, SearchResult,
};
use crate::models::StoredItem;
use crate::search::{self, MIN_TRIGRAM_QUERY_LEN};
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
    }

    static HOOKS: Lazy<Mutex<SearchTestHooks>> = Lazy::new(|| Mutex::new(SearchTestHooks::default()));

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
}

/// Number of results to eagerly compute MatchData for (the rest are lazy).
const EAGER_MATCH_DATA_COUNT: usize = 25;
/// Content length threshold for "short" items that get eager highlights.
const SHORT_CONTENT_THRESHOLD: usize = 1024;
/// Skip eager short-item highlights when results exceed this count.
const EAGER_SHORT_RESULT_LIMIT: usize = 200;
const SHORT_QUERY_MAX_RESULTS: usize = 50;
const SHORT_QUERY_RECENT_WINDOW: usize = 5000;
const SHORT_QUERY_CONTENT_CAP: usize = 512;

pub(crate) struct SearchContext {
    pub(crate) db: Arc<Database>,
    pub(crate) indexer: Arc<Indexer>,
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
        runtime,
        token,
    } = context;
    let parsed_query_owned = parsed_query.clone();
    let filter_copy = filter;
    let runtime_for_closure = runtime.clone();
    let db_for_closure = Arc::clone(&db);
    let indexer_for_closure = Arc::clone(&indexer);
    let token_for_closure = token.clone();

    let handle = runtime.spawn_blocking(move || {
        execute_search_sync(
            &db_for_closure,
            &indexer_for_closure,
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
                    search::compute_short_query_match_data(content, trimmed, true)
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
        let recent_candidates = db.fetch_recent_items_for_short_query(
            SHORT_QUERY_RECENT_WINDOW,
            filter,
            tag.as_ref(),
        )?;
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
    let item_map: std::collections::HashMap<i64, StoredItem> = stored_items
        .into_iter()
        .filter_map(|item| item.id.map(|id| (id, item)))
        .collect();

    let results: Vec<ItemMatch> = ordered_ids
        .iter()
        .filter_map(|id| {
            item_map.get(id).map(|item| {
                let content = item.content.text_content();
                let is_prefix = content.to_lowercase().starts_with(&query_lower);
                ItemMatch {
                    item_metadata: item.to_metadata(),
                    match_data: Some(search::compute_short_query_match_data(
                        content,
                        trimmed,
                        is_prefix,
                    )),
                }
            })
        })
        .collect();

    Ok(results)
}

pub(crate) fn search_trigram_query_sync(
    db: &Database,
    indexer: &Indexer,
    query: &search::SearchQuery,
    token: &CancellationToken,
    runtime: &tokio::runtime::Handle,
    filter: Option<&ContentTypeFilter>,
    tag: Option<ItemTag>,
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

    let tagged_ids = if let Some(tag) = tag {
        Some(
            db.filter_ids_by_tag(&ids, tag)?
                .into_iter()
                .collect::<std::collections::HashSet<_>>(),
        )
    } else {
        None
    };

    let item_map: std::collections::HashMap<i64, StoredItem> = stored_items
        .into_iter()
        .filter_map(|item| item.id.map(|id| (id, item)))
        .filter(|(id, _)| match &tagged_ids {
            Some(tagged_ids) => tagged_ids.contains(id),
            None => true,
        })
        .filter(|(_, item)| match filter {
            Some(filter) => filter.matches_db_type(item.content.database_type()),
            None => true,
        })
        .collect();

    let few_results = fuzzy_matches.len() <= EAGER_SHORT_RESULT_LIMIT;
    #[cfg(test)]
    test_support::before_eager_matches();
    let mut results = Vec::with_capacity(fuzzy_matches.len());
    for (index, fuzzy_match) in fuzzy_matches.into_iter().enumerate() {
        if token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }
        let Some(item) = item_map.get(&fuzzy_match.id) else {
            continue;
        };
        let content = item.content.text_content();
        let is_short = content.len() <= SHORT_CONTENT_THRESHOLD;
        let item_match = if index < EAGER_MATCH_DATA_COUNT || (is_short && few_results) {
            #[cfg(test)]
            test_support::on_eager_match(index);
            search::create_item_match(item, query.raw_text())
        } else {
            search::create_lazy_item_match(item)
        };
        results.push(item_match);
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
                text,
                false,
                token,
                runtime,
                content_type_filter.as_ref(),
                tag_filter,
            )?,
            search::SearchQuery::PreferPrefix { stripped_text, .. } => search_short_query_sync(
                db,
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
    let mut item = item;
    if let Some(item) = item.as_mut() {
        hydrate_clipboard_item_tags(db, item)?;
    }
    Ok(item)
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
