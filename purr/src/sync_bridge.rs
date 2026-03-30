//! Bridge between store mutations and the sync event system.
//!
//! Contains the SyncEmitter trait, its real implementation, and helpers for
//! converting local domain types into sync transport types.
//!
//! This entire module is compiled only when the `sync` feature is enabled.

use purr_sync::event::ItemEvent;
use purr_sync::projector;
use purr_sync::snapshot::ItemSnapshot;
use purr_sync::store::{ProjectionState, SyncStore};
use purr_sync::types::{
    ApplyResult, FileSnapshotEntry, ItemAggregate, ItemEventPayload, ItemSnapshotData,
    LinkMetadataSnapshot, TypeSpecificData, FLAG_INDEX_DIRTY,
};

use crate::interface::{ClipKittyError, ClipboardContent, LinkMetadataState};
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

fn base64_decode(s: &str) -> Result<Vec<u8>, String> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD
        .decode(s)
        .map_err(|e| format!("base64 decode error: {e}"))
}

/// Reconstruct a StoredItem from an ItemSnapshotData (reverse of snapshot_from_stored_item).
/// Used to materialize remote sync changes into the local items table.
pub(crate) fn stored_item_from_snapshot(
    item_id: String,
    snapshot: &purr_sync::types::ItemSnapshotData,
) -> Result<crate::models::StoredItem, String> {
    use crate::interface::{ClipboardContent, FileEntry, FileStatus, LinkMetadataState};

    let content = match &snapshot.type_specific {
        purr_sync::types::TypeSpecificData::Text { value } => ClipboardContent::Text {
            value: value.clone(),
        },
        purr_sync::types::TypeSpecificData::Color { value } => ClipboardContent::Color {
            value: value.clone(),
        },
        purr_sync::types::TypeSpecificData::Link { url, metadata } => {
            let metadata_state = match metadata {
                Some(meta) => {
                    let image_data = meta
                        .image_data_base64
                        .as_deref()
                        .filter(|s| !s.is_empty())
                        .map(base64_decode)
                        .transpose()?;
                    LinkMetadataState::from_database(
                        meta.title.as_deref(),
                        meta.description.as_deref(),
                        image_data,
                    )?
                }
                None => LinkMetadataState::Pending,
            };
            ClipboardContent::Link {
                url: url.clone(),
                metadata_state,
            }
        }
        purr_sync::types::TypeSpecificData::Image {
            data_base64,
            description,
            is_animated,
        } => ClipboardContent::Image {
            data: base64_decode(data_base64)?,
            description: description.clone(),
            is_animated: *is_animated,
        },
        purr_sync::types::TypeSpecificData::File {
            display_name,
            files,
        } => {
            let entries = files
                .iter()
                .map(|f| {
                    Ok(FileEntry {
                        file_item_id: 0,
                        path: f.path.clone(),
                        filename: f.filename.clone(),
                        file_size: f.file_size,
                        uti: f.uti.clone(),
                        bookmark_data: base64_decode(&f.bookmark_data_base64)?,
                        file_status: FileStatus::from_database_str(&f.file_status),
                    })
                })
                .collect::<Result<Vec<_>, String>>()?;
            ClipboardContent::File {
                display_name: display_name.clone(),
                files: entries,
            }
        }
    };

    let thumbnail = snapshot
        .thumbnail_base64
        .as_deref()
        .filter(|s| !s.is_empty())
        .map(base64_decode)
        .transpose()?;

    Ok(crate::models::StoredItem {
        id: None,
        item_id,
        content,
        content_hash: snapshot.content_hash.clone(),
        timestamp_unix: snapshot.timestamp_unix,
        source_app: snapshot.source_app.clone(),
        source_app_bundle_id: snapshot.source_app_bundle_id.clone(),
        thumbnail,
        color_rgba: snapshot.color_rgba,
    })
}

// ═══════════════════════════════════════════════════════════════════════════════
// SyncEmitter trait
// ═══════════════════════════════════════════════════════════════════════════════

/// Trait for emitting sync events from mutation operations.
///
/// Implementations handle projection lookup, event construction, and persistence.
/// All methods take `item_id: &str` — the stable string item ID from the items table.
pub(crate) trait SyncEmitter: Send + Sync {
    fn emit_item_created(
        &self,
        item_id: &str,
        snapshot: ItemSnapshotData,
    ) -> Result<(), ClipKittyError>;

    fn emit_item_touched(
        &self,
        item_id: &str,
        timestamp_unix: i64,
    ) -> Result<(), ClipKittyError>;

    fn emit_text_edited(&self, item_id: &str, new_text: &str) -> Result<(), ClipKittyError>;

    fn emit_bookmark_set(&self, item_id: &str) -> Result<(), ClipKittyError>;

