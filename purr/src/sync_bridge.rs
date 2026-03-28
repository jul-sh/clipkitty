//! Bridge between store mutations and the sync event system.
//!
//! Contains the SyncEmitter trait, its real implementation, and helpers for
//! converting local domain types into sync transport types.
//!
//! This entire module is compiled only when the `sync` feature is enabled.

use purr_sync::event::ItemEvent;
use purr_sync::store::SyncStore;
use purr_sync::types::{
    FileSnapshotEntry, ItemEventPayload, ItemSnapshotData, LinkMetadataSnapshot, TypeSpecificData,
    VersionVector, FLAG_INDEX_DIRTY,
};

use crate::interface::{ClipboardContent, ClipKittyError, LinkMetadataState};
use crate::models::StoredItem;
use crate::save_service::ResolvedLinkMetadata;
use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;

// ═══════════════════════════════════════════════════════════════════════════════
// Snapshot builders — convert local types to sync transport types
// ═══════════════════════════════════════════════════════════════════════════════

/// Build an ItemSnapshotData from a StoredItem for sync transport.
pub(crate) fn snapshot_from_stored_item(item: &StoredItem) -> ItemSnapshotData {
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

/// Convert resolved link metadata into a sync transport snapshot.
pub(crate) fn link_metadata_snapshot(meta: &ResolvedLinkMetadata) -> LinkMetadataSnapshot {
    LinkMetadataSnapshot {
        title: meta.title.clone(),
        description: meta.description.clone(),
        image_data_base64: meta.image_data.as_ref().map(|d| base64_encode(d)),
    }
}

fn base64_encode(data: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(data)
}

// ═══════════════════════════════════════════════════════════════════════════════
// SyncEmitter trait
// ═══════════════════════════════════════════════════════════════════════════════

/// Trait for emitting sync events from mutation operations.
///
/// Implementations handle projection lookup, event construction, and persistence.
pub(crate) trait SyncEmitter: Send + Sync {
    fn emit_item_created(
        &self,
        local_item_id: i64,
        snapshot: ItemSnapshotData,
    ) -> Result<(), ClipKittyError>;

    fn emit_item_touched(
        &self,
        local_item_id: i64,
        timestamp_unix: i64,
    ) -> Result<(), ClipKittyError>;

    fn emit_text_edited(
        &self,
        local_item_id: i64,
        new_text: &str,
    ) -> Result<(), ClipKittyError>;

    fn emit_bookmark_set(&self, local_item_id: i64) -> Result<(), ClipKittyError>;

    fn emit_bookmark_cleared(&self, local_item_id: i64) -> Result<(), ClipKittyError>;

    fn emit_item_deleted(&self, local_item_id: i64) -> Result<(), ClipKittyError>;

    fn emit_link_metadata_updated(
        &self,
        local_item_id: i64,
        metadata: LinkMetadataSnapshot,
    ) -> Result<(), ClipKittyError>;

    fn emit_image_description_updated(
        &self,
        local_item_id: i64,
        description: &str,
    ) -> Result<(), ClipKittyError>;

    fn emit_clear(&self) -> Result<(), ClipKittyError>;

    fn set_index_dirty(&self) -> Result<(), ClipKittyError>;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Real implementation — projection lookup + event append via SyncStore
// ═══════════════════════════════════════════════════════════════════════════════

/// Device ID for locally-originated events.
fn local_device_id() -> &'static str {
    "local"
}

pub(crate) struct RealSyncEmitter {
    pool: Pool<SqliteConnectionManager>,
}

impl RealSyncEmitter {
    pub fn new(pool: Pool<SqliteConnectionManager>) -> Self {
        Self { pool }
    }

    fn sync_store(&self) -> SyncStore<'_> {
        SyncStore::new(&self.pool)
    }
}

