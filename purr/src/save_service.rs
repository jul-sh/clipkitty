use crate::database::Database;
use crate::indexer::Indexer;
use crate::interface::{ClipKittyError, ItemTag, LinkMetadataPayload, LinkMetadataState};
use crate::models::StoredItem;
use crate::sync::event::ItemEvent;
use crate::sync::store::SyncStore;
use crate::sync::types::*;
use chrono::Utc;
use uuid::Uuid;

/// Device ID for locally-originated events.
/// In production this will come from the SyncEngine; for now we use a
/// per-process constant. The actual device ID is set once at startup
/// and stored in sync_device_state.
fn local_device_id() -> &'static str {
    "local"
}

// ═══════════════════════════════════════════════════════════════════════════════
// Save operations — each builds an event, appends it, then applies locally.
// ═══════════════════════════════════════════════════════════════════════════════

pub(crate) fn save_text(
    db: &Database,
    indexer: &Indexer,
    text: String,
    source_app: Option<String>,
    source_app_bundle_id: Option<String>,
) -> Result<i64, ClipKittyError> {
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
    dedupe_or_insert_and_index(db, indexer, item)
}

pub(crate) fn update_link_metadata(
    db: &Database,
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
    let sync = SyncStore::new(db);
    if let Some(global_id) = sync.global_id_for_local(item_id)? {
        if let Some(proj) = sync.fetch_projection(&global_id)? {
            let metadata = LinkMetadataSnapshot {
                title: title.clone(),
                description: description.clone(),
                image_data_base64: image_data.as_ref().map(|d| base64_encode(d)),
            };
            let event = ItemEvent::new_local(
                global_id,
                local_device_id(),
                ItemEventPayload::LinkMetadataUpdated {
                    metadata,
                    base_metadata_version: proj.versions.metadata,
                },
            );
            sync.append_local_event(&event)?;
        }
    }

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
    item_id: i64,
    description: String,
) -> Result<(), ClipKittyError> {
    // Emit sync event.
    let sync = SyncStore::new(db);
    if let Some(global_id) = sync.global_id_for_local(item_id)? {
        if let Some(proj) = sync.fetch_projection(&global_id)? {
            let event = ItemEvent::new_local(
                global_id,
                local_device_id(),
                ItemEventPayload::ImageDescriptionUpdated {
                    description: description.clone(),
                    base_content_version: proj.versions.content,
                },
            );
            sync.append_local_event(&event)?;
        }
    }

    db.update_image_description(item_id, &description)?;
    if let Some(item) = get_stored_item(db, item_id)? {
        if let Err(_) = indexer.add_document(item_id, &description, item.timestamp_unix) {
            let _ = sync.set_dirty_flag(FLAG_INDEX_DIRTY, true);
        } else {
            let _ = indexer.commit();
        }
    }
    Ok(())
}

pub(crate) fn update_text_item(
    db: &Database,
    indexer: &Indexer,
    item_id: i64,
    text: String,
) -> Result<(), ClipKittyError> {
    let content_hash = StoredItem::hash_string(&text);

    // Emit sync event.
    let sync = SyncStore::new(db);
    if let Some(global_id) = sync.global_id_for_local(item_id)? {
        if let Some(proj) = sync.fetch_projection(&global_id)? {
            let event = ItemEvent::new_local(
                global_id,
                local_device_id(),
                ItemEventPayload::TextEdited {
                    new_text: text.clone(),
                    base_content_version: proj.versions.content,
                },
            );
            sync.append_local_event(&event)?;
        }
    }

    db.update_text_item(item_id, &text, &content_hash)?;
    if let Some(item) = get_stored_item(db, item_id)? {
        if let Err(_) = indexer.add_document(item_id, &text, item.timestamp_unix) {
            let _ = sync.set_dirty_flag(FLAG_INDEX_DIRTY, true);
        } else {
            let _ = indexer.commit();
        }
    }
    Ok(())
}

pub(crate) fn update_timestamp(
    db: &Database,
    _indexer: &Indexer,
    item_id: i64,
) -> Result<(), ClipKittyError> {
    let now = Utc::now();

    // Emit sync event.
    let sync = SyncStore::new(db);
    if let Some(global_id) = sync.global_id_for_local(item_id)? {
        if let Some(proj) = sync.fetch_projection(&global_id)? {
            let event = ItemEvent::new_local(
                global_id,
                local_device_id(),
                ItemEventPayload::ItemTouched {
                    new_last_used_at_unix: now.timestamp(),
                    base_touch_version: proj.versions.touch,
                },
            );
            sync.append_local_event(&event)?;
        }
    }

    db.update_timestamp(item_id, now)?;
    // Touch only changes the timestamp — no need to re-index searchable content.
    Ok(())
}

