use crate::database::{Database, SearchItemMetadata};
use crate::interface::{
    ClipKittyError, ContentTypeFilter, ItemMatch, ItemMetadata, ItemQueryFilter, ItemTag,
    SearchResult,
};
use crate::match_presentation::{HighlightAnalysisCache, MatchPresentation};
use crate::models::StoredItem;
use crate::search::{self, MIN_TRIGRAM_QUERY_LEN};
use std::collections::{HashMap, HashSet};
use tokio_util::sync::CancellationToken;

/// Number of results to eagerly compute row decoration for (the rest are lazy).
const EAGER_MATCH_DATA_COUNT: usize = 1;
/// Content length threshold for "short" items that get eager row decoration.
const SHORT_CONTENT_THRESHOLD: usize = 1024;
/// Skip eager short-item decoration when results exceed this count.
const EAGER_SHORT_RESULT_LIMIT: usize = 0;
const SHORT_QUERY_MAX_RESULTS: usize = 50;
const SHORT_QUERY_RECENT_WINDOW: usize = 5000;
const SHORT_QUERY_CONTENT_CAP: usize = 512;

pub(crate) enum ShortQueryMode {
    PrefixThenContains,
    PrefixOnly,
}

pub(crate) struct SearchResultAssembler<'a> {
    db: &'a Database,
    cache: &'a HighlightAnalysisCache,
    token: &'a CancellationToken,
    runtime: &'a tokio::runtime::Handle,
}

impl<'a> SearchResultAssembler<'a> {
    pub(crate) fn new(
        db: &'a Database,
        cache: &'a HighlightAnalysisCache,
        token: &'a CancellationToken,
        runtime: &'a tokio::runtime::Handle,
    ) -> Self {
        Self {
            db,
            cache,
            token,
            runtime,
        }
    }

