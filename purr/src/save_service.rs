use crate::database::Database;
use crate::indexer::Indexer;
use crate::interface::{ClipKittyError, ItemTag, LinkMetadataPayload, LinkMetadataState};
use crate::models::StoredItem;
use chrono::Utc;

// ═══════════════════════════════════════════════════════════════════════════════
// Outcome types — callers use these to decide what sync events to emit.
// ═══════════════════════════════════════════════════════════════════════════════

/// Outcome of a save operation that may deduplicate.
#[allow(dead_code)]
pub(crate) enum InsertOutcome {
    /// A duplicate was found; the existing item was touched.
    Deduplicated {
        existing_id: i64,
        touched_at_unix: i64,
    },
    /// A new item was inserted.
    Inserted {
        new_id: i64,
        item: StoredItem,
    },
}

impl InsertOutcome {
    /// Return the FFI-facing id (0 for dedupe, positive for new).
    pub(crate) fn ffi_id(&self) -> i64 {
        match self {
            InsertOutcome::Deduplicated { .. } => 0,
            InsertOutcome::Inserted { new_id, .. } => *new_id,
        }
    }
}

/// Outcome of a re-indexing operation.
pub(crate) enum ReindexOutcome {
    /// Indexing succeeded.
    Indexed,
    /// Indexing failed; the search index is now stale.
    IndexFailed,
}

/// Resolved link metadata fields after normalization.
#[allow(dead_code)]
pub(crate) struct ResolvedLinkMetadata {
    pub title: Option<String>,
    pub description: Option<String>,
    pub image_data: Option<Vec<u8>>,
}

/// Outcome of a prune operation.
#[allow(dead_code)]
pub(crate) struct PruneOutcome {
    pub deleted_ids: Vec<i64>,
    pub bytes_freed: u64,
}

// ═══════════════════════════════════════════════════════════════════════════════
// Save operations — pure local mutations (DB + indexer).
// ═══════════════════════════════════════════════════════════════════════════════

