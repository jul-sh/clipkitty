use crate::database::Database;
use crate::indexer::Indexer;
use crate::interface::{ClipKittyError, ItemTag, LinkMetadataPayload, LinkMetadataState};
use crate::models::StoredItem;
use purr_sync::types::*;
use crate::sync_bridge::SyncEmitter;
use chrono::Utc;

// ═══════════════════════════════════════════════════════════════════════════════
// Save operations — each emits a sync event, then applies locally.
// ═══════════════════════════════════════════════════════════════════════════════

pub(crate) fn save_text(
    db: &Database,
    indexer: &Indexer,
    emitter: &dyn SyncEmitter,
    text: String,
    source_app: Option<String>,
    source_app_bundle_id: Option<String>,
) -> Result<i64, ClipKittyError> {
    let item = StoredItem::new_text(text, source_app, source_app_bundle_id);
    dedupe_or_insert_and_index(db, indexer, emitter, item)
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn save_file(
    db: &Database,
    indexer: &Indexer,
    emitter: &dyn SyncEmitter,
    path: String,
    filename: String,
    file_size: u64,
    uti: String,
    bookmark_data: Vec<u8>,
    thumbnail: Option<Vec<u8>>,
    source_app: Option<String>,
    source_app_bundle_id: Option<String>,
) -> Result<i64, ClipKittyError> {
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
    dedupe_or_insert_and_index(db, indexer, emitter, item)
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn save_files(
    db: &Database,
    indexer: &Indexer,
    emitter: &dyn SyncEmitter,
    paths: Vec<String>,
    filenames: Vec<String>,
    file_sizes: Vec<u64>,
    utis: Vec<String>,
    bookmark_data_list: Vec<Vec<u8>>,
    thumbnail: Option<Vec<u8>>,
    source_app: Option<String>,
    source_app_bundle_id: Option<String>,
) -> Result<i64, ClipKittyError> {
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
    dedupe_or_insert_and_index(db, indexer, emitter, item)
}

pub(crate) fn save_image(
    db: &Database,
    indexer: &Indexer,
    emitter: &dyn SyncEmitter,
    image_data: Vec<u8>,
    thumbnail: Option<Vec<u8>>,
    source_app: Option<String>,
    source_app_bundle_id: Option<String>,
    is_animated: bool,
) -> Result<i64, ClipKittyError> {
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
    dedupe_or_insert_and_index(db, indexer, emitter, item)
}

pub(crate) fn update_link_metadata(
    db: &Database,
    emitter: &dyn SyncEmitter,
    item_id: i64,
    title: Option<String>,
    description: Option<String>,
    image_data: Option<Vec<u8>>,
) -> Result<(), ClipKittyError> {
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

    // Emit sync event.
    let metadata = LinkMetadataSnapshot {
        title: title.clone(),
        description: description.clone(),
        image_data_base64: image_data.as_ref().map(|d| base64_encode(d)),
    };
    emitter.emit_link_metadata_updated(item_id, metadata)?;

    db.update_link_metadata(
        item_id,
        title.as_deref(),
        description.as_deref(),
        image_data.as_deref(),
    )?;
    Ok(())
}

pub(crate) fn update_image_description(
    db: &Database,
    indexer: &Indexer,
    emitter: &dyn SyncEmitter,
    item_id: i64,
    description: String,
) -> Result<(), ClipKittyError> {
    emitter.emit_image_description_updated(item_id, &description)?;

    db.update_image_description(item_id, &description)?;
    if let Some(item) = get_stored_item(db, item_id)? {
        if let Err(_) = indexer.add_document(item_id, &description, item.timestamp_unix) {
            let _ = emitter.set_index_dirty();
        } else {
            let _ = indexer.commit();
        }
    }
    Ok(())
}

pub(crate) fn update_text_item(
    db: &Database,
    indexer: &Indexer,
    emitter: &dyn SyncEmitter,
    item_id: i64,
    text: String,
) -> Result<(), ClipKittyError> {
    let content_hash = StoredItem::hash_string(&text);

    emitter.emit_text_edited(item_id, &text)?;

    db.update_text_item(item_id, &text, &content_hash)?;
    if let Some(item) = get_stored_item(db, item_id)? {
        if let Err(_) = indexer.add_document(item_id, &text, item.timestamp_unix) {
            let _ = emitter.set_index_dirty();
        } else {
            let _ = indexer.commit();
        }
    }
    Ok(())
}

pub(crate) fn update_timestamp(
    db: &Database,
    _indexer: &Indexer,
    emitter: &dyn SyncEmitter,
    item_id: i64,
) -> Result<(), ClipKittyError> {
    let now = Utc::now();

    emitter.emit_item_touched(item_id, now.timestamp())?;

    db.update_timestamp(item_id, now)?;
    // Touch only changes the timestamp — no need to re-index searchable content.
    Ok(())
}

pub(crate) fn add_tag(
    db: &Database,
    emitter: &dyn SyncEmitter,
    item_id: i64,
    tag: ItemTag,
) -> Result<(), ClipKittyError> {
    emitter.emit_bookmark_set(item_id)?;

    db.add_tag(item_id, tag)?;
    Ok(())
}

pub(crate) fn remove_tag(
    db: &Database,
    emitter: &dyn SyncEmitter,
    item_id: i64,
    tag: ItemTag,
) -> Result<(), ClipKittyError> {
    emitter.emit_bookmark_cleared(item_id)?;

    db.remove_tag(item_id, tag)?;
    Ok(())
}

pub(crate) fn delete_item(
    db: &Database,
    indexer: &Indexer,
    emitter: &dyn SyncEmitter,
    item_id: i64,
) -> Result<(), ClipKittyError> {
    emitter.emit_item_deleted(item_id)?;

    db.delete_item(item_id)?;
    indexer.delete_document(item_id)?;
    indexer.commit()?;
    Ok(())
}

pub(crate) fn clear(
    db: &Database,
    indexer: &Indexer,
    emitter: &dyn SyncEmitter,
) -> Result<(), ClipKittyError> {
    // Clear sync state before clearing items so we don't leave orphan sync records.
    emitter.emit_clear()?;

    db.clear_all()?;
    indexer.clear()?;
    Ok(())
}

pub(crate) fn prune_to_size(
    db: &Database,
    indexer: &Indexer,
    emitter: &dyn SyncEmitter,
    max_bytes: i64,
    keep_ratio: f64,
) -> Result<u64, ClipKittyError> {
    let deleted_ids = db.get_prunable_ids(max_bytes, keep_ratio)?;

    // Emit ItemDeleted events for each pruned item.
    for id in &deleted_ids {
        emitter.emit_item_deleted(*id)?;
        indexer.delete_document(*id)?;
    }
    if !deleted_ids.is_empty() {
        indexer.commit()?;
    }
    Ok(db.prune_to_size(max_bytes, keep_ratio)? as u64)
}

// ═══════════════════════════════════════════════════════════════════════════════
// Internal helpers
// ═══════════════════════════════════════════════════════════════════════════════

fn dedupe_or_insert_and_index(
    db: &Database,
    indexer: &Indexer,
    emitter: &dyn SyncEmitter,
    item: StoredItem,
) -> Result<i64, ClipKittyError> {
    if let Some(existing) = db.find_by_hash(&item.content_hash)? {
        if let Some(id) = existing.id {
            let now = Utc::now();
            db.update_timestamp(id, now)?;
            indexer.add_document(id, &index_text(&existing), now.timestamp())?;
            indexer.commit()?;

            // Emit touch event for the existing item.
            emitter.emit_item_touched(id, now.timestamp())?;

            return Ok(0);
        }
    }

    // New item — emit ItemCreated via the emitter.
    let index_text = index_text(&item);
    let id = db.insert_item(&item)?;
    indexer.add_document(id, &index_text, item.timestamp_unix)?;
    indexer.commit()?;

    let snapshot_data = snapshot_from_stored_item(&item);
    emitter.emit_item_created(id, snapshot_data)?;

    Ok(id)
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

/// Build an ItemSnapshotData from a StoredItem for sync transport.
fn snapshot_from_stored_item(item: &StoredItem) -> ItemSnapshotData {
    use crate::interface::ClipboardContent;

    let type_specific = match &item.content {
        ClipboardContent::Text { value } => TypeSpecificData::Text {
            value: value.clone(),
        },
        ClipboardContent::Color { value } => TypeSpecificData::Color {
            value: value.clone(),
        },
        ClipboardContent::Link {
            url,
            metadata_state,
        } => {
            let metadata = match metadata_state {
                LinkMetadataState::Loaded { .. } => {
                    let (title, desc, img) = metadata_state.to_database_fields();
                    Some(LinkMetadataSnapshot {
                        title,
                        description: desc,
                        image_data_base64: img.map(|d| base64_encode(&d)),
                    })
                }
                _ => None,
            };
            TypeSpecificData::Link {
                url: url.clone(),
                metadata,
            }
        }
        ClipboardContent::Image {
            data,
            description,
            is_animated,
        } => TypeSpecificData::Image {
            data_base64: base64_encode(data),
            description: description.clone(),
            is_animated: *is_animated,
        },
        ClipboardContent::File {
            display_name,
            files,
        } => TypeSpecificData::File {
            display_name: display_name.clone(),
            files: files
                .iter()
                .map(|f| FileSnapshotEntry {
                    path: f.path.clone(),
                    filename: f.filename.clone(),
                    file_size: f.file_size,
                    uti: f.uti.clone(),
                    bookmark_data_base64: base64_encode(&f.bookmark_data),
                    file_status: f.file_status.to_database_str(),
                })
                .collect(),
        },
    };

    ItemSnapshotData {
        content_type: item.content.database_type().to_string(),
        content_text: item.content.text_content().to_string(),
        content_hash: item.content_hash.clone(),
        source_app: item.source_app.clone(),
        source_app_bundle_id: item.source_app_bundle_id.clone(),
        timestamp_unix: item.timestamp_unix,
        is_bookmarked: false,
        thumbnail_base64: item.thumbnail.as_ref().map(|d| base64_encode(d)),
        color_rgba: item.color_rgba,
        type_specific,
    }
}

fn base64_encode(data: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(data)
}
