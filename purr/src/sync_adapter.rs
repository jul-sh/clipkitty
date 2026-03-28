use crate::interface::{ClipKittyError, ClipboardContent, ItemTag};
use crate::models::StoredItem;
use purr_sync::{SyncContentPayload, SyncLiveSnapshot, SyncShadowRow, SyncTombstoneSnapshot};

pub(crate) fn sync_content_payload_for_item(item: &StoredItem) -> Option<SyncContentPayload> {
    match &item.content {
        ClipboardContent::Text { value } => Some(SyncContentPayload::Text {
            value: value.clone(),
        }),
        ClipboardContent::Color { value } => Some(SyncContentPayload::Color {
            value: value.clone(),
        }),
        ClipboardContent::Link {
            url,
            metadata_state,
        } => Some(SyncContentPayload::Link {
            url: url.clone(),
            metadata_state: metadata_state.clone(),
        }),
        ClipboardContent::Image {
            data,
            description,
            is_animated,
        } => Some(SyncContentPayload::Image {
            data: data.clone(),
            description: description.clone(),
            thumbnail: item.thumbnail.clone(),
            is_animated: *is_animated,
        }),
        ClipboardContent::File { .. } => None,
    }
}

pub(crate) fn is_bookmarked(tags: &[ItemTag]) -> bool {
    tags.contains(&ItemTag::Bookmark)
}

pub(crate) fn live_snapshot_from_parts(
    row: &SyncShadowRow,
    item: &StoredItem,
    is_bookmarked: bool,
) -> Result<SyncLiveSnapshot, ClipKittyError> {
    let Some(content) = sync_content_payload_for_item(item) else {
        return Err(ClipKittyError::DataInconsistency(format!(
            "sync shadow row {} referenced unsupported local item type",
            row.global_item_id
        )));
    };
    Ok(SyncLiveSnapshot {
        global_item_id: row.global_item_id.clone(),
        content,
        source_app: item.source_app.clone(),
        source_app_bundle_id: item.source_app_bundle_id.clone(),
        is_bookmarked,
        activity_timestamp_unix: item.timestamp_unix,
        content_version: row.content_version.clone(),
        bookmark_version: row.bookmark_version.clone(),
        activity_version: row.activity_version.clone(),
        delete_version: row.delete_version.clone(),
    })
}

pub(crate) fn tombstone_snapshot_from_row(row: &SyncShadowRow) -> SyncTombstoneSnapshot {
    SyncTombstoneSnapshot {
        global_item_id: row.global_item_id.clone(),
        content_version: row.content_version.clone(),
        delete_version: row.delete_version.clone(),
    }
}

pub(crate) fn stored_item_from_live_snapshot(snapshot: &SyncLiveSnapshot) -> StoredItem {
    match &snapshot.content {
        SyncContentPayload::Text { value } => StoredItem {
            id: None,
            content: ClipboardContent::Text {
                value: value.clone(),
            },
            content_hash: StoredItem::hash_string(value),
            timestamp_unix: snapshot.activity_timestamp_unix,
            source_app: snapshot.source_app.clone(),
            source_app_bundle_id: snapshot.source_app_bundle_id.clone(),
            thumbnail: None,
            color_rgba: None,
        },
        SyncContentPayload::Color { value } => StoredItem {
            id: None,
            content: ClipboardContent::Color {
                value: value.clone(),
            },
            content_hash: StoredItem::hash_string(value),
            timestamp_unix: snapshot.activity_timestamp_unix,
            source_app: snapshot.source_app.clone(),
            source_app_bundle_id: snapshot.source_app_bundle_id.clone(),
            thumbnail: None,
            color_rgba: crate::content_detection::parse_color_to_rgba(value),
        },
        SyncContentPayload::Link {
            url,
            metadata_state,
        } => {
            let (_, _, image_data) = metadata_state.to_database_fields();
            StoredItem {
                id: None,
                content: ClipboardContent::Link {
                    url: url.clone(),
                    metadata_state: metadata_state.clone(),
                },
                content_hash: StoredItem::hash_string(url),
                timestamp_unix: snapshot.activity_timestamp_unix,
                source_app: snapshot.source_app.clone(),
                source_app_bundle_id: snapshot.source_app_bundle_id.clone(),
                thumbnail: image_data,
                color_rgba: None,
            }
        }
        SyncContentPayload::Image {
            data,
            description,
            thumbnail,
            is_animated,
        } => StoredItem {
            id: None,
            content: ClipboardContent::Image {
                data: data.clone(),
                description: description.clone(),
                is_animated: *is_animated,
            },
            content_hash: StoredItem::hash_bytes(data),
            timestamp_unix: snapshot.activity_timestamp_unix,
            source_app: snapshot.source_app.clone(),
            source_app_bundle_id: snapshot.source_app_bundle_id.clone(),
            thumbnail: thumbnail.clone(),
            color_rgba: None,
        },
    }
}