pub(crate) fn save_text(
    db: &Database,
    indexer: &Indexer,
    text: String,
    source_app: Option<String>,
    source_app_bundle_id: Option<String>,
) -> Result<InsertOutcome, ClipKittyError> {
    let item = StoredItem::new_text(text, source_app, source_app_bundle_id);
    dedupe_or_insert_and_index(db, indexer, item)
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn save_file(
    db: &Database,
    indexer: &Indexer,
    path: String,
    filename: String,
    file_size: u64,
    uti: String,
    bookmark_data: Vec<u8>,
    thumbnail: Option<Vec<u8>>,
    source_app: Option<String>,
    source_app_bundle_id: Option<String>,
) -> Result<InsertOutcome, ClipKittyError> {
    let item = StoredItem::new_file(
        path,
        filename,
        file_size,
        uti,
        bookmark_data,
        thumbnail,
        source_app,
        source_app_bundle_id,
    );
    dedupe_or_insert_and_index(db, indexer, item)
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn save_files(
    db: &Database,
    indexer: &Indexer,
    paths: Vec<String>,
    filenames: Vec<String>,
    file_sizes: Vec<u64>,
    utis: Vec<String>,
    bookmark_data_list: Vec<Vec<u8>>,
    thumbnail: Option<Vec<u8>>,
    source_app: Option<String>,
    source_app_bundle_id: Option<String>,
) -> Result<InsertOutcome, ClipKittyError> {
    let item = StoredItem::new_files(
        paths,
        filenames,
        file_sizes,
        utis,
        bookmark_data_list,
        thumbnail,
        source_app,
        source_app_bundle_id,
    );
    dedupe_or_insert_and_index(db, indexer, item)
}

pub(crate) fn save_image(
    db: &Database,
    indexer: &Indexer,
    image_data: Vec<u8>,
    thumbnail: Option<Vec<u8>>,
    source_app: Option<String>,
    source_app_bundle_id: Option<String>,
    is_animated: bool,
) -> Result<InsertOutcome, ClipKittyError> {
    if image_data.is_empty() {
        return Err(ClipKittyError::InvalidInput("Empty image data".into()));
    }

    let item = StoredItem::new_image_with_thumbnail(
        image_data,
        thumbnail,
        source_app,
        source_app_bundle_id,
        is_animated,
    );
    dedupe_or_insert_and_index(db, indexer, item)
}

pub(crate) fn update_link_metadata(
    db: &Database,
    item_id: i64,
    title: Option<String>,
    description: Option<String>,
    image_data: Option<Vec<u8>>,
) -> Result<ResolvedLinkMetadata, ClipKittyError> {
    let title = title.and_then(non_empty);
    let description = description.and_then(non_empty);
    let state = match (title, description, image_data) {
        (None, None, None) => LinkMetadataState::Failed,
        (None, Some(_), None) => LinkMetadataState::Failed,
        (Some(title), description, None) => LinkMetadataState::Loaded {
            payload: LinkMetadataPayload::TitleOnly { title, description },
        },
        (None, description, Some(image_data)) => LinkMetadataState::Loaded {
            payload: LinkMetadataPayload::ImageOnly {
                image_data,
                description,
            },
        },
        (Some(title), description, Some(image_data)) => LinkMetadataState::Loaded {
            payload: LinkMetadataPayload::TitleAndImage {
                title,
                image_data,
                description,
            },
        },
    };
    let (title, description, image_data) = state.to_database_fields();

    db.update_link_metadata(
        item_id,
        title.as_deref(),
        description.as_deref(),
        image_data.as_deref(),
    )?;

    Ok(ResolvedLinkMetadata {
        title,
        description,
        image_data,
    })
}

pub(crate) fn update_image_description(
    db: &Database,
    indexer: &Indexer,
    item_id: i64,
    description: String,
) -> Result<ReindexOutcome, ClipKittyError> {
    db.update_image_description(item_id, &description)?;
    if let Some(item) = get_stored_item(db, item_id)? {
        if indexer
            .add_document(item_id, &description, item.timestamp_unix)
            .is_err()
        {
            return Ok(ReindexOutcome::IndexFailed);
        }
        let _ = indexer.commit();
    }
    Ok(ReindexOutcome::Indexed)
}

pub(crate) fn update_text_item(
    db: &Database,
    indexer: &Indexer,
    item_id: i64,
    text: String,
) -> Result<ReindexOutcome, ClipKittyError> {
    let content_hash = StoredItem::hash_string(&text);

    db.update_text_item(item_id, &text, &content_hash)?;
    if let Some(item) = get_stored_item(db, item_id)? {
        if indexer
            .add_document(item_id, &text, item.timestamp_unix)
            .is_err()
        {
            return Ok(ReindexOutcome::IndexFailed);
        }
        let _ = indexer.commit();
    }
    Ok(ReindexOutcome::Indexed)
}

pub(crate) fn update_timestamp(
    db: &Database,
    item_id: i64,
) -> Result<i64, ClipKittyError> {
    let now = Utc::now();
    db.update_timestamp(item_id, now)?;
    Ok(now.timestamp())
}

pub(crate) fn add_tag(
    db: &Database,
    item_id: i64,
    tag: ItemTag,
) -> Result<(), ClipKittyError> {
    db.add_tag(item_id, tag)?;
    Ok(())
}

pub(crate) fn remove_tag(
    db: &Database,
    item_id: i64,
    tag: ItemTag,
) -> Result<(), ClipKittyError> {
    db.remove_tag(item_id, tag)?;
    Ok(())
}

pub(crate) fn delete_item(
    db: &Database,
    indexer: &Indexer,
    item_id: i64,
) -> Result<(), ClipKittyError> {
    db.delete_item(item_id)?;
    indexer.delete_document(item_id)?;
    indexer.commit()?;
    Ok(())
}

pub(crate) fn clear(
    db: &Database,
    indexer: &Indexer,
) -> Result<(), ClipKittyError> {
    db.clear_all()?;
    indexer.clear()?;
    Ok(())
}

pub(crate) fn prune_to_size(
    db: &Database,
    indexer: &Indexer,
    max_bytes: i64,
    keep_ratio: f64,
) -> Result<PruneOutcome, ClipKittyError> {
    let deleted_ids = db.get_prunable_ids(max_bytes, keep_ratio)?;

    for id in &deleted_ids {
        indexer.delete_document(*id)?;
    }
    if !deleted_ids.is_empty() {
        indexer.commit()?;
    }
    let bytes_freed = db.prune_to_size(max_bytes, keep_ratio)? as u64;
    Ok(PruneOutcome {
        deleted_ids,
        bytes_freed,
    })
}

// ═══════════════════════════════════════════════════════════════════════════════
// Internal helpers
// ═══════════════════════════════════════════════════════════════════════════════

fn dedupe_or_insert_and_index(
    db: &Database,
    indexer: &Indexer,
    item: StoredItem,
) -> Result<InsertOutcome, ClipKittyError> {
    if let Some(existing) = db.find_by_hash(&item.content_hash)? {
        if let Some(id) = existing.id {
            let now = Utc::now();
            db.update_timestamp(id, now)?;
            indexer.add_document(id, &index_text(&existing), now.timestamp())?;
            indexer.commit()?;

            return Ok(InsertOutcome::Deduplicated {
                existing_id: id,
                touched_at_unix: now.timestamp(),
            });
        }
    }

    let index_text = index_text(&item);
    let id = db.insert_item(&item)?;
    indexer.add_document(id, &index_text, item.timestamp_unix)?;
    indexer.commit()?;

    Ok(InsertOutcome::Inserted { new_id: id, item })
}

fn get_stored_item(db: &Database, item_id: i64) -> Result<Option<StoredItem>, ClipKittyError> {
    Ok(db.fetch_items_by_ids(&[item_id])?.into_iter().next())
}

fn index_text(item: &StoredItem) -> String {
    item.file_index_text()
        .unwrap_or_else(|| item.text_content().to_string())
}

fn non_empty(value: String) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}