    pub(crate) fn build_empty_query_result(
        &self,
        filter: ItemQueryFilter,
    ) -> Result<SearchResult, ClipKittyError> {
        let (content_type_filter, tag_filter) = split_filter(filter);
        let (mut items, total_count) = self.db.fetch_item_metadata(
            None,
            1000,
            content_type_filter.as_ref(),
            tag_filter.as_ref(),
        )?;
        self.hydrate_item_metadata_tags(&mut items)?;
        let first_preview_payload = self.presentation().load_first_preview_payload(
            items.first().map(|item| item.item_id),
            "",
            self.token,
            self.runtime,
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

    pub(crate) fn build_search_result(
        &self,
        query: &str,
        mut matches: Vec<ItemMatch>,
    ) -> Result<SearchResult, ClipKittyError> {
        let total_count = matches.len() as u64;
        self.hydrate_item_match_tags(&mut matches)?;
        let first_preview_payload = self.presentation().load_first_preview_payload(
            matches.first().map(|item| item.item_metadata.item_id),
            query,
            self.token,
            self.runtime,
        )?;

        Ok(SearchResult {
            matches,
            total_count,
            first_preview_payload,
        })
    }

    pub(crate) fn search_short_query(
        &self,
        query: &str,
        mode: ShortQueryMode,
        filter: Option<&ContentTypeFilter>,
        tag: Option<ItemTag>,
    ) -> Result<Vec<ItemMatch>, ClipKittyError> {
        if self.token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }

        let query_lower = trimmed.to_lowercase();
        let mut ordered_ids = Vec::with_capacity(SHORT_QUERY_MAX_RESULTS);
        let mut prefix_ids = HashSet::new();
        let prefix_candidates =
            self.db
                .search_prefix_query(trimmed, SHORT_QUERY_MAX_RESULTS, filter, tag.as_ref())?;

        for (id, _, _) in prefix_candidates {
            if prefix_ids.insert(id) {
                ordered_ids.push(id);
            }
            if ordered_ids.len() >= SHORT_QUERY_MAX_RESULTS {
                break;
            }
        }

        if matches!(mode, ShortQueryMode::PrefixThenContains)
            && ordered_ids.len() < SHORT_QUERY_MAX_RESULTS
        {
            let recent_candidates = self.db.fetch_recent_items_for_short_query(
                SHORT_QUERY_RECENT_WINDOW,
                filter,
                tag.as_ref(),
            )?;
            for (id, content, _) in recent_candidates {
                if prefix_ids.contains(&id) {
                    continue;
                }
                let content_prefix: String =
                    content.chars().take(SHORT_QUERY_CONTENT_CAP).collect();
                if content_prefix.to_lowercase().contains(&query_lower) {
                    ordered_ids.push(id);
                }
                if ordered_ids.len() >= SHORT_QUERY_MAX_RESULTS {
                    break;
                }
            }
        }

        self.assemble_short_query_matches(&ordered_ids, trimmed)
    }

    pub(crate) fn search_trigram_query(
        &self,
        indexer: &crate::indexer::Indexer,
        query: &search::SearchQuery,
        filter: Option<&ContentTypeFilter>,
        tag: Option<ItemTag>,
    ) -> Result<Vec<ItemMatch>, ClipKittyError> {
        if self.token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let candidates = search::search_trigram_lazy(indexer, query, self.token)?;
        if candidates.is_empty() {
            return Ok(Vec::new());
        }

        let ids: Vec<i64> = candidates.iter().map(|candidate| candidate.id).collect();
        let metadata_rows = self.db.fetch_search_item_metadata_by_ids(&ids)?;
        if self.token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let tagged_ids = if let Some(tag) = tag {
            Some(
                self.db
                    .filter_ids_by_tag(&ids, tag)?
                    .into_iter()
                    .collect::<HashSet<_>>(),
            )
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
        let presentation = self.presentation();
        #[cfg(test)]
        crate::match_presentation::test_support::before_eager_matches();
        let mut results = Vec::with_capacity(metadata_map.len());
        let mut eager_index = 0usize;
        for candidate in candidates {
            if self.token.is_cancelled() {
                return Err(ClipKittyError::Cancelled);
            }
            let Some(metadata) = metadata_map.get(&candidate.id) else {
                continue;
            };
            presentation.cache_match_context(
                query.raw_text(),
                candidate.id,
                metadata.content_hash.clone(),
                candidate.match_context(),
                candidate.scoring_phase(),
            );

            let mut item_metadata = metadata.item_metadata.clone();
            presentation.apply_match_context_snippet(
                candidate.id,
                query.raw_text(),
                &mut item_metadata,
                candidate.match_context(),
            );
            let is_short = candidate.content().len() <= SHORT_CONTENT_THRESHOLD;
            let item_match = if eager_index < EAGER_MATCH_DATA_COUNT || (is_short && few_results) {
                #[cfg(test)]
                crate::match_presentation::test_support::on_eager_match(eager_index);
                if self.token.is_cancelled() {
                    return Err(ClipKittyError::Cancelled);
                }
                ItemMatch {
                    item_metadata,
                    row_decoration: Some(
                        presentation
                            .row_decoration_for_cached_match(candidate.id, query.raw_text()),
                    ),
                }
            } else {
                search::create_lazy_item_match_with_metadata(item_metadata)
            };
            if self.token.is_cancelled() {
                return Err(ClipKittyError::Cancelled);
            }
            results.push(item_match);
            eager_index += 1;
        }

        Ok(results)
    }

    fn assemble_short_query_matches(
        &self,
        ordered_ids: &[i64],
        query: &str,
    ) -> Result<Vec<ItemMatch>, ClipKittyError> {
        if ordered_ids.is_empty() {
            return Ok(Vec::new());
        }

        if self.token.is_cancelled() {
            return Err(ClipKittyError::Cancelled);
        }

        let stored_items =
            self.db
                .fetch_items_by_ids_interruptible(ordered_ids, self.token, self.runtime)?;
        let item_map: HashMap<i64, StoredItem> = stored_items
            .into_iter()
            .filter_map(|item| item.id.map(|id| (id, item)))
            .collect();
        let presentation = self.presentation();

        Ok(ordered_ids
            .iter()
            .filter_map(|id| {
                item_map.get(id).map(|item| ItemMatch {
                    item_metadata: item.to_metadata(),
                    row_decoration: Some(presentation.row_decoration_for_item(
                        *id,
                        item.content.text_content(),
                        query,
                    )),
                })
            })
            .collect())
    }

    fn hydrate_item_match_tags(&self, matches: &mut [ItemMatch]) -> Result<(), ClipKittyError> {
        let ids: Vec<i64> = matches
            .iter()
            .map(|item| item.item_metadata.item_id)
            .collect();
        let tags_by_id = self.db.get_tags_for_ids(&ids)?;
        for item in matches {
            item.item_metadata.tags = tags_by_id
                .get(&item.item_metadata.item_id)
                .cloned()
                .unwrap_or_default();
        }
        Ok(())
    }

    fn hydrate_item_metadata_tags(&self, items: &mut [ItemMetadata]) -> Result<(), ClipKittyError> {
        let ids: Vec<i64> = items.iter().map(|item| item.item_id).collect();
        let tags_by_id = self.db.get_tags_for_ids(&ids)?;
        for item in items {
            item.tags = tags_by_id.get(&item.item_id).cloned().unwrap_or_default();
        }
        Ok(())
    }

    fn presentation(&self) -> MatchPresentation<'_> {
        MatchPresentation::new(self.db, self.cache)
    }
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

pub(crate) fn uses_short_query_path(parsed_query: &search::SearchQuery) -> bool {
    parsed_query.recall_text().chars().count() < MIN_TRIGRAM_QUERY_LEN
}

pub(crate) fn split_filter(
    filter: ItemQueryFilter,
) -> (Option<ContentTypeFilter>, Option<ItemTag>) {
    match filter {
        ItemQueryFilter::All => (None, None),
        ItemQueryFilter::ContentType { content_type } => (Some(content_type), None),
        ItemQueryFilter::Tagged { tag } => (None, Some(tag)),
    }
}