    fn emit_bookmark_cleared(&self, item_id: &str) -> Result<(), ClipKittyError>;

    fn emit_item_deleted(&self, item_id: &str) -> Result<(), ClipKittyError>;

    fn emit_link_metadata_updated(
        &self,
        item_id: &str,
        metadata: LinkMetadataSnapshot,
    ) -> Result<(), ClipKittyError>;

    fn emit_image_description_updated(
        &self,
        item_id: &str,
        description: &str,
    ) -> Result<(), ClipKittyError>;

    fn set_index_dirty(&self) -> Result<(), ClipKittyError>;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Real implementation — projection lookup + event append via SyncStore
// ═══════════════════════════════════════════════════════════════════════════════

pub(crate) struct RealSyncEmitter {
    pool: Pool<SqliteConnectionManager>,
    device_id: parking_lot::Mutex<String>,
}

impl RealSyncEmitter {
    pub fn new(pool: Pool<SqliteConnectionManager>) -> Self {
        Self {
            pool,
            device_id: parking_lot::Mutex::new("local".to_string()),
        }
    }

    pub fn set_device_id(&self, device_id: String) {
        *self.device_id.lock() = device_id;
    }

    fn local_device_id(&self) -> String {
        self.device_id.lock().clone()
    }

    fn sync_store(&self) -> SyncStore<'_> {
        SyncStore::new(&self.pool)
    }

    fn append_local_event_and_advance(
        &self,
        event: &ItemEvent,
    ) -> Result<(), ClipKittyError> {
        let sync = self.sync_store();
        let current_aggregate = sync
            .fetch_snapshot(&event.item_id)?
            .map(|s| s.aggregate);

        match projector::apply_event(current_aggregate.as_ref(), &event.payload) {
            ApplyResult::Applied(delta) => {
                sync.append_local_event(event)?;
                self.persist_local_aggregate(
                    &sync,
                    &event.item_id,
                    &delta.new_aggregate,
                    &event.event_id,
                )
            }
            ApplyResult::Ignored(reason) => Err(ClipKittyError::DataInconsistency(format!(
                "local sync event `{}` was ignored: {reason:?}",
                event.payload_type()
            ))),
            ApplyResult::Deferred(reason) => Err(ClipKittyError::DataInconsistency(format!(
                "local sync event `{}` was deferred: {reason:?}",
                event.payload_type()
            ))),
            ApplyResult::Forked(plan) => Err(ClipKittyError::DataInconsistency(format!(
                "local sync event `{}` unexpectedly forked: {}",
                event.payload_type(),
                plan.reason
            ))),
        }
    }

    fn persist_local_aggregate(
        &self,
        sync: &SyncStore<'_>,
        item_id: &str,
        aggregate: &ItemAggregate,
        event_id: &str,
    ) -> Result<(), ClipKittyError> {
        let existing_snapshot = sync.fetch_snapshot(item_id)?;
        let previous_revision = existing_snapshot
            .as_ref()
            .map(|snapshot| snapshot.snapshot_revision)
            .unwrap_or(0);
        let snapshot = ItemSnapshot::compacted(
            item_id.to_string(),
            previous_revision,
            event_id.to_string(),
            aggregate.clone(),
        );
        sync.upsert_snapshot(&snapshot)?;

        let existing_projection = sync.fetch_projection(item_id)?;
        let projection_state = match aggregate {
            ItemAggregate::Live(live) => {
                match existing_projection.map(|entry| entry.state) {
                    Some(ProjectionState::Materialized { .. }) => {
                        ProjectionState::Materialized {
                            versions: live.versions,
                        }
                    }
                    Some(ProjectionState::PendingMaterialization { .. })
                    | Some(ProjectionState::Tombstoned { .. })
                    | None => ProjectionState::Materialized {
                        versions: live.versions,
                    },
                }
            }
            ItemAggregate::Tombstoned(tomb) => ProjectionState::Tombstoned {
                versions: tomb.versions,
            },
        };

        sync.upsert_projection(item_id, &projection_state)?;
        Ok(())
    }

    fn materialized_projection_versions(
        &self,
        sync: &SyncStore<'_>,
        item_id: &str,
    ) -> Result<Option<purr_sync::types::VersionVector>, ClipKittyError> {
        let projection = sync.fetch_projection(item_id)?;
        match projection.map(|entry| entry.state) {
            Some(ProjectionState::Materialized { versions, .. }) => Ok(Some(versions)),
            Some(ProjectionState::PendingMaterialization { .. }) => {
                Err(ClipKittyError::DataInconsistency(format!(
                    "global item `{item_id}` is pending materialization for a local mutation"
                )))
            }
            Some(ProjectionState::Tombstoned { .. }) => Err(ClipKittyError::DataInconsistency(
                format!("global item `{item_id}` is tombstoned for a local mutation"),
            )),
            None => Ok(None),
        }
    }
}

