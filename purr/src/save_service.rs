use crate::database::Database;
use crate::indexer::Indexer;
use crate::interface::{
    ClipKittyError, ItemTag, LinkMetadataPayload, LinkMetadataState, SyncApplyReport,
    SyncLiveSnapshot, SyncRecordChange, SyncSnapshot, SyncTombstoneSnapshot,
};
use crate::models::StoredItem;
use crate::sync_adapter::{
    is_bookmarked, live_snapshot_from_parts, stored_item_from_live_snapshot,
    tombstone_snapshot_from_row,
};
use chrono::{TimeZone, Utc};
use purr_sync::{
    initial_sync_version, new_sync_identifier, plan_remote_apply, sync_shadow_for_live_snapshot,
    sync_shadow_for_tombstone_snapshot, LocalSyncRecord, PendingUploadDisposition,
    RemoteApplyDecision, SyncDomain, SyncShadowRow, SyncShadowState,
};

#[derive(Debug, Default, Clone, Copy)]
struct ApplyRemoteOutcome {
    applied: bool,
    forked: bool,
    index_changed: bool,
}

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
    db.update_link_metadata(
        item_id,
        title.as_deref(),
        description.as_deref(),
        image_data.as_deref(),
    )?;
    db.stage_local_item_domain_change(item_id, SyncDomain::Content)?;
    Ok(())
}

pub(crate) fn update_image_description(
    db: &Database,
    indexer: &Indexer,
    item_id: i64,
    description: String,
) -> Result<(), ClipKittyError> {
    db.update_image_description(item_id, &description)?;
    if let Some(item) = get_stored_item(db, item_id)? {
        indexer.add_document(item_id, &description, item.timestamp_unix)?;
        indexer.commit()?;
    }
    db.stage_local_item_domain_change(item_id, SyncDomain::Content)?;
    Ok(())
}

pub(crate) fn update_text_item(
    db: &Database,
    indexer: &Indexer,
    item_id: i64,
    text: String,
) -> Result<(), ClipKittyError> {
    let content_hash = StoredItem::hash_string(&text);
    db.update_text_item(item_id, &text, &content_hash)?;
    if let Some(item) = get_stored_item(db, item_id)? {
        indexer.add_document(item_id, &text, item.timestamp_unix)?;
        indexer.commit()?;
    }
    db.stage_local_item_domain_change(item_id, SyncDomain::Content)?;
    Ok(())
}

pub(crate) fn update_timestamp(
    db: &Database,
    indexer: &Indexer,
    item_id: i64,
) -> Result<(), ClipKittyError> {
    let now = Utc::now();
    db.update_timestamp(item_id, now)?;
    if let Some(item) = get_stored_item(db, item_id)? {
        indexer.add_document(item_id, item.text_content(), now.timestamp())?;
        indexer.commit()?;
    }
    db.stage_local_item_domain_change(item_id, SyncDomain::Activity)?;
    Ok(())
}

pub(crate) fn add_tag(db: &Database, item_id: i64, tag: ItemTag) -> Result<(), ClipKittyError> {
    db.add_tag(item_id, tag)?;
    db.stage_local_item_domain_change(item_id, SyncDomain::Bookmark)?;
    Ok(())
}

pub(crate) fn remove_tag(db: &Database, item_id: i64, tag: ItemTag) -> Result<(), ClipKittyError> {
    db.remove_tag(item_id, tag)?;
    db.stage_local_item_domain_change(item_id, SyncDomain::Bookmark)?;
    Ok(())
}

pub(crate) fn delete_item(
    db: &Database,
    indexer: &Indexer,
    item_id: i64,
) -> Result<(), ClipKittyError> {
    let _ = db.stage_local_item_delete(item_id)?;
    db.delete_item(item_id)?;
    indexer.delete_document(item_id)?;
    indexer.commit()?;
    Ok(())
}