pub(crate) fn add_tag(db: &Database, item_id: i64, tag: ItemTag) -> Result<(), ClipKittyError> {
    // Emit sync event.
    let sync = SyncStore::new(db);
    if let Some(global_id) = sync.global_id_for_local(item_id)? {
        if let Some(proj) = sync.fetch_projection(&global_id)? {
            let event = ItemEvent::new_local(
                global_id,
                local_device_id(),
                ItemEventPayload::BookmarkSet {
                    base_bookmark_version: proj.versions.bookmark,
                },
            );
            sync.append_local_event(&event)?;
        }
    }

    db.add_tag(item_id, tag)?;
    Ok(())
}

pub(crate) fn remove_tag(db: &Database, item_id: i64, tag: ItemTag) -> Result<(), ClipKittyError> {
    // Emit sync event.
    let sync = SyncStore::new(db);
    if let Some(global_id) = sync.global_id_for_local(item_id)? {
        if let Some(proj) = sync.fetch_projection(&global_id)? {
            let event = ItemEvent::new_local(
                global_id,
                local_device_id(),
                ItemEventPayload::BookmarkCleared {
                    base_bookmark_version: proj.versions.bookmark,
                },
            );
            sync.append_local_event(&event)?;
        }
    }

    db.remove_tag(item_id, tag)?;
    Ok(())
}

pub(crate) fn delete_item(
    db: &Database,
    indexer: &Indexer,
    item_id: i64,
) -> Result<(), ClipKittyError> {
    // Emit sync event.
    let sync = SyncStore::new(db);
    if let Some(global_id) = sync.global_id_for_local(item_id)? {
        if let Some(proj) = sync.fetch_projection(&global_id)? {
            let event = ItemEvent::new_local(
                global_id,
                local_device_id(),
                ItemEventPayload::ItemDeleted {
                    base_existence_version: proj.versions.existence,
                },
            );
            sync.append_local_event(&event)?;
        }
    }

    db.delete_item(item_id)?;
    indexer.delete_document(item_id)?;
    indexer.commit()?;
    Ok(())
}

pub(crate) fn clear(db: &Database, indexer: &Indexer) -> Result<(), ClipKittyError> {
    // Clear sync state before clearing items so we don't leave orphan sync records.
    let sync = SyncStore::new(db);
    sync.clear_sync_state()?;

    db.clear_all()?;
    indexer.clear()?;
    Ok(())
}

pub(crate) fn prune_to_size(
    db: &Database,
    indexer: &Indexer,
    max_bytes: i64,
    keep_ratio: f64,
) -> Result<u64, ClipKittyError> {
    let deleted_ids = db.get_prunable_ids(max_bytes, keep_ratio)?;

    // Emit ItemDeleted events for each pruned item.
    let sync = SyncStore::new(db);
    for id in &deleted_ids {
        if let Some(global_id) = sync.global_id_for_local(*id)? {
            if let Some(proj) = sync.fetch_projection(&global_id)? {
                let event = ItemEvent::new_local(
                    global_id,
                    local_device_id(),
                    ItemEventPayload::ItemDeleted {
                        base_existence_version: proj.versions.existence,
                    },
                );
                sync.append_local_event(&event)?;
            }
        }
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
    item: StoredItem,
) -> Result<i64, ClipKittyError> {
    if let Some(existing) = db.find_by_hash(&item.content_hash)? {
        if let Some(id) = existing.id {
            let now = Utc::now();
            db.update_timestamp(id, now)?;
            indexer.add_document(id, &index_text(&existing), now.timestamp())?;
            indexer.commit()?;

            // Emit touch event for the existing item.
            let sync = SyncStore::new(db);
            if let Some(global_id) = sync.global_id_for_local(id)? {
                if let Some(proj) = sync.fetch_projection(&global_id)? {
                    let event = ItemEvent::new_local(
                        global_id,
                        local_device_id(),
                        ItemEventPayload::ItemTouched {
                            new_last_used_at_unix: now.timestamp(),
                            base_touch_version: proj.versions.touch,
                        },
                    );
                    sync.append_local_event(&event)?;
                }
            }

            return Ok(0);
        }
    }

    // New item — generate global ID and emit ItemCreated.
    let index_text = index_text(&item);
    let id = db.insert_item(&item)?;
    indexer.add_document(id, &index_text, item.timestamp_unix)?;
    indexer.commit()?;

    // Build snapshot data and emit event.
    let global_item_id = Uuid::new_v4().to_string();
    let snapshot_data = snapshot_from_stored_item(&item);
    let event = ItemEvent::new_local(
        global_item_id.clone(),
        local_device_id(),
        ItemEventPayload::ItemCreated {
            snapshot: snapshot_data,
        },
    );

    let sync = SyncStore::new(db);
    sync.append_local_event(&event)?;

    // Set up projection: global_item_id -> local_item_id.
    let versions = VersionVector {
        content: 1,
        bookmark: 0,
        existence: 1,
        touch: 1,
        metadata: 1,
    };
    sync.upsert_projection(&global_item_id, Some(id), &versions, false)?;

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