impl SyncEmitter for RealSyncEmitter {
    fn emit_item_created(
        &self,
        item_id: &str,
        snapshot: ItemSnapshotData,
    ) -> Result<(), ClipKittyError> {
        let event = ItemEvent::new_local(
            item_id.to_string(),
            &self.local_device_id(),
            ItemEventPayload::ItemCreated { snapshot },
        );
        self.append_local_event_and_advance(&event)
    }

    fn emit_item_touched(
        &self,
        item_id: &str,
        timestamp_unix: i64,
    ) -> Result<(), ClipKittyError> {
        let sync = self.sync_store();
        if let Some(versions) = self.materialized_projection_versions(&sync, item_id)? {
            let event = ItemEvent::new_local(
                item_id.to_string(),
                &self.local_device_id(),
                ItemEventPayload::ItemTouched {
                    new_last_used_at_unix: timestamp_unix,
                    base_touch_version: versions.touch,
                },
            );
            self.append_local_event_and_advance(&event)?;
        }
        Ok(())
    }

    fn emit_text_edited(&self, item_id: &str, new_text: &str) -> Result<(), ClipKittyError> {
        let sync = self.sync_store();
        if let Some(versions) = self.materialized_projection_versions(&sync, item_id)? {
            let event = ItemEvent::new_local(
                item_id.to_string(),
                &self.local_device_id(),
                ItemEventPayload::TextEdited {
                    new_text: new_text.to_string(),
                    base_content_version: versions.content,
                },
            );
            self.append_local_event_and_advance(&event)?;
        }
        Ok(())
    }

    fn emit_bookmark_set(&self, item_id: &str) -> Result<(), ClipKittyError> {
        let sync = self.sync_store();
        if let Some(versions) = self.materialized_projection_versions(&sync, item_id)? {
            let event = ItemEvent::new_local(
                item_id.to_string(),
                &self.local_device_id(),
                ItemEventPayload::BookmarkSet {
                    base_bookmark_version: versions.bookmark,
                },
            );
            self.append_local_event_and_advance(&event)?;
        }
        Ok(())
    }

    fn emit_bookmark_cleared(&self, item_id: &str) -> Result<(), ClipKittyError> {
        let sync = self.sync_store();
        if let Some(versions) = self.materialized_projection_versions(&sync, item_id)? {
            let event = ItemEvent::new_local(
                item_id.to_string(),
                &self.local_device_id(),
                ItemEventPayload::BookmarkCleared {
                    base_bookmark_version: versions.bookmark,
                },
            );
            self.append_local_event_and_advance(&event)?;
        }
        Ok(())
    }

    fn emit_item_deleted(&self, item_id: &str) -> Result<(), ClipKittyError> {
        let sync = self.sync_store();
        if let Some(versions) = self.materialized_projection_versions(&sync, item_id)? {
            let event = ItemEvent::new_local(
                item_id.to_string(),
                &self.local_device_id(),
                ItemEventPayload::ItemDeleted {
                    base_existence_version: versions.existence,
                },
            );
            self.append_local_event_and_advance(&event)?;
        }
        Ok(())
    }

    fn emit_link_metadata_updated(
        &self,
        item_id: &str,
        metadata: LinkMetadataSnapshot,
    ) -> Result<(), ClipKittyError> {
        let sync = self.sync_store();
        if let Some(versions) = self.materialized_projection_versions(&sync, item_id)? {
            let event = ItemEvent::new_local(
                item_id.to_string(),
                &self.local_device_id(),
                ItemEventPayload::LinkMetadataUpdated {
                    metadata,
                    base_metadata_version: versions.metadata,
                },
            );
            self.append_local_event_and_advance(&event)?;
        }
        Ok(())
    }

    fn emit_image_description_updated(
        &self,
        item_id: &str,
        description: &str,
    ) -> Result<(), ClipKittyError> {
        let sync = self.sync_store();
        if let Some(versions) = self.materialized_projection_versions(&sync, item_id)? {
            let event = ItemEvent::new_local(
                item_id.to_string(),
                &self.local_device_id(),
                ItemEventPayload::ImageDescriptionUpdated {
                    description: description.to_string(),
                    base_content_version: versions.content,
                },
            );
            self.append_local_event_and_advance(&event)?;
        }
        Ok(())
    }

    fn set_index_dirty(&self) -> Result<(), ClipKittyError> {
        let sync = self.sync_store();
        sync.set_dirty_flag(FLAG_INDEX_DIRTY, true)?;
        Ok(())
    }
}