pub(crate) fn clear(db: &Database, indexer: &Indexer) -> Result<(), ClipKittyError> {
    db.clear_all()?;
    db.clear_sync_shadow()?;
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
    for id in &deleted_ids {
        indexer.delete_document(*id)?;
    }
    if !deleted_ids.is_empty() {
        indexer.commit()?;
    }
    db.remove_sync_shadow_by_item_ids(&deleted_ids)?;
    Ok(db.prune_to_size(max_bytes, keep_ratio)? as u64)
}

pub(crate) fn pending_sync_changes(
    db: &Database,
    limit: u32,
) -> Result<Vec<SyncRecordChange>, ClipKittyError> {
    if limit == 0 {
        return Ok(Vec::new());
    }

    db.backfill_missing_sync_shadows(limit as usize)?;
    db.pending_sync_shadows(limit as usize)?
        .into_iter()
        .map(|row| materialize_sync_change(db, row))
        .collect()
}

pub(crate) fn acknowledge_sync_change_uploaded(
    db: &Database,
    global_item_id: &str,
    record_change_tag: Option<&str>,
) -> Result<(), ClipKittyError> {
    db.acknowledge_sync_change_uploaded(global_item_id, record_change_tag)?;
    Ok(())
}

pub(crate) fn apply_remote_sync_changes(
    db: &Database,
    indexer: &Indexer,
    changes: Vec<SyncRecordChange>,
) -> Result<SyncApplyReport, ClipKittyError> {
    let mut report = SyncApplyReport::default();

    for change in changes {
        let outcome = apply_remote_sync_change(db, indexer, change)?;
        if outcome.index_changed {
            indexer.commit()?;
        }
        if outcome.applied {
            report.applied_change_count += 1;
        }
        if outcome.forked {
            report.fork_count += 1;
        }
    }

    Ok(report)
}

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
            db.stage_local_item_domain_change(id, SyncDomain::Activity)?;
            return Ok(0);
        }
    }

    let index_text = index_text(&item);
    let id = db.insert_item(&item)?;
    indexer.add_document(id, &index_text, item.timestamp_unix)?;
    indexer.commit()?;
    db.stage_local_item_created(id)?;
    Ok(id)
}

fn materialize_sync_change(
    db: &Database,
    row: SyncShadowRow,
) -> Result<SyncRecordChange, ClipKittyError> {
    let snapshot = match row.state {
        SyncShadowState::Live => {
            let item_id = row.item_id.ok_or_else(|| {
                ClipKittyError::DataInconsistency(format!(
                    "sync shadow row {} is live but missing a local item id",
                    row.global_item_id
                ))
            })?;
            let item = get_stored_item(db, item_id)?.ok_or_else(|| {
                ClipKittyError::DataInconsistency(format!(
                    "sync shadow row {} points to missing local item {}",
                    row.global_item_id, item_id
                ))
            })?;
            let tags_by_id = db.get_tags_for_ids(&[item_id])?;
            let tags = tags_by_id.get(&item_id).map(Vec::as_slice).unwrap_or(&[]);
            SyncSnapshot::Live {
                snapshot: live_snapshot_from_parts(&row, &item, is_bookmarked(tags))?,
            }
        }
        SyncShadowState::Tombstone => SyncSnapshot::Tombstone {
            snapshot: tombstone_snapshot_from_row(&row),
        },
    };

    Ok(SyncRecordChange {
        snapshot,
        record_change_tag: row.record_change_tag,
    })
}

