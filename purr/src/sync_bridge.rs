//! Bridge between save_service mutations and the sync event system.
//!
//! The `SyncEmitter` trait decouples save_service from sync internals,
//! enabling the sync system to be extracted into a separate crate.

use purr_sync::event::ItemEvent;
use purr_sync::store::SyncStore;
use purr_sync::types::*;

use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;

/// Trait for emitting sync events from mutation operations.
///
/// Implementations handle projection lookup, event construction, and persistence.
/// save_service calls these methods instead of constructing SyncStore directly.
pub(crate) trait SyncEmitter: Send + Sync {
    fn emit_item_created(
        &self,
        local_item_id: i64,
        snapshot: ItemSnapshotData,
    ) -> Result<(), crate::interface::ClipKittyError>;

    fn emit_item_touched(
        &self,
        local_item_id: i64,
        timestamp_unix: i64,
    ) -> Result<(), crate::interface::ClipKittyError>;

    fn emit_text_edited(
        &self,
        local_item_id: i64,
        new_text: &str,
    ) -> Result<(), crate::interface::ClipKittyError>;

    fn emit_bookmark_set(
        &self,
        local_item_id: i64,
    ) -> Result<(), crate::interface::ClipKittyError>;

    fn emit_bookmark_cleared(
        &self,
        local_item_id: i64,
    ) -> Result<(), crate::interface::ClipKittyError>;

    fn emit_item_deleted(
        &self,
        local_item_id: i64,
    ) -> Result<(), crate::interface::ClipKittyError>;

    fn emit_link_metadata_updated(
        &self,
        local_item_id: i64,
        metadata: LinkMetadataSnapshot,
    ) -> Result<(), crate::interface::ClipKittyError>;

    fn emit_image_description_updated(
        &self,
        local_item_id: i64,
        description: &str,
    ) -> Result<(), crate::interface::ClipKittyError>;

    fn emit_clear(&self) -> Result<(), crate::interface::ClipKittyError>;

    fn set_index_dirty(&self) -> Result<(), crate::interface::ClipKittyError>;
}

// ─────────────────────────────────────────────────────────────────────────────
// Real implementation — projection lookup + event append via SyncStore
// ─────────────────────────────────────────────────────────────────────────────

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
    ) -> Result<(), crate::interface::ClipKittyError> {
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
    ) -> Result<(), crate::interface::ClipKittyError> {
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
    ) -> Result<(), crate::interface::ClipKittyError> {
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

    fn emit_bookmark_set(
        &self,
        local_item_id: i64,
    ) -> Result<(), crate::interface::ClipKittyError> {
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

    fn emit_bookmark_cleared(
        &self,
        local_item_id: i64,
    ) -> Result<(), crate::interface::ClipKittyError> {
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

    fn emit_item_deleted(
        &self,
        local_item_id: i64,
    ) -> Result<(), crate::interface::ClipKittyError> {
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
    ) -> Result<(), crate::interface::ClipKittyError> {
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
    ) -> Result<(), crate::interface::ClipKittyError> {
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

    fn emit_clear(&self) -> Result<(), crate::interface::ClipKittyError> {
        let sync = self.sync_store();
        sync.clear_sync_state()?;
        Ok(())
    }

    fn set_index_dirty(&self) -> Result<(), crate::interface::ClipKittyError> {
        let sync = self.sync_store();
        sync.set_dirty_flag(FLAG_INDEX_DIRTY, true)?;
        Ok(())
    }
}