impl SyncEmitter for RealSyncEmitter {
    fn emit_item_created(
        &self,
        local_item_id: i64,
        snapshot: ItemSnapshotData,
    ) -> Result<(), ClipKittyError> {
        let global_item_id = uuid::Uuid::new_v4().to_string();
        let event = ItemEvent::new_local(
            global_item_id.clone(),
            local_device_id(),
            ItemEventPayload::ItemCreated { snapshot },
        );
        let sync = self.sync_store();
        sync.append_local_event(&event)?;

        let versions = VersionVector {
            content: 1,
            bookmark: 0,
            existence: 1,
            touch: 1,
            metadata: 1,
        };
        sync.upsert_projection(&global_item_id, Some(local_item_id), &versions, false)?;
        Ok(())
    }

    fn emit_item_touched(
        &self,
        local_item_id: i64,
        timestamp_unix: i64,
    ) -> Result<(), ClipKittyError> {
        let sync = self.sync_store();
        if let Some(global_id) = sync.global_id_for_local(local_item_id)? {
            if let Some(proj) = sync.fetch_projection(&global_id)? {
                let event = ItemEvent::new_local(
                    global_id,
                    local_device_id(),
                    ItemEventPayload::ItemTouched {
                        new_last_used_at_unix: timestamp_unix,
                        base_touch_version: proj.versions.touch,
                    },
                );
                sync.append_local_event(&event)?;
            }
        }
        Ok(())
    }

    fn emit_text_edited(
        &self,
        local_item_id: i64,
        new_text: &str,
    ) -> Result<(), ClipKittyError> {
        let sync = self.sync_store();
        if let Some(global_id) = sync.global_id_for_local(local_item_id)? {
            if let Some(proj) = sync.fetch_projection(&global_id)? {
                let event = ItemEvent::new_local(
                    global_id,
                    local_device_id(),
                    ItemEventPayload::TextEdited {
                        new_text: new_text.to_string(),
                        base_content_version: proj.versions.content,
                    },
                );
                sync.append_local_event(&event)?;
            }
        }
        Ok(())
    }

    fn emit_bookmark_set(&self, local_item_id: i64) -> Result<(), ClipKittyError> {
        let sync = self.sync_store();
        if let Some(global_id) = sync.global_id_for_local(local_item_id)? {
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
        Ok(())
    }

    fn emit_bookmark_cleared(&self, local_item_id: i64) -> Result<(), ClipKittyError> {
        let sync = self.sync_store();
        if let Some(global_id) = sync.global_id_for_local(local_item_id)? {
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
        Ok(())
    }

    fn emit_item_deleted(&self, local_item_id: i64) -> Result<(), ClipKittyError> {
        let sync = self.sync_store();
        if let Some(global_id) = sync.global_id_for_local(local_item_id)? {
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
        Ok(())
    }

    fn emit_link_metadata_updated(
        &self,
        local_item_id: i64,
        metadata: LinkMetadataSnapshot,
    ) -> Result<(), ClipKittyError> {
        let sync = self.sync_store();
        if let Some(global_id) = sync.global_id_for_local(local_item_id)? {
            if let Some(proj) = sync.fetch_projection(&global_id)? {
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
        Ok(())
    }

    fn emit_image_description_updated(
        &self,
        local_item_id: i64,
        description: &str,
    ) -> Result<(), ClipKittyError> {
        let sync = self.sync_store();
        if let Some(global_id) = sync.global_id_for_local(local_item_id)? {
            if let Some(proj) = sync.fetch_projection(&global_id)? {
                let event = ItemEvent::new_local(
                    global_id,
                    local_device_id(),
                    ItemEventPayload::ImageDescriptionUpdated {
                        description: description.to_string(),
                        base_content_version: proj.versions.content,
                    },
                );
                sync.append_local_event(&event)?;
            }
        }
        Ok(())
    }

    fn emit_clear(&self) -> Result<(), ClipKittyError> {
        let sync = self.sync_store();
        sync.clear_sync_state()?;
        Ok(())
    }

    fn set_index_dirty(&self) -> Result<(), ClipKittyError> {
        let sync = self.sync_store();
        sync.set_dirty_flag(FLAG_INDEX_DIRTY, true)?;
        Ok(())
    }
}