fn apply_remote_sync_change(
    db: &Database,
    indexer: &Indexer,
    change: SyncRecordChange,
) -> Result<ApplyRemoteOutcome, ClipKittyError> {
    let global_item_id = match &change.snapshot {
        SyncSnapshot::Live { snapshot } => snapshot.global_item_id.as_str(),
        SyncSnapshot::Tombstone { snapshot } => snapshot.global_item_id.as_str(),
    };
    let local = load_local_sync_record(db, global_item_id)?;
    let decision = plan_remote_apply(&local, &change);

    match decision {
        RemoteApplyDecision::Ignore => Ok(ApplyRemoteOutcome::default()),
        RemoteApplyDecision::UpsertLive {
            snapshot,
            pending_upload,
            record_change_tag,
            forked_local_snapshot,
        } => {
            let mut outcome = ApplyRemoteOutcome::default();

            if let Some(forked_snapshot) = forked_local_snapshot {
                create_forked_local_item(db, indexer, &forked_snapshot)?;
                outcome.forked = true;
                outcome.index_changed = true;
                outcome.applied = true;
            }

            let live_outcome = persist_live_snapshot(
                db,
                indexer,
                &local,
                &snapshot,
                pending_upload,
                record_change_tag,
            )?;
            outcome.applied |= live_outcome.applied;
            outcome.index_changed |= live_outcome.index_changed;
            Ok(outcome)
        }
        RemoteApplyDecision::UpsertTombstone {
            snapshot,
            pending_upload,
            record_change_tag,
        } => persist_tombstone_snapshot(
            db,
            indexer,
            &local,
            &snapshot,
            pending_upload,
            record_change_tag,
        ),
    }
}

fn load_local_sync_record(
    db: &Database,
    global_item_id: &str,
) -> Result<LocalSyncRecord, ClipKittyError> {
    let Some(row) = db.get_sync_shadow_by_global_id(global_item_id)? else {
        return Ok(LocalSyncRecord::Missing);
    };

    match row.state {
        SyncShadowState::Live => {
            let item_id = row.item_id.ok_or_else(|| {
                ClipKittyError::DataInconsistency(format!(
                    "sync shadow row {} is live but missing a local item id",
                    row.global_item_id
                ))
            })?;
            let item = get_stored_item(db, item_id)?.ok_or_else(|| {
                ClipKittyError::DataInconsistency(format!(
                    "sync shadow row {} points to missing local item {}",
                    row.global_item_id, item_id
                ))
            })?;
            let tags_by_id = db.get_tags_for_ids(&[item_id])?;
            let tags = tags_by_id.get(&item_id).map(Vec::as_slice).unwrap_or(&[]);
            Ok(LocalSyncRecord::Live {
                snapshot: live_snapshot_from_parts(&row, &item, is_bookmarked(tags))?,
                row,
            })
        }
        SyncShadowState::Tombstone => Ok(LocalSyncRecord::Tombstone {
            snapshot: tombstone_snapshot_from_row(&row),
            row,
        }),
    }
}

fn create_forked_local_item(
    db: &Database,
    indexer: &Indexer,
    snapshot: &SyncLiveSnapshot,
) -> Result<(), ClipKittyError> {
    let item = stored_item_from_live_snapshot(snapshot);
    let item_id = db.insert_item(&item)?;
    if snapshot.is_bookmarked {
        db.add_tag(item_id, ItemTag::Bookmark)?;
    }

    let device_id = db.sync_device_id()?;
    let fork_row = SyncShadowRow {
        global_item_id: new_sync_identifier(),
        item_id: Some(item_id),
        state: SyncShadowState::Live,
        record_change_tag: None,
        pending_upload: true,
        content_version: initial_sync_version(&device_id, 1),
        bookmark_version: initial_sync_version(
            &device_id,
            if snapshot.is_bookmarked { 1 } else { 0 },
        ),
        activity_version: initial_sync_version(&device_id, 1),
        delete_version: initial_sync_version(&device_id, 0),
    };
    db.save_sync_shadow(&fork_row)?;
    indexer.add_document(
        item_id,
        &index_text(&item),
        snapshot.activity_timestamp_unix,
    )?;
    Ok(())
}

fn persist_live_snapshot(
    db: &Database,
    indexer: &Indexer,
    local: &LocalSyncRecord,
    snapshot: &SyncLiveSnapshot,
    pending_upload: PendingUploadDisposition,
    record_change_tag: Option<String>,
) -> Result<ApplyRemoteOutcome, ClipKittyError> {
    let desired_item = stored_item_from_live_snapshot(snapshot);
    let mut outcome = ApplyRemoteOutcome::default();

    match local {
        LocalSyncRecord::Missing | LocalSyncRecord::Tombstone { .. } => {
            let item_id = db.insert_item(&desired_item)?;
            if snapshot.is_bookmarked {
                db.add_tag(item_id, ItemTag::Bookmark)?;
            }
            indexer.add_document(
                item_id,
                &index_text(&desired_item),
                snapshot.activity_timestamp_unix,
            )?;
            outcome.index_changed = true;

            let row =
                sync_shadow_for_live_snapshot(snapshot, item_id, pending_upload, record_change_tag);
            db.save_sync_shadow(&row)?;
            outcome.applied = true;
        }
        LocalSyncRecord::Live {
            row,
            snapshot: current_snapshot,
        } => {
            let item_id = row.item_id.ok_or_else(|| {
                ClipKittyError::DataInconsistency(format!(
                    "sync shadow row {} is live but missing a local item id",
                    row.global_item_id
                ))
            })?;

            let content_or_metadata_changed = current_snapshot.content != snapshot.content
                || current_snapshot.source_app != snapshot.source_app
                || current_snapshot.source_app_bundle_id != snapshot.source_app_bundle_id;
            let activity_changed =
                current_snapshot.activity_timestamp_unix != snapshot.activity_timestamp_unix;
            let bookmark_changed = current_snapshot.is_bookmarked != snapshot.is_bookmarked;

            if content_or_metadata_changed {
                db.replace_item_preserving_id(item_id, &desired_item)?;
            } else if activity_changed {
                db.update_timestamp(
                    item_id,
                    timestamp_from_unix(snapshot.activity_timestamp_unix),
                )?;
            }

            if bookmark_changed {
                if snapshot.is_bookmarked {
                    db.add_tag(item_id, ItemTag::Bookmark)?;
                } else {
                    db.remove_tag(item_id, ItemTag::Bookmark)?;
                }
            }

            if content_or_metadata_changed || activity_changed {
                indexer.add_document(
                    item_id,
                    &index_text(&desired_item),
                    snapshot.activity_timestamp_unix,
                )?;
                outcome.index_changed = true;
            }

            let new_row =
                sync_shadow_for_live_snapshot(snapshot, item_id, pending_upload, record_change_tag);
            if *row != new_row {
                db.save_sync_shadow(&new_row)?;
                outcome.applied = true;
            }

            outcome.applied |= content_or_metadata_changed || activity_changed || bookmark_changed;
        }
    }

    Ok(outcome)
}

fn persist_tombstone_snapshot(
    db: &Database,
    indexer: &Indexer,
    local: &LocalSyncRecord,
    snapshot: &SyncTombstoneSnapshot,
    pending_upload: PendingUploadDisposition,
    record_change_tag: Option<String>,
) -> Result<ApplyRemoteOutcome, ClipKittyError> {
    let mut outcome = ApplyRemoteOutcome::default();

    if let LocalSyncRecord::Live { row, .. } = local {
        let item_id = row.item_id.ok_or_else(|| {
            ClipKittyError::DataInconsistency(format!(
                "sync shadow row {} is live but missing a local item id",
                row.global_item_id
            ))
        })?;
        db.delete_item(item_id)?;
        indexer.delete_document(item_id)?;
        outcome.index_changed = true;
        outcome.applied = true;
    }

    let new_row = sync_shadow_for_tombstone_snapshot(
        snapshot,
        local.row(),
        pending_upload,
        record_change_tag,
    );
    if local.row() != Some(&new_row) {
        db.save_sync_shadow(&new_row)?;
        outcome.applied = true;
    }

    Ok(outcome)
}

fn get_stored_item(db: &Database, item_id: i64) -> Result<Option<StoredItem>, ClipKittyError> {
    Ok(db.fetch_items_by_ids(&[item_id])?.into_iter().next())
}

fn index_text(item: &StoredItem) -> String {
    item.file_index_text()
        .unwrap_or_else(|| item.text_content().to_string())
}

fn timestamp_from_unix(timestamp_unix: i64) -> chrono::DateTime<Utc> {
    Utc.timestamp_opt(timestamp_unix, 0)
        .single()
        .unwrap_or_else(Utc::now)
}

fn non_empty(value: String) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}
