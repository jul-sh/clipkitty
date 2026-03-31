//! Comprehensive tests for the iCloud sync system.
//!
//! Covers: projector conflict rules, compaction, replay, event-sourced writes,
//! dedup, schema evolution, tombstone lifecycle, fork scenarios.

use purr_sync::compactor::{self, CompactionOutcome};
use purr_sync::event::ItemEvent;
use purr_sync::projector;
use purr_sync::replay;
use purr_sync::snapshot::ItemSnapshot;
use purr_sync::store::{ProjectionEntry, ProjectionState, SyncStore};
use purr_sync::types::{
    ApplyResult, DeferredReason, FileSnapshotEntry, ForkPlan, IgnoreReason, ItemAggregate,
    ItemEventPayload, ItemSnapshotData, LinkMetadataSnapshot, LiveItemState, ProjectionDelta,
    TombstoneState, TypeSpecificData, VersionDomain, VersionVector, COMPACTION_EVENT_THRESHOLD,
    FLAG_INDEX_DIRTY, FLAG_NEEDS_FULL_RESYNC, SYNC_SCHEMA_VERSION,
    TOMBSTONE_SNAPSHOT_RETENTION_SECS,
};

use purr::database::Database;
use purr::ClipboardStore;
use purr::ClipboardStoreApi;
use tempfile::TempDir;

// ═══════════════════════════════════════════════════════════════════════════════
// Test helpers
// ═══════════════════════════════════════════════════════════════════════════════

fn test_db() -> Database {
    Database::open_in_memory().unwrap()
}

/// Create a ClipboardStore backed by a temp directory for integration tests.
fn test_store() -> (ClipboardStore, TempDir) {
    let dir = TempDir::new().unwrap();
    let db_path = dir.path().join("test.db").to_string_lossy().to_string();
    let store = ClipboardStore::new(db_path).unwrap();
    (store, dir)
}

/// Get a raw Database reference from a temp dir store for sync assertions.
fn store_db(dir: &TempDir) -> Database {
    let db_path = dir.path().join("test.db").to_string_lossy().to_string();
    Database::open(db_path).unwrap()
}

fn text_snapshot(text: &str) -> ItemSnapshotData {
    ItemSnapshotData {
        content_type: "text".to_string(),
        content_text: text.to_string(),
        content_hash: format!("hash_{text}"),
        source_app: Some("TestApp".to_string()),
        source_app_bundle_id: Some("com.test".to_string()),
        timestamp_unix: 1000000,
        is_bookmarked: false,
        thumbnail_base64: None,
        color_rgba: None,
        type_specific: TypeSpecificData::Text {
            value: text.to_string(),
        },
    }
}

fn image_snapshot(desc: &str) -> ItemSnapshotData {
    ItemSnapshotData {
        content_type: "image".to_string(),
        content_text: desc.to_string(),
        content_hash: format!("hash_img_{desc}"),
        source_app: None,
        source_app_bundle_id: None,
        timestamp_unix: 1000000,
        is_bookmarked: false,
        thumbnail_base64: None,
        color_rgba: None,
        type_specific: TypeSpecificData::Image {
            data_base64: "iVBORw0KGgo=".to_string(),
            description: desc.to_string(),
            is_animated: false,
        },
    }
}

fn link_snapshot(url: &str) -> ItemSnapshotData {
    ItemSnapshotData {
        content_type: "link".to_string(),
        content_text: url.to_string(),
        content_hash: format!("hash_link_{url}"),
        source_app: None,
        source_app_bundle_id: None,
        timestamp_unix: 1000000,
        is_bookmarked: false,
        thumbnail_base64: None,
        color_rgba: None,
        type_specific: TypeSpecificData::Link {
            url: url.to_string(),
            metadata: None,
        },
    }
}

fn live_aggregate(snapshot: ItemSnapshotData, versions: VersionVector) -> ItemAggregate {
    ItemAggregate::Live(LiveItemState { snapshot, versions })
}

fn tombstone_aggregate(content_type: &str, versions: VersionVector) -> ItemAggregate {
    ItemAggregate::Tombstoned(TombstoneState {
        deleted_at_unix: chrono::Utc::now().timestamp(),
        versions,
        content_type: content_type.to_string(),
    })
}

fn default_versions() -> VersionVector {
    VersionVector {
        content: 1,
        bookmark: 0,
        existence: 1,
        touch: 1,
        metadata: 1,
    }
}

fn assert_projection_materialized(entry: &ProjectionEntry) -> VersionVector {
    match &entry.state {
        ProjectionState::Materialized { versions } => *versions,
        ProjectionState::PendingMaterialization { .. } => {
            panic!("expected materialized projection, got pending materialization")
        }
        ProjectionState::Tombstoned { .. } => {
            panic!("expected materialized projection, got tombstoned")
        }
    }
}

fn assert_projection_pending(entry: &ProjectionEntry) -> VersionVector {
    match &entry.state {
        ProjectionState::PendingMaterialization { versions } => *versions,
        ProjectionState::Materialized { .. } => {
            panic!("expected pending projection, got materialized")
        }
        ProjectionState::Tombstoned { .. } => panic!("expected pending projection, got tombstoned"),
    }
}

fn assert_projection_tombstoned(entry: &ProjectionEntry) -> VersionVector {
    match &entry.state {
        ProjectionState::Tombstoned { versions } => *versions,
        ProjectionState::PendingMaterialization { .. } => {
            panic!("expected tombstoned projection, got pending materialization")
        }
        ProjectionState::Materialized { .. } => {
            panic!("expected tombstoned projection, got materialized")
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// PROJECTOR TESTS — Conflict rules
// ═══════════════════════════════════════════════════════════════════════════════

mod projector_tests {
    use super::*;

    // ── ItemCreated ──────────────────────────────────────────────────────

    #[test]
    fn item_created_on_empty_aggregate_applies() {
        let snapshot = text_snapshot("hello");
        let payload = ItemEventPayload::ItemCreated {
            snapshot: snapshot.clone(),
        };

        let result = projector::apply_event(None, &payload);

        match result {
            ApplyResult::Applied(delta) => {
                assert!(delta.read_model_dirty);
                assert!(delta.index_dirty);
                match &delta.new_aggregate {
                    ItemAggregate::Live(live) => {
                        assert_eq!(live.snapshot.content_text, "hello");
                        assert_eq!(live.versions.content, 1);
                        assert_eq!(live.versions.existence, 1);
                    }
                    _ => panic!("expected Live aggregate"),
                }
            }
            other => panic!("expected Applied, got {other:?}"),
        }
    }

    #[test]
    fn duplicate_item_created_is_ignored() {
        let snapshot = text_snapshot("hello");
        let agg = live_aggregate(snapshot.clone(), default_versions());
        let payload = ItemEventPayload::ItemCreated {
            snapshot: snapshot.clone(),
        };

        let result = projector::apply_event(Some(&agg), &payload);
        assert!(matches!(
            result,
            ApplyResult::Ignored(IgnoreReason::AlreadyApplied)
        ));
    }

    // ── TextEdited ───────────────────────────────────────────────────────

    #[test]
    fn text_edit_with_matching_base_applies() {
        let snapshot = text_snapshot("hello");
        let agg = live_aggregate(snapshot, default_versions());
        let payload = ItemEventPayload::TextEdited {
            new_text: "hello world".to_string(),
            base_content_version: 1,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        match result {
            ApplyResult::Applied(delta) => {
                assert!(delta.read_model_dirty);
                assert!(delta.index_dirty);
                match &delta.new_aggregate {
                    ItemAggregate::Live(live) => {
                        assert_eq!(live.snapshot.content_text, "hello world");
                        assert_eq!(live.versions.content, 2);
                    }
                    _ => panic!("expected Live"),
                }
            }
            other => panic!("expected Applied, got {other:?}"),
        }
    }

    #[test]
    fn text_edit_with_stale_base_forks() {
        let snapshot = text_snapshot("hello");
        let mut versions = default_versions();
        versions.content = 3; // content has been edited twice since
        let agg = live_aggregate(snapshot, versions);
        let payload = ItemEventPayload::TextEdited {
            new_text: "outdated edit".to_string(),
            base_content_version: 1,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        match result {
            ApplyResult::Forked(plan) => {
                assert_eq!(plan.forked_snapshot.content_text, "outdated edit");
                assert!(plan.reason.contains("conflict"));
            }
            other => panic!("expected Forked, got {other:?}"),
        }
    }

    #[test]
    fn text_edit_with_future_base_defers() {
        let snapshot = text_snapshot("hello");
        let agg = live_aggregate(snapshot, default_versions());
        let payload = ItemEventPayload::TextEdited {
            new_text: "future edit".to_string(),
            base_content_version: 5,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        match result {
            ApplyResult::Deferred(DeferredReason::FutureVersion {
                domain,
                event_base,
                current,
            }) => {
                assert_eq!(domain, VersionDomain::Content);
                assert_eq!(event_base, 5);
                assert_eq!(current, 1);
            }
            other => panic!("expected Deferred FutureVersion, got {other:?}"),
        }
    }

    #[test]
    fn text_edit_on_missing_item_defers() {
        let payload = ItemEventPayload::TextEdited {
            new_text: "orphan edit".to_string(),
            base_content_version: 1,
        };

        let result = projector::apply_event(None, &payload);
        assert!(matches!(
            result,
            ApplyResult::Deferred(DeferredReason::MissingItem)
        ));
    }

    #[test]
    fn text_edit_on_tombstone_forks() {
        let versions = default_versions();
        let agg = tombstone_aggregate("text", versions);
        let payload = ItemEventPayload::TextEdited {
            new_text: "edit after delete".to_string(),
            base_content_version: 1,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        match result {
            ApplyResult::Forked(plan) => {
                assert_eq!(plan.forked_snapshot.content_text, "edit after delete");
            }
            other => panic!("expected Forked, got {other:?}"),
        }
    }

    // ── BookmarkSet / BookmarkCleared ────────────────────────────────────

    #[test]
    fn bookmark_set_with_matching_base_applies() {
        let snapshot = text_snapshot("hello");
        let agg = live_aggregate(snapshot, default_versions());
        let payload = ItemEventPayload::BookmarkSet {
            base_bookmark_version: 0,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        match result {
            ApplyResult::Applied(delta) => {
                assert!(delta.read_model_dirty);
                assert!(!delta.index_dirty); // bookmark doesn't change index
                match &delta.new_aggregate {
                    ItemAggregate::Live(live) => {
                        assert!(live.snapshot.is_bookmarked);
                        assert_eq!(live.versions.bookmark, 1);
                    }
                    _ => panic!("expected Live"),
                }
            }
            other => panic!("expected Applied, got {other:?}"),
        }
    }

    #[test]
    fn bookmark_cleared_with_matching_base_applies() {
        let mut snapshot = text_snapshot("hello");
        snapshot.is_bookmarked = true;
        let mut versions = default_versions();
        versions.bookmark = 1;
        let agg = live_aggregate(snapshot, versions);
        let payload = ItemEventPayload::BookmarkCleared {
            base_bookmark_version: 1,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        match result {
            ApplyResult::Applied(delta) => match &delta.new_aggregate {
                ItemAggregate::Live(live) => {
                    assert!(!live.snapshot.is_bookmarked);
                    assert_eq!(live.versions.bookmark, 2);
                }
                _ => panic!("expected Live"),
            },
            other => panic!("expected Applied, got {other:?}"),
        }
    }

    #[test]
    fn stale_bookmark_is_ignored() {
        let snapshot = text_snapshot("hello");
        let mut versions = default_versions();
        versions.bookmark = 3;
        let agg = live_aggregate(snapshot, versions);
        let payload = ItemEventPayload::BookmarkSet {
            base_bookmark_version: 1,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        match result {
            ApplyResult::Ignored(IgnoreReason::StaleVersion {
                domain,
                event_base,
                current,
            }) => {
                assert_eq!(domain, VersionDomain::Bookmark);
                assert_eq!(event_base, 1);
                assert_eq!(current, 3);
            }
            other => panic!("expected Ignored StaleVersion, got {other:?}"),
        }
    }

    #[test]
    fn bookmark_vs_content_edit_both_apply_independently() {
        // Start with a fresh item.
        let snapshot = text_snapshot("hello");
        let agg = live_aggregate(snapshot, default_versions());

        // Apply text edit first.
        let edit_payload = ItemEventPayload::TextEdited {
            new_text: "hello world".to_string(),
            base_content_version: 1,
        };
        let edit_result = projector::apply_event(Some(&agg), &edit_payload);
        let edited_agg = match edit_result {
            ApplyResult::Applied(delta) => delta.new_aggregate,
            other => panic!("expected Applied for edit, got {other:?}"),
        };

        // Apply bookmark on the edited aggregate.
        let bookmark_payload = ItemEventPayload::BookmarkSet {
            base_bookmark_version: 0,
        };
        let bookmark_result = projector::apply_event(Some(&edited_agg), &bookmark_payload);
        match bookmark_result {
            ApplyResult::Applied(delta) => match &delta.new_aggregate {
                ItemAggregate::Live(live) => {
                    assert_eq!(live.snapshot.content_text, "hello world");
                    assert!(live.snapshot.is_bookmarked);
                    assert_eq!(live.versions.content, 2);
                    assert_eq!(live.versions.bookmark, 1);
                }
                _ => panic!("expected Live"),
            },
            other => panic!("expected Applied for bookmark, got {other:?}"),
        }
    }

    // ── Bookmark on tombstone ────────────────────────────────────────────

    #[test]
    fn bookmark_on_tombstone_is_ignored() {
        let agg = tombstone_aggregate("text", default_versions());
        let payload = ItemEventPayload::BookmarkSet {
            base_bookmark_version: 0,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        assert!(matches!(
            result,
            ApplyResult::Ignored(IgnoreReason::OperationOnTombstone)
        ));
    }

    #[test]
    fn bookmark_clear_on_tombstone_is_ignored() {
        let agg = tombstone_aggregate("text", default_versions());
        let payload = ItemEventPayload::BookmarkCleared {
            base_bookmark_version: 0,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        assert!(matches!(
            result,
            ApplyResult::Ignored(IgnoreReason::OperationOnTombstone)
        ));
    }

    // ── ItemDeleted ──────────────────────────────────────────────────────

    #[test]
    fn delete_with_matching_base_applies() {
        let snapshot = text_snapshot("hello");
        let agg = live_aggregate(snapshot, default_versions());
        let payload = ItemEventPayload::ItemDeleted {
            base_existence_version: 1,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        match result {
            ApplyResult::Applied(delta) => {
                assert!(delta.read_model_dirty);
                assert!(delta.index_dirty);
                assert!(matches!(delta.new_aggregate, ItemAggregate::Tombstoned(_)));
            }
            other => panic!("expected Applied, got {other:?}"),
        }
    }

    #[test]
    fn delete_on_tombstone_is_ignored() {
        let agg = tombstone_aggregate("text", default_versions());
        let payload = ItemEventPayload::ItemDeleted {
            base_existence_version: 1,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        assert!(matches!(
            result,
            ApplyResult::Ignored(IgnoreReason::OperationOnTombstone)
        ));
    }

    #[test]
    fn delete_with_stale_base_is_ignored() {
        let snapshot = text_snapshot("hello");
        let mut versions = default_versions();
        versions.existence = 3;
        let agg = live_aggregate(snapshot, versions);
        let payload = ItemEventPayload::ItemDeleted {
            base_existence_version: 1,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        assert!(matches!(
            result,
            ApplyResult::Ignored(IgnoreReason::StaleVersion { .. })
        ));
    }

    // ── ItemTouched ──────────────────────────────────────────────────────

    #[test]
    fn touch_with_matching_base_applies() {
        let snapshot = text_snapshot("hello");
        let agg = live_aggregate(snapshot, default_versions());
        let payload = ItemEventPayload::ItemTouched {
            new_last_used_at_unix: 2000000,
            base_touch_version: 1,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        match result {
            ApplyResult::Applied(delta) => match &delta.new_aggregate {
                ItemAggregate::Live(live) => {
                    assert_eq!(live.snapshot.timestamp_unix, 2000000);
                    assert_eq!(live.versions.touch, 2);
                }
                _ => panic!("expected Live"),
            },
            other => panic!("expected Applied, got {other:?}"),
        }
    }

    #[test]
    fn touch_on_tombstone_is_ignored() {
        let agg = tombstone_aggregate("text", default_versions());
        let payload = ItemEventPayload::ItemTouched {
            new_last_used_at_unix: 2000000,
            base_touch_version: 1,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        assert!(matches!(
            result,
            ApplyResult::Ignored(IgnoreReason::OperationOnTombstone)
        ));
    }

    // ── LinkMetadataUpdated ──────────────────────────────────────────────

    #[test]
    fn link_metadata_update_with_matching_base_applies() {
        let snapshot = link_snapshot("https://example.com");
        let agg = live_aggregate(snapshot, default_versions());
        let metadata = LinkMetadataSnapshot {
            title: Some("Example".to_string()),
            description: Some("A website".to_string()),
            image_data_base64: None,
        };
        let payload = ItemEventPayload::LinkMetadataUpdated {
            metadata: metadata.clone(),
            base_metadata_version: 1,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        match result {
            ApplyResult::Applied(delta) => {
                assert!(delta.read_model_dirty);
                assert!(!delta.index_dirty); // metadata doesn't change index
                match &delta.new_aggregate {
                    ItemAggregate::Live(live) => {
                        assert_eq!(live.versions.metadata, 2);
                        match &live.snapshot.type_specific {
                            TypeSpecificData::Link {
                                metadata: Some(m), ..
                            } => {
                                assert_eq!(m.title, Some("Example".to_string()));
                            }
                            other => panic!("expected Link with metadata, got {other:?}"),
                        }
                    }
                    _ => panic!("expected Live"),
                }
            }
            other => panic!("expected Applied, got {other:?}"),
        }
    }

    #[test]
    fn stale_link_metadata_is_ignored() {
        let snapshot = link_snapshot("https://example.com");
        let mut versions = default_versions();
        versions.metadata = 5;
        let agg = live_aggregate(snapshot, versions);
        let metadata = LinkMetadataSnapshot {
            title: Some("Old".to_string()),
            description: None,
            image_data_base64: None,
        };
        let payload = ItemEventPayload::LinkMetadataUpdated {
            metadata,
            base_metadata_version: 2,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        assert!(matches!(
            result,
            ApplyResult::Ignored(IgnoreReason::StaleVersion { .. })
        ));
    }

    // ── ImageDescriptionUpdated ──────────────────────────────────────────

    #[test]
    fn image_description_update_applies() {
        let snapshot = image_snapshot("Image");
        let agg = live_aggregate(snapshot, default_versions());
        let payload = ItemEventPayload::ImageDescriptionUpdated {
            description: "A cat photo".to_string(),
            base_content_version: 1,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        match result {
            ApplyResult::Applied(delta) => {
                assert!(delta.index_dirty);
                match &delta.new_aggregate {
                    ItemAggregate::Live(live) => {
                        assert_eq!(live.snapshot.content_text, "A cat photo");
                        assert_eq!(live.versions.content, 2);
                    }
                    _ => panic!("expected Live"),
                }
            }
            other => panic!("expected Applied, got {other:?}"),
        }
    }

    #[test]
    fn stale_image_description_is_ignored() {
        let snapshot = image_snapshot("Image");
        let mut versions = default_versions();
        versions.content = 3;
        let agg = live_aggregate(snapshot, versions);
        let payload = ItemEventPayload::ImageDescriptionUpdated {
            description: "stale description".to_string(),
            base_content_version: 1,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        assert!(matches!(
            result,
            ApplyResult::Ignored(IgnoreReason::StaleVersion { .. })
        ));
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// SYNC STORE TESTS — Persistence layer
// ═══════════════════════════════════════════════════════════════════════════════

mod store_tests {
    use super::*;

    #[test]
    fn append_and_fetch_local_event() {
        let db = test_db();
        let sync = SyncStore::new(db.pool());

        let event = ItemEvent::new_local(
            "item-1".to_string(),
            "device-A",
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("hello"),
            },
        );

        sync.append_local_event(&event).unwrap();

        let pending = sync.fetch_pending_upload_events().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].event_id, event.event_id);
        assert_eq!(pending[0].item_id, "item-1");
    }

    #[test]
    fn mark_uploaded_removes_from_pending() {
        let db = test_db();
        let sync = SyncStore::new(db.pool());

        let event = ItemEvent::new_local(
            "item-1".to_string(),
            "device-A",
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("hello"),
            },
        );
        sync.append_local_event(&event).unwrap();
        sync.mark_events_uploaded(&[&event.event_id]).unwrap();

        let pending = sync.fetch_pending_upload_events().unwrap();
        assert!(pending.is_empty());
    }

    #[test]
    fn dedup_prevents_double_apply() {
        let db = test_db();
        let sync = SyncStore::new(db.pool());

        assert!(!sync.is_event_applied("evt-1").unwrap());
        sync.mark_event_applied("evt-1").unwrap();
        assert!(sync.is_event_applied("evt-1").unwrap());

        // Idempotent.
        sync.mark_event_applied("evt-1").unwrap();
        assert!(sync.is_event_applied("evt-1").unwrap());
    }

    #[test]
    fn projection_roundtrip() {
        let db = test_db();
        let sync = SyncStore::new(db.pool());

        let versions = VersionVector {
            content: 3,
            bookmark: 1,
            existence: 1,
            touch: 5,
            metadata: 2,
        };
        sync.upsert_projection("global-1", &ProjectionState::Materialized { versions })
            .unwrap();

        let entry = sync.fetch_projection("global-1").unwrap().unwrap();
        let projected_versions = assert_projection_materialized(&entry);
        assert_eq!(projected_versions, versions);
    }

    #[test]
    fn snapshot_upsert_and_fetch() {
        let db = test_db();
        let sync = SyncStore::new(db.pool());

        let agg = ItemAggregate::Live(LiveItemState {
            snapshot: text_snapshot("hello"),
            versions: default_versions(),
        });
        let snapshot = ItemSnapshot::initial("global-1".to_string(), agg.clone());
        sync.upsert_snapshot(&snapshot).unwrap();

        let fetched = sync.fetch_snapshot("global-1").unwrap().unwrap();
        assert_eq!(fetched.snapshot_revision, 1);
        assert_eq!(fetched.aggregate, agg);

        // Overwrite with higher revision.
        let snapshot2 =
            ItemSnapshot::compacted("global-1".to_string(), 1, "evt-99".to_string(), agg.clone());
        sync.upsert_snapshot(&snapshot2).unwrap();

        let fetched2 = sync.fetch_snapshot("global-1").unwrap().unwrap();
        assert_eq!(fetched2.snapshot_revision, 2);
    }

    #[test]
    fn deferred_event_lifecycle() {
        let db = test_db();
        let sync = SyncStore::new(db.pool());

        let event = ItemEvent::new_local(
            "item-1".to_string(),
            "device-B",
            ItemEventPayload::TextEdited {
                new_text: "deferred".to_string(),
                base_content_version: 1,
            },
        );

        let reason = DeferredReason::MissingItem;
        sync.defer_event(&event, &reason).unwrap();

        assert_eq!(sync.count_deferred_events().unwrap(), 1);

        let deferred = sync.fetch_deferred_events_for_item("item-1").unwrap();
        assert_eq!(deferred.len(), 1);
        assert_eq!(deferred[0].event_id, event.event_id);

        sync.remove_deferred_event(&event.event_id).unwrap();
        assert_eq!(sync.count_deferred_events().unwrap(), 0);
    }

    #[test]
    fn dirty_flags() {
        let db = test_db();
        let sync = SyncStore::new(db.pool());

        assert!(!sync.get_dirty_flag(FLAG_INDEX_DIRTY).unwrap());
        sync.set_dirty_flag(FLAG_INDEX_DIRTY, true).unwrap();
        assert!(sync.get_dirty_flag(FLAG_INDEX_DIRTY).unwrap());
        sync.set_dirty_flag(FLAG_INDEX_DIRTY, false).unwrap();
        assert!(!sync.get_dirty_flag(FLAG_INDEX_DIRTY).unwrap());
    }

    #[test]
    fn device_state_roundtrip() {
        let db = test_db();
        let sync = SyncStore::new(db.pool());

        sync.upsert_device_state("dev-1", Some(b"token-abc"))
            .unwrap();
        let token = sync.fetch_zone_change_token("dev-1").unwrap().unwrap();
        assert_eq!(token, b"token-abc");

        // No token for unknown device.
        assert!(sync
            .fetch_zone_change_token("dev-unknown")
            .unwrap()
            .is_none());
    }

    #[test]
    fn clear_sync_state_preserves_device() {
        let db = test_db();
        let sync = SyncStore::new(db.pool());

        // Setup state.
        sync.upsert_device_state("dev-1", Some(b"token")).unwrap();
        let event = ItemEvent::new_local(
            "item-1".to_string(),
            "dev-1",
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("test"),
            },
        );
        sync.append_local_event(&event).unwrap();
        sync.mark_event_applied("some-evt").unwrap();
        sync.upsert_projection(
            "global-1",
            &ProjectionState::Materialized {
                versions: default_versions(),
            },
        )
        .unwrap();

        // Clear.
        sync.clear_sync_state().unwrap();

        // Events, projections, dedup cleared.
        assert!(sync.fetch_pending_upload_events().unwrap().is_empty());
        assert!(sync.fetch_projection("global-1").unwrap().is_none());
        assert!(!sync.is_event_applied("some-evt").unwrap());

        // Device state preserved.
        assert!(sync.fetch_zone_change_token("dev-1").unwrap().is_some());
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// REPLAY TESTS — Download path
// ═══════════════════════════════════════════════════════════════════════════════

mod replay_tests {
    use super::*;

    fn setup_item_in_db(db: &Database, global_id: &str) {
        let sync = SyncStore::new(db.pool());
        let agg = ItemAggregate::Live(LiveItemState {
            snapshot: text_snapshot("existing"),
            versions: default_versions(),
        });
        let snapshot = ItemSnapshot::initial(global_id.to_string(), agg);
        sync.upsert_snapshot(&snapshot).unwrap();
        sync.upsert_projection(
            global_id,
            &ProjectionState::Materialized {
                versions: default_versions(),
            },
        )
        .unwrap();
    }

    #[test]
    fn apply_remote_event_creates_item() {
        let db = test_db();
        let sync = SyncStore::new(db.pool());

        let event = ItemEvent::new_local(
            "item-1".to_string(),
            "device-B",
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("remote item"),
            },
        );

        let result = replay::apply_remote_event(db.pool(), &event).unwrap();
        assert!(matches!(result, ApplyResult::Applied(_)));

        // Verify projection was created.
        let proj = sync.fetch_projection("item-1").unwrap().unwrap();
        let versions = assert_projection_pending(&proj);
        assert_eq!(versions.content, 1);

        // Verify dedup.
        assert!(sync.is_event_applied(&event.event_id).unwrap());
    }

    #[test]
    fn duplicate_remote_event_is_ignored() {
        let db = test_db();

        let event = ItemEvent::new_local(
            "item-1".to_string(),
            "device-B",
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("remote item"),
            },
        );

        // Apply twice.
        let result1 = replay::apply_remote_event(db.pool(), &event).unwrap();
        assert!(matches!(result1, ApplyResult::Applied(_)));

        let result2 = replay::apply_remote_event(db.pool(), &event).unwrap();
        assert!(matches!(
            result2,
            ApplyResult::Ignored(IgnoreReason::AlreadyApplied)
        ));
    }

    #[test]
    fn remote_event_with_missing_item_is_deferred() {
        let db = test_db();
        let sync = SyncStore::new(db.pool());

        let event = ItemEvent::new_local(
            "nonexistent".to_string(),
            "device-B",
            ItemEventPayload::TextEdited {
                new_text: "edit orphan".to_string(),
                base_content_version: 1,
            },
        );

        let result = replay::apply_remote_event(db.pool(), &event).unwrap();
        assert!(matches!(result, ApplyResult::Deferred(_)));

        // Verify it was stored in deferred queue.
        assert_eq!(sync.count_deferred_events().unwrap(), 1);
    }

    #[test]
    fn deferred_events_resolve_after_item_created() {
        let db = test_db();

        // First: send a text edit for an item that doesn't exist yet.
        let edit_event = ItemEvent::new_local(
            "item-1".to_string(),
            "device-B",
            ItemEventPayload::TextEdited {
                new_text: "edited text".to_string(),
                base_content_version: 1,
            },
        );
        replay::apply_remote_event(db.pool(), &edit_event).unwrap();

        // Now send the ItemCreated.
        let create_event = ItemEvent::new_local(
            "item-1".to_string(),
            "device-B",
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("original"),
            },
        );

        // Use batch apply to trigger deferred retry.
        let result = replay::apply_remote_event_batch(db.pool(), &[create_event]).unwrap();

        // The create should have applied, and the deferred edit should have been retried.
        assert!(result.events_applied >= 1);
        assert_eq!(result.events_deferred, 0);

        // Verify the projection has content_version bumped from the edit.
        let sync = SyncStore::new(db.pool());
        let proj = sync.fetch_projection("item-1").unwrap().unwrap();
        let versions = assert_projection_pending(&proj);
        assert_eq!(versions.content, 2); // 1 from create + 1 from edit
    }

    #[test]
    fn apply_remote_snapshot_updates_projection() {
        let db = test_db();
        let sync = SyncStore::new(db.pool());

        let versions = VersionVector {
            content: 5,
            bookmark: 2,
            existence: 1,
            touch: 10,
            metadata: 3,
        };
        let agg = ItemAggregate::Live(LiveItemState {
            snapshot: text_snapshot("snapshot data"),
            versions,
        });
        let snapshot = ItemSnapshot::initial("item-1".to_string(), agg);

        let applied = replay::apply_remote_snapshots(db.pool(), &[snapshot]).unwrap();
        assert_eq!(applied, 1);

        let proj = sync.fetch_projection("item-1").unwrap().unwrap();
        let projected_versions = assert_projection_pending(&proj);
        assert_eq!(projected_versions, versions);
    }

    #[test]
    fn older_snapshot_is_rejected() {
        let db = test_db();

        let agg = ItemAggregate::Live(LiveItemState {
            snapshot: text_snapshot("new"),
            versions: default_versions(),
        });
        let snap_v2 =
            ItemSnapshot::compacted("item-1".to_string(), 1, "evt-2".to_string(), agg.clone());
        replay::apply_remote_snapshots(db.pool(), &[snap_v2]).unwrap();

        // Try to apply an older snapshot.
        let snap_v1 = ItemSnapshot::initial("item-1".to_string(), agg);
        let applied = replay::apply_remote_snapshots(db.pool(), &[snap_v1]).unwrap();
        assert_eq!(applied, 0);
    }

    #[test]
    fn full_resync_clears_and_rebuilds() {
        let db = test_db();
        let sync = SyncStore::new(db.pool());

        // Setup some existing state.
        setup_item_in_db(&db, "old-item");
        sync.mark_event_applied("old-evt").unwrap();

        // Full resync with new snapshots.
        let agg = ItemAggregate::Live(LiveItemState {
            snapshot: text_snapshot("resync item"),
            versions: default_versions(),
        });
        let snapshot = ItemSnapshot::initial("new-item".to_string(), agg);

        let applied = replay::full_resync_from_snapshots(db.pool(), &[snapshot]).unwrap();
        assert_eq!(applied, 1);

        // Old state should be gone.
        assert!(sync.fetch_projection("old-item").unwrap().is_none());
        assert!(!sync.is_event_applied("old-evt").unwrap());

        // New state should exist.
        assert!(sync.fetch_projection("new-item").unwrap().is_some());
        assert!(!sync.get_dirty_flag(FLAG_NEEDS_FULL_RESYNC).unwrap());
    }

    #[test]
    fn batch_apply_with_fork_reports_plan() {
        let db = test_db();

        // Create an item first.
        let create_event = ItemEvent::new_local(
            "item-1".to_string(),
            "device-A",
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("original"),
            },
        );
        replay::apply_remote_event(db.pool(), &create_event).unwrap();

        // Now simulate advancing the content version.
        let edit1 = ItemEvent::new_local(
            "item-1".to_string(),
            "device-A",
            ItemEventPayload::TextEdited {
                new_text: "edit 1".to_string(),
                base_content_version: 1,
            },
        );
        replay::apply_remote_event(db.pool(), &edit1).unwrap();

        // Another edit from a different device on the original base — should fork.
        let edit2 = ItemEvent::new_local(
            "item-1".to_string(),
            "device-B",
            ItemEventPayload::TextEdited {
                new_text: "conflicting edit".to_string(),
                base_content_version: 1,
            },
        );

        let result = replay::apply_remote_event_batch(db.pool(), &[edit2]).unwrap();
        assert_eq!(result.events_forked, 1);
        assert_eq!(result.fork_plans.len(), 1);
        assert_eq!(
            result.fork_plans[0].1.forked_snapshot.content_text,
            "conflicting edit"
        );
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// COMPACTION TESTS
// ═══════════════════════════════════════════════════════════════════════════════

mod compaction_tests {
    use super::*;

    fn seed_item_with_events(db: &Database, global_id: &str, n_events: usize) {
        let sync = SyncStore::new(db.pool());

        // Create the item.
        let create_event = ItemEvent::new_local(
            global_id.to_string(),
            "device-A",
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("compaction test"),
            },
        );
        sync.append_local_event(&create_event).unwrap();

        let agg = ItemAggregate::Live(LiveItemState {
            snapshot: text_snapshot("compaction test"),
            versions: default_versions(),
        });
        let snap = ItemSnapshot::initial(global_id.to_string(), agg);
        sync.upsert_snapshot(&snap).unwrap();
        sync.upsert_projection(
            global_id,
            &ProjectionState::Materialized {
                versions: default_versions(),
            },
        )
        .unwrap();

        // Add touch events.
        for i in 0..n_events {
            let touch_event = ItemEvent::new_local(
                global_id.to_string(),
                "device-A",
                ItemEventPayload::ItemTouched {
                    new_last_used_at_unix: 1000000 + (i as i64),
                    base_touch_version: 1 + (i as u64),
                },
            );
            sync.append_local_event(&touch_event).unwrap();
        }
    }

    #[test]
    fn compaction_not_needed_below_threshold() {
        let db = test_db();
        seed_item_with_events(&db, "item-1", 10);

        let sync = SyncStore::new(db.pool());
        assert!(!compactor::needs_compaction(&sync, "item-1").unwrap());
    }

    #[test]
    fn compaction_triggered_above_event_threshold() {
        let db = test_db();
        // 32+ events triggers compaction (1 create + 32 touches = 33 total).
        seed_item_with_events(&db, "item-1", COMPACTION_EVENT_THRESHOLD);

        let sync = SyncStore::new(db.pool());
        assert!(compactor::needs_compaction(&sync, "item-1").unwrap());
    }

    #[test]
    fn compact_item_produces_snapshot() {
        let db = test_db();
        seed_item_with_events(&db, "item-1", COMPACTION_EVENT_THRESHOLD);

        let result = compactor::compact_item(db.pool(), "item-1").unwrap();
        match result {
            CompactionOutcome::Compacted {
                snapshot,
                events_compacted,
            } => {
                assert!(events_compacted > 0);
                assert_eq!(snapshot.snapshot_revision, 2); // initial=1, compacted=2
                assert_eq!(snapshot.item_id, "item-1");
            }
            other => panic!("expected Compacted, got {other:?}"),
        }

        // After compaction, uncompacted count should be 0.
        let sync = SyncStore::new(db.pool());
        assert_eq!(sync.count_uncompacted_events("item-1").unwrap(), 0);
    }

    #[test]
    fn compact_all_processes_eligible_items() {
        let db = test_db();
        seed_item_with_events(&db, "item-1", COMPACTION_EVENT_THRESHOLD);
        seed_item_with_events(&db, "item-2", 5); // below threshold

        let count = compactor::compact_all(db.pool()).unwrap();
        assert_eq!(count, 1); // only item-1 was eligible
    }

    #[test]
    fn compact_no_events_returns_no_events() {
        let db = test_db();

        let result = compactor::compact_item(db.pool(), "nonexistent").unwrap();
        assert_eq!(result, CompactionOutcome::NoEvents);
    }

    #[test]
    fn compacted_events_are_not_refetched_as_uncompacted() {
        let db = test_db();
        seed_item_with_events(&db, "item-1", COMPACTION_EVENT_THRESHOLD);

        compactor::compact_item(db.pool(), "item-1").unwrap();

        let sync = SyncStore::new(db.pool());
        let uncompacted = sync.fetch_uncompacted_events("item-1").unwrap();
        assert!(uncompacted.is_empty());
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// EVENT-SOURCED WRITE PATH TESTS
// ═══════════════════════════════════════════════════════════════════════════════

mod write_path_tests {
    use super::*;

    #[test]
    fn save_text_emits_item_created_event() {
        let (store, dir) = test_store();

        let id = store
            .save_text("hello sync".to_string(), None, None)
            .unwrap();
        assert!(!id.is_empty());

        // Verify event was emitted.
        let pending = store.pending_local_events().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].payload_type, "item_created");

        // Verify projection exists.
        let db = store_db(&dir);
        let sync = SyncStore::new(db.pool());
        let proj = sync.fetch_projection(&id).unwrap().unwrap();
        let versions = assert_projection_materialized(&proj);
        assert_eq!(versions.content, 1);
        assert_eq!(versions.existence, 1);
    }

    #[test]
    fn duplicate_save_text_emits_touch_event() {
        let (store, _dir) = test_store();

        // First save.
        let id = store
            .save_text("hello sync".to_string(), None, None)
            .unwrap();
        assert!(!id.is_empty());

        // Duplicate save (returns 0 for dedup).
        let id2 = store
            .save_text("hello sync".to_string(), None, None)
            .unwrap();
        assert!(id2.is_empty());

        // Should have 2 events: item_created + item_touched.
        let pending = store.pending_local_events().unwrap();
        assert_eq!(pending.len(), 2);
        assert_eq!(pending[0].payload_type, "item_created");
        assert_eq!(pending[1].payload_type, "item_touched");
    }

    #[test]
    fn delete_item_emits_deleted_event() {
        let (store, dir) = test_store();

        let id = store
            .save_text("to delete".to_string(), None, None)
            .unwrap();
        store.delete_item(id.clone()).unwrap();

        let pending = store.pending_local_events().unwrap();
        assert!(pending.len() >= 2);
        let delete_events: Vec<_> = pending
            .iter()
            .filter(|e| e.payload_type == "item_deleted")
            .collect();
        assert_eq!(delete_events.len(), 1);

        let db = store_db(&dir);
        let sync = SyncStore::new(db.pool());

        let projection = sync.fetch_projection(&id).unwrap().unwrap();
        assert_projection_tombstoned(&projection);
    }

    #[test]
    fn update_text_item_emits_text_edited_event() {
        let (store, _dir) = test_store();

        let id = store.save_text("original".to_string(), None, None).unwrap();
        store
            .update_text_item(id.clone(), "edited".to_string())
            .unwrap();

        let pending = store.pending_local_events().unwrap();
        let edit_events: Vec<_> = pending
            .iter()
            .filter(|e| e.payload_type == "text_edited")
            .collect();
        assert_eq!(edit_events.len(), 1);
    }

    #[test]
    fn sequential_local_text_edits_advance_sync_versions() {
        let (store, dir) = test_store();

        let id = store.save_text("original".to_string(), None, None).unwrap();
        store
            .update_text_item(id.clone(), "edited once".to_string())
            .unwrap();
        store
            .update_text_item(id.clone(), "edited twice".to_string())
            .unwrap();

        let pending = store.pending_local_events().unwrap();
        let edit_events: Vec<_> = pending
            .iter()
            .filter(|event| event.payload_type == "text_edited")
            .map(|event| {
                ItemEvent::from_stored(
                    event.event_id.clone(),
                    event.item_id.clone(),
                    event.origin_device_id.clone(),
                    event.schema_version,
                    event.recorded_at,
                    &event.payload_type,
                    &event.payload_data,
                )
                .unwrap()
            })
            .collect();

        assert_eq!(edit_events.len(), 2);
        match &edit_events[0].payload {
            ItemEventPayload::TextEdited {
                base_content_version,
                ..
            } => assert_eq!(*base_content_version, 1),
            other => panic!("expected text_edited payload, got {other:?}"),
        }
        match &edit_events[1].payload {
            ItemEventPayload::TextEdited {
                base_content_version,
                ..
            } => assert_eq!(*base_content_version, 2),
            other => panic!("expected text_edited payload, got {other:?}"),
        }

        let db = store_db(&dir);
        let sync = SyncStore::new(db.pool());
        let projection = sync.fetch_projection(&id).unwrap().unwrap();
        let versions = assert_projection_materialized(&projection);
        assert_eq!(versions.content, 3);
    }

    #[test]
    fn add_tag_emits_bookmark_set_event() {
        let (store, _dir) = test_store();

        let id = store
            .save_text("bookmarkable".to_string(), None, None)
            .unwrap();
        store
            .add_tag(id, purr::interface::ItemTag::Bookmark)
            .unwrap();

        let pending = store.pending_local_events().unwrap();
        let bookmark_events: Vec<_> = pending
            .iter()
            .filter(|e| e.payload_type == "bookmark_set")
            .collect();
        assert_eq!(bookmark_events.len(), 1);
    }

    #[test]
    fn remove_tag_emits_bookmark_cleared_event() {
        let (store, _dir) = test_store();

        let id = store
            .save_text("bookmarked".to_string(), None, None)
            .unwrap();
        store
            .add_tag(id.clone(), purr::interface::ItemTag::Bookmark)
            .unwrap();
        store
            .remove_tag(id.clone(), purr::interface::ItemTag::Bookmark)
            .unwrap();

        let pending = store.pending_local_events().unwrap();
        let cleared_events: Vec<_> = pending
            .iter()
            .filter(|e| e.payload_type == "bookmark_cleared")
            .collect();
        assert_eq!(cleared_events.len(), 1);
    }

    #[test]
    fn update_timestamp_emits_touched_event() {
        let (store, _dir) = test_store();

        let id = store.save_text("touch me".to_string(), None, None).unwrap();
        store.update_timestamp(id).unwrap();

        let pending = store.pending_local_events().unwrap();
        let touch_events: Vec<_> = pending
            .iter()
            .filter(|e| e.payload_type == "item_touched")
            .collect();
        assert_eq!(touch_events.len(), 1);
    }

    #[test]
    fn set_sync_device_id_restamps_local_events() {
        let (store, _dir) = test_store();

        // Events emitted before set_sync_device_id have origin_device_id "local".
        let id = store.save_text("before sync".to_string(), None, None).unwrap();
        assert!(!id.is_empty());

        let pending = store.pending_local_events().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].origin_device_id, "local");

        // Setting the real device ID should restamp existing events.
        store.set_sync_device_id("device-abc-123".to_string());

        let pending = store.pending_local_events().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].origin_device_id, "device-abc-123");
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// EVENT SERIALIZATION TESTS
// ═══════════════════════════════════════════════════════════════════════════════

mod serialization_tests {
    use super::*;

    #[test]
    fn event_roundtrip_item_created() {
        let snapshot = text_snapshot("hello");
        let event = ItemEvent::new_local(
            "item-1".to_string(),
            "dev-A",
            ItemEventPayload::ItemCreated {
                snapshot: snapshot.clone(),
            },
        );

        let payload_data = event.payload_data();
        let payload_type = event.payload_type();

        let restored = ItemEvent::from_stored(
            event.event_id.clone(),
            event.item_id.clone(),
            event.origin_device_id.clone(),
            event.schema_version,
            event.recorded_at,
            &payload_type,
            &payload_data,
        )
        .unwrap();

        assert_eq!(restored.payload, event.payload);
    }

    #[test]
    fn event_roundtrip_text_edited() {
        let event = ItemEvent::new_local(
            "item-1".to_string(),
            "dev-A",
            ItemEventPayload::TextEdited {
                new_text: "edited text".to_string(),
                base_content_version: 5,
            },
        );

        let restored = ItemEvent::from_stored(
            event.event_id.clone(),
            event.item_id.clone(),
            event.origin_device_id.clone(),
            event.schema_version,
            event.recorded_at,
            &event.payload_type(),
            &event.payload_data(),
        )
        .unwrap();

        assert_eq!(restored.payload, event.payload);
    }

    #[test]
    fn snapshot_roundtrip() {
        let agg = ItemAggregate::Live(LiveItemState {
            snapshot: text_snapshot("snapshot test"),
            versions: VersionVector {
                content: 3,
                bookmark: 1,
                existence: 1,
                touch: 7,
                metadata: 2,
            },
        });

        let snapshot = ItemSnapshot::initial("item-1".to_string(), agg.clone());
        let data = snapshot.aggregate_data();

        let restored = ItemSnapshot::from_stored(
            "item-1".to_string(),
            1,
            SYNC_SCHEMA_VERSION,
            None,
            &data,
            false,
            None,
        )
        .unwrap();

        assert_eq!(restored.aggregate, agg);
    }

    #[test]
    fn tombstone_aggregate_roundtrip() {
        let agg = tombstone_aggregate("text", default_versions());
        let data = serde_json::to_string(&agg).unwrap();
        let restored: ItemAggregate = serde_json::from_str(&data).unwrap();
        match (&agg, &restored) {
            (ItemAggregate::Tombstoned(orig), ItemAggregate::Tombstoned(rest)) => {
                assert_eq!(orig.content_type, rest.content_type);
                assert_eq!(orig.versions, rest.versions);
            }
            _ => panic!("tombstone roundtrip failed"),
        }
    }

    #[test]
    fn all_payload_types_serialize() {
        let payloads = vec![
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("test"),
            },
            ItemEventPayload::TextEdited {
                new_text: "edit".to_string(),
                base_content_version: 1,
            },
            ItemEventPayload::BookmarkSet {
                base_bookmark_version: 0,
            },
            ItemEventPayload::BookmarkCleared {
                base_bookmark_version: 1,
            },
            ItemEventPayload::ItemDeleted {
                base_existence_version: 1,
            },
            ItemEventPayload::ItemTouched {
                new_last_used_at_unix: 123456,
                base_touch_version: 1,
            },
            ItemEventPayload::LinkMetadataUpdated {
                metadata: LinkMetadataSnapshot {
                    title: Some("Title".to_string()),
                    description: None,
                    image_data_base64: None,
                },
                base_metadata_version: 1,
            },
            ItemEventPayload::ImageDescriptionUpdated {
                description: "A photo".to_string(),
                base_content_version: 1,
            },
        ];

        for payload in payloads {
            let json = serde_json::to_string(&payload).unwrap();
            let restored: ItemEventPayload = serde_json::from_str(&json).unwrap();
            assert_eq!(restored, payload);
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TOMBSTONE LIFECYCLE TESTS
// ═══════════════════════════════════════════════════════════════════════════════

mod tombstone_tests {
    use super::*;

    #[test]
    fn create_then_delete_produces_tombstone() {
        let snapshot = text_snapshot("mortal item");
        let create_payload = ItemEventPayload::ItemCreated {
            snapshot: snapshot.clone(),
        };
        let create_result = projector::apply_event(None, &create_payload);
        let agg = match create_result {
            ApplyResult::Applied(delta) => delta.new_aggregate,
            other => panic!("expected Applied, got {other:?}"),
        };

        let delete_payload = ItemEventPayload::ItemDeleted {
            base_existence_version: 1,
        };
        let delete_result = projector::apply_event(Some(&agg), &delete_payload);
        match delete_result {
            ApplyResult::Applied(delta) => match &delta.new_aggregate {
                ItemAggregate::Tombstoned(tomb) => {
                    assert_eq!(tomb.content_type, "text");
                    assert_eq!(tomb.versions.existence, 2);
                }
                _ => panic!("expected Tombstoned"),
            },
            other => panic!("expected Applied, got {other:?}"),
        }
    }

    #[test]
    fn all_operations_ignored_on_tombstone_except_edit() {
        let versions = VersionVector {
            content: 1,
            bookmark: 0,
            existence: 2,
            touch: 1,
            metadata: 1,
        };
        let agg = tombstone_aggregate("text", versions);

        let operations: Vec<ItemEventPayload> = vec![
            ItemEventPayload::BookmarkSet {
                base_bookmark_version: 0,
            },
            ItemEventPayload::BookmarkCleared {
                base_bookmark_version: 0,
            },
            ItemEventPayload::ItemDeleted {
                base_existence_version: 2,
            },
            ItemEventPayload::ItemTouched {
                new_last_used_at_unix: 999,
                base_touch_version: 1,
            },
            ItemEventPayload::LinkMetadataUpdated {
                metadata: LinkMetadataSnapshot {
                    title: Some("Title".to_string()),
                    description: None,
                    image_data_base64: None,
                },
                base_metadata_version: 1,
            },
            ItemEventPayload::ImageDescriptionUpdated {
                description: "desc".to_string(),
                base_content_version: 1,
            },
        ];

        for op in operations {
            let result = projector::apply_event(Some(&agg), &op);
            assert!(
                matches!(
                    result,
                    ApplyResult::Ignored(IgnoreReason::OperationOnTombstone)
                ),
                "expected Ignored for {:?}, got {:?}",
                op.type_tag(),
                result
            );
        }

        // But text edit on tombstone should fork.
        let edit = ItemEventPayload::TextEdited {
            new_text: "resurrection".to_string(),
            base_content_version: 1,
        };
        let result = projector::apply_event(Some(&agg), &edit);
        assert!(matches!(result, ApplyResult::Forked(_)));
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// SNAPSHOT DATA CONSTRUCTION TESTS
// ═══════════════════════════════════════════════════════════════════════════════

mod snapshot_data_tests {
    use super::*;

    #[test]
    fn text_snapshot_data_fields() {
        let snap = text_snapshot("hello world");
        assert_eq!(snap.content_type, "text");
        assert_eq!(snap.content_text, "hello world");
        assert!(!snap.is_bookmarked);
        match &snap.type_specific {
            TypeSpecificData::Text { value } => assert_eq!(value, "hello world"),
            other => panic!("expected Text, got {other:?}"),
        }
    }

    #[test]
    fn image_snapshot_data_fields() {
        let snap = image_snapshot("A beautiful sunset");
        assert_eq!(snap.content_type, "image");
        match &snap.type_specific {
            TypeSpecificData::Image {
                description,
                is_animated,
                ..
            } => {
                assert_eq!(description, "A beautiful sunset");
                assert!(!is_animated);
            }
            other => panic!("expected Image, got {other:?}"),
        }
    }

    #[test]
    fn link_snapshot_data_fields() {
        let snap = link_snapshot("https://example.com");
        assert_eq!(snap.content_type, "link");
        match &snap.type_specific {
            TypeSpecificData::Link { url, metadata } => {
                assert_eq!(url, "https://example.com");
                assert!(metadata.is_none());
            }
            other => panic!("expected Link, got {other:?}"),
        }
    }

    #[test]
    fn file_snapshot_data() {
        let snap = ItemSnapshotData {
            content_type: "file".to_string(),
            content_text: "File: test.txt".to_string(),
            content_hash: "hash_file".to_string(),
            source_app: None,
            source_app_bundle_id: None,
            timestamp_unix: 1000000,
            is_bookmarked: false,
            thumbnail_base64: None,
            color_rgba: None,
            type_specific: TypeSpecificData::File {
                display_name: "File: test.txt".to_string(),
                files: vec![FileSnapshotEntry {
                    path: "/tmp/test.txt".to_string(),
                    filename: "test.txt".to_string(),
                    file_size: 1024,
                    uti: "public.plain-text".to_string(),
                    bookmark_data_base64: "AQID".to_string(),
                    file_status: "available".to_string(),
                }],
            },
        };

        let json = serde_json::to_string(&snap).unwrap();
        let restored: ItemSnapshotData = serde_json::from_str(&json).unwrap();
        assert_eq!(snap, restored);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// ADDITIONAL PROJECTOR TESTS — Audit-driven
// ═══════════════════════════════════════════════════════════════════════════════

mod projector_audit_tests {
    use super::*;

    #[test]
    fn item_created_bookmarked_bumps_bookmark_domain() {
        let mut snapshot = text_snapshot("bookmarked item");
        snapshot.is_bookmarked = true;
        let payload = ItemEventPayload::ItemCreated { snapshot };

        let result = projector::apply_event(None, &payload);
        match result {
            ApplyResult::Applied(delta) => {
                assert!(delta.bumped_domains.contains(&VersionDomain::Bookmark));
                match &delta.new_aggregate {
                    ItemAggregate::Live(live) => {
                        assert_eq!(live.versions.bookmark, 1);
                        assert!(live.snapshot.is_bookmarked);
                    }
                    _ => panic!("expected Live aggregate"),
                }
            }
            other => panic!("expected Applied, got {other:?}"),
        }
    }

    #[test]
    fn item_created_unbookmarked_does_not_bump_bookmark_domain() {
        let snapshot = text_snapshot("plain item");
        assert!(!snapshot.is_bookmarked);
        let payload = ItemEventPayload::ItemCreated { snapshot };

        let result = projector::apply_event(None, &payload);
        match result {
            ApplyResult::Applied(delta) => {
                assert!(!delta.bumped_domains.contains(&VersionDomain::Bookmark));
                match &delta.new_aggregate {
                    ItemAggregate::Live(live) => {
                        assert_eq!(live.versions.bookmark, 0);
                    }
                    _ => panic!("expected Live aggregate"),
                }
            }
            other => panic!("expected Applied, got {other:?}"),
        }
    }

    #[test]
    fn item_touched_does_not_set_index_dirty() {
        let snapshot = text_snapshot("touchable");
        let agg = live_aggregate(snapshot, default_versions());
        let payload = ItemEventPayload::ItemTouched {
            new_last_used_at_unix: 2000000,
            base_touch_version: 1,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        match result {
            ApplyResult::Applied(delta) => {
                assert!(!delta.index_dirty, "touch should not dirty the index");
                assert!(delta.read_model_dirty);
            }
            other => panic!("expected Applied, got {other:?}"),
        }
    }

    #[test]
    fn image_description_updated_applies() {
        let snapshot = image_snapshot("original desc");
        let agg = live_aggregate(snapshot, default_versions());
        let payload = ItemEventPayload::ImageDescriptionUpdated {
            description: "new desc".to_string(),
            base_content_version: 1,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        match result {
            ApplyResult::Applied(delta) => {
                assert!(delta.index_dirty);
                match &delta.new_aggregate {
                    ItemAggregate::Live(live) => {
                        assert_eq!(live.snapshot.content_text, "new desc");
                        assert_eq!(live.versions.content, 2);
                    }
                    _ => panic!("expected Live"),
                }
            }
            other => panic!("expected Applied, got {other:?}"),
        }
    }

    #[test]
    fn link_metadata_updated_applies() {
        let snapshot = link_snapshot("https://example.com");
        let agg = live_aggregate(snapshot, default_versions());
        let metadata = LinkMetadataSnapshot {
            title: Some("Example".to_string()),
            description: Some("A website".to_string()),
            image_data_base64: None,
        };
        let payload = ItemEventPayload::LinkMetadataUpdated {
            metadata: metadata.clone(),
            base_metadata_version: 1,
        };

        let result = projector::apply_event(Some(&agg), &payload);
        match result {
            ApplyResult::Applied(delta) => {
                assert!(!delta.index_dirty);
                assert!(delta.bumped_domains.contains(&VersionDomain::Metadata));
                match &delta.new_aggregate {
                    ItemAggregate::Live(live) => {
                        assert_eq!(live.versions.metadata, 2);
                        if let TypeSpecificData::Link {
                            metadata: Some(ref meta),
                            ..
                        } = live.snapshot.type_specific
                        {
                            assert_eq!(meta.title, Some("Example".to_string()));
                        } else {
                            panic!("expected Link with metadata");
                        }
                    }
                    _ => panic!("expected Live"),
                }
            }
            other => panic!("expected Applied, got {other:?}"),
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// ADDITIONAL COMPACTION TESTS — Audit-driven
// ═══════════════════════════════════════════════════════════════════════════════

mod compaction_audit_tests {
    use super::*;

    #[test]
    fn compaction_triggered_by_payload_size() {
        let db = test_db();
        let sync = SyncStore::new(db.pool());
        let gid = "payload-heavy-item";

        // Create item with snapshot.
        let agg = ItemAggregate::Live(LiveItemState {
            snapshot: text_snapshot("seed"),
            versions: default_versions(),
        });
        let snap = ItemSnapshot::initial(gid.to_string(), agg);
        sync.upsert_snapshot(&snap).unwrap();
        sync.upsert_projection(
            gid,
            &ProjectionState::Materialized {
                versions: default_versions(),
            },
        )
        .unwrap();

        // Add events with large payload to exceed 128KB threshold.
        let big_text = "x".repeat(16 * 1024); // 16KB per event
        for i in 0..10 {
            let event = ItemEvent::new_local(
                gid.to_string(),
                "device-A",
                ItemEventPayload::TextEdited {
                    new_text: big_text.clone(),
                    base_content_version: 1 + (i as u64),
                },
            );
            sync.append_local_event(&event).unwrap();
        }

        // 10 events * 16KB = 160KB > 128KB threshold, but only 10 < 32 event threshold.
        assert!(
            compactor::needs_compaction(&sync, gid).unwrap(),
            "payload size should trigger compaction"
        );
    }

    #[test]
    fn compaction_triggered_by_age() {
        let db = test_db();
        let sync = SyncStore::new(db.pool());
        let gid = "old-item";

        // Create item with snapshot.
        let agg = ItemAggregate::Live(LiveItemState {
            snapshot: text_snapshot("old item"),
            versions: default_versions(),
        });
        let snap = ItemSnapshot::initial(gid.to_string(), agg);
        sync.upsert_snapshot(&snap).unwrap();
        sync.upsert_projection(
            gid,
            &ProjectionState::Materialized {
                versions: default_versions(),
            },
        )
        .unwrap();

        // Add an event with old timestamp (8 days ago).
        let old_timestamp = chrono::Utc::now().timestamp() - (8 * 24 * 3600);
        let event_id = uuid::Uuid::new_v4().to_string();
        let event = ItemEvent::from_stored(
            event_id,
            gid.to_string(),
            "device-A".to_string(),
            SYNC_SCHEMA_VERSION,
            old_timestamp,
            "item_touched",
            &serde_json::to_string(&ItemEventPayload::ItemTouched {
                new_last_used_at_unix: old_timestamp,
                base_touch_version: 1,
            })
            .unwrap(),
        )
        .unwrap();
        sync.append_local_event(&event).unwrap();

        assert!(
            compactor::needs_compaction(&sync, gid).unwrap(),
            "old event age should trigger compaction"
        );
    }

    #[test]
    fn compaction_triggered_by_tombstone_age() {
        let db = test_db();
        let sync = SyncStore::new(db.pool());
        let gid = "tombstoned-item";

        // Create tombstoned snapshot (31+ days old).
        let old_delete_time = chrono::Utc::now().timestamp() - (31 * 24 * 3600);
        let tomb_agg = ItemAggregate::Tombstoned(TombstoneState {
            deleted_at_unix: old_delete_time,
            versions: VersionVector {
                content: 1,
                bookmark: 0,
                existence: 2,
                touch: 1,
                metadata: 1,
            },
            content_type: "text".to_string(),
        });
        let snap = ItemSnapshot::initial(gid.to_string(), tomb_agg);
        sync.upsert_snapshot(&snap).unwrap();
        sync.upsert_projection(
            gid,
            &ProjectionState::Tombstoned {
                versions: VersionVector {
                    content: 1,
                    bookmark: 0,
                    existence: 2,
                    touch: 1,
                    metadata: 1,
                },
            },
        )
        .unwrap();

        // Add a single stale event.
        let event = ItemEvent::new_local(
            gid.to_string(),
            "device-A",
            ItemEventPayload::ItemTouched {
                new_last_used_at_unix: chrono::Utc::now().timestamp(),
                base_touch_version: 1,
            },
        );
        sync.append_local_event(&event).unwrap();

        assert!(
            compactor::needs_compaction(&sync, gid).unwrap(),
            "old tombstone with events should trigger compaction"
        );
    }

    #[test]
    fn purge_retained_events_removes_old_compacted() {
        let db = test_db();
        let sync = SyncStore::new(db.pool());
        let gid = "purge-test";

        // Seed item and run compaction.
        let create_event = ItemEvent::new_local(
            gid.to_string(),
            "device-A",
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("purge test"),
            },
        );
        sync.append_local_event(&create_event).unwrap();

        let agg = ItemAggregate::Live(LiveItemState {
            snapshot: text_snapshot("purge test"),
            versions: default_versions(),
        });
        let snap = ItemSnapshot::initial(gid.to_string(), agg);
        sync.upsert_snapshot(&snap).unwrap();
        sync.upsert_projection(
            gid,
            &ProjectionState::Materialized {
                versions: default_versions(),
            },
        )
        .unwrap();

        // Add enough events to trigger compaction.
        for i in 0..COMPACTION_EVENT_THRESHOLD {
            let event = ItemEvent::new_local(
                gid.to_string(),
                "device-A",
                ItemEventPayload::ItemTouched {
                    new_last_used_at_unix: 1000000 + (i as i64),
                    base_touch_version: 1 + (i as u64),
                },
            );
            sync.append_local_event(&event).unwrap();
        }

        compactor::compact_item(db.pool(), gid).unwrap();

        // Purge with a threshold far in the future so all compacted events are "old".
        let future_threshold = chrono::Utc::now().timestamp() + 100000;
        let purged = sync
            .delete_compacted_events_before(future_threshold)
            .unwrap();
        assert!(purged > 0, "should purge compacted events");
    }

    #[test]
    fn purge_tombstone_snapshots_removes_old_tombstones() {
        let db = test_db();
        let sync = SyncStore::new(db.pool());

        // Create a very old tombstone.
        let old_delete_time =
            chrono::Utc::now().timestamp() - (TOMBSTONE_SNAPSHOT_RETENTION_SECS + 1);
        let tomb_agg = ItemAggregate::Tombstoned(TombstoneState {
            deleted_at_unix: old_delete_time,
            versions: default_versions(),
            content_type: "text".to_string(),
        });
        let snap = ItemSnapshot::initial("old-tombstone".to_string(), tomb_agg);
        sync.upsert_snapshot(&snap).unwrap();
        sync.upsert_projection(
            "old-tombstone",
            &ProjectionState::Tombstoned {
                versions: default_versions(),
            },
        )
        .unwrap();

        // Create a recent tombstone.
        let recent_agg = ItemAggregate::Tombstoned(TombstoneState {
            deleted_at_unix: chrono::Utc::now().timestamp(),
            versions: default_versions(),
            content_type: "text".to_string(),
        });
        let snap2 = ItemSnapshot::initial("recent-tombstone".to_string(), recent_agg);
        sync.upsert_snapshot(&snap2).unwrap();

        let purged = compactor::purge_tombstone_snapshots(db.pool()).unwrap();
        assert_eq!(purged, 1, "only the old tombstone should be purged");

        // Verify the recent one still exists.
        assert!(sync.fetch_snapshot("recent-tombstone").unwrap().is_some());
        assert!(sync.fetch_snapshot("old-tombstone").unwrap().is_none());
        assert!(sync.fetch_projection("old-tombstone").unwrap().is_none());
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// ADDITIONAL WRITE PATH TESTS — Audit-driven
// ═══════════════════════════════════════════════════════════════════════════════

mod write_path_audit_tests {
    use super::*;

    #[test]
    fn save_image_emits_item_created_event() {
        let (store, _dir) = test_store();

        // PNG header bytes (minimal valid PNG-like data).
        let png_bytes = vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3];
        let id = store
            .save_image(png_bytes, None, None, None, false)
            .unwrap();
        assert!(!id.is_empty());

        let pending = store.pending_local_events().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].payload_type, "item_created");
    }

    #[test]
    fn save_file_emits_item_created_event() {
        let (store, _dir) = test_store();

        let id = store
            .save_file(
                "/tmp/test.txt".to_string(),
                "test.txt".to_string(),
                1024,
                "public.plain-text".to_string(),
                vec![1, 2, 3],
                None,
                None,
                None,
            )
            .unwrap();
        assert!(!id.is_empty());

        let pending = store.pending_local_events().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].payload_type, "item_created");
    }

    #[test]
    fn update_link_metadata_emits_event() {
        let (store, _dir) = test_store();

        let id = store
            .save_text("https://example.com".to_string(), None, None)
            .unwrap();
        store
            .update_link_metadata(
                id,
                Some("Example".to_string()),
                Some("Description".to_string()),
                None,
            )
            .unwrap();

        let pending = store.pending_local_events().unwrap();
        let meta_events: Vec<_> = pending
            .iter()
            .filter(|e| e.payload_type == "link_metadata_updated")
            .collect();
        assert_eq!(meta_events.len(), 1);
    }

    #[test]
    fn update_image_description_emits_event() {
        let (store, _dir) = test_store();

        let png_bytes = vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3];
        let id = store
            .save_image(png_bytes, None, None, None, false)
            .unwrap();
        store
            .update_image_description(id, "A nice photo".to_string())
            .unwrap();

        let pending = store.pending_local_events().unwrap();
        let desc_events: Vec<_> = pending
            .iter()
            .filter(|e| e.payload_type == "image_description_updated")
            .collect();
        assert_eq!(desc_events.len(), 1);
    }

    #[test]
    fn clear_emits_delete_events_and_retains_sync_tombstones() {
        let (store, dir) = test_store();

        let first_id = store
            .save_text("will be cleared".to_string(), None, None)
            .unwrap();
        let second_id = store
            .save_text("will also be cleared".to_string(), None, None)
            .unwrap();
        assert!(!first_id.is_empty());
        assert!(!second_id.is_empty());

        let pending = store.pending_local_events().unwrap();
        let created_count = pending
            .iter()
            .filter(|event| event.payload_type == "item_created")
            .count();
        assert_eq!(created_count, 2);

        store.clear().unwrap();

        let pending = store.pending_local_events().unwrap();
        let delete_events: Vec<_> = pending
            .iter()
            .filter(|event| event.payload_type == "item_deleted")
            .collect();
        assert_eq!(delete_events.len(), 2);

        let db = store_db(&dir);
        let sync = SyncStore::new(db.pool());

        for event in delete_events {
            let projection = sync.fetch_projection(&event.item_id).unwrap().unwrap();
            assert_projection_tombstoned(&projection);
        }
    }

    #[test]
    fn pending_snapshot_records_only_include_unuploaded_snapshots() {
        let (store, _dir) = test_store();

        let id = store
            .save_text("snapshot me".to_string(), None, None)
            .unwrap();
        let pending = store.pending_snapshot_records().unwrap();
        assert_eq!(pending.len(), 1);

        store.mark_snapshot_uploaded(id).unwrap();

        let pending = store.pending_snapshot_records().unwrap();
        assert!(pending.is_empty());
    }

    #[test]
    fn prune_to_size_emits_delete_events() {
        let (store, _dir) = test_store();

        // Save several items.
        for i in 0..5 {
            store
                .save_text(format!("item {i} with some text"), None, None)
                .unwrap();
        }

        // Mark all events as uploaded so we can distinguish new delete events.
        let pending = store.pending_local_events().unwrap();
        let event_ids: Vec<String> = pending.iter().map(|e| e.event_id.clone()).collect();
        store.mark_events_uploaded(event_ids).unwrap();

        // Prune with very small limit to force deletions.
        let pruned = store.prune_to_size(1, 0.5).unwrap();

        if pruned > 0 {
            let new_pending = store.pending_local_events().unwrap();
            let delete_events: Vec<_> = new_pending
                .iter()
                .filter(|e| e.payload_type == "item_deleted")
                .collect();
            assert!(
                !delete_events.is_empty(),
                "pruning should emit item_deleted events"
            );
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// ADDITIONAL REPLAY TESTS — Out-of-order events
// ═══════════════════════════════════════════════════════════════════════════════

mod replay_audit_tests {
    use super::*;

    #[test]
    fn out_of_order_events_are_deferred_then_resolved() {
        let db = test_db();
        let gid = "ooo-item";

        // Apply a TextEdited event before ItemCreated — should be deferred.
        let edit_event = ItemEvent::new_local(
            gid.to_string(),
            "device-B",
            ItemEventPayload::TextEdited {
                new_text: "edited text".to_string(),
                base_content_version: 1,
            },
        );
        let result = replay::apply_remote_event(db.pool(), &edit_event).unwrap();
        assert!(
            matches!(result, ApplyResult::Deferred(_)),
            "edit before create should be deferred"
        );

        // Now apply ItemCreated — this should resolve the deferred event.
        let create_event = ItemEvent::new_local(
            gid.to_string(),
            "device-B",
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("original"),
            },
        );

        // Use batch apply which retries deferred events.
        let batch = replay::apply_remote_event_batch(db.pool(), &[create_event]).unwrap();
        // 2 applied: the create itself + the deferred edit resolved during retry.
        assert_eq!(
            batch.events_applied, 2,
            "create + deferred edit should apply"
        );

        // The deferred edit should have been retried and resolved.
        let sync = SyncStore::new(db.pool());
        let deferred_count = sync.count_deferred_events().unwrap();
        assert_eq!(
            deferred_count, 0,
            "deferred event should be resolved after create"
        );
    }

    #[test]
    fn batch_apply_tracks_all_outcome_types() {
        let db = test_db();
        let gid = "batch-item";

        // Create item first.
        let create = ItemEvent::new_local(
            gid.to_string(),
            "device-C",
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("batch test"),
            },
        );
        replay::apply_remote_event(db.pool(), &create).unwrap();

        // Apply a matching edit (should apply).
        let edit = ItemEvent::new_local(
            gid.to_string(),
            "device-C",
            ItemEventPayload::TextEdited {
                new_text: "edited".to_string(),
                base_content_version: 1,
            },
        );

        // Apply same create again (should be ignored as dup).
        let dup_create = ItemEvent::new_local(
            gid.to_string(),
            "device-C",
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("batch test"),
            },
        );

        let batch = replay::apply_remote_event_batch(db.pool(), &[edit, dup_create]).unwrap();
        assert_eq!(batch.events_applied, 1);
        assert_eq!(batch.events_ignored, 1);
    }

    #[test]
    fn full_resync_with_tail_replaces_stale_local_rows() {
        let (store, dir) = test_store();

        let stale_id = store
            .save_text("stale local row".to_string(), None, None)
            .unwrap();
        assert!(!stale_id.is_empty());

        let aggregate = ItemAggregate::Live(LiveItemState {
            snapshot: text_snapshot("remote truth"),
            versions: default_versions(),
        });
        let snapshot = ItemSnapshot::initial("remote-item".to_string(), aggregate);
        let record = purr::interface::SyncSnapshotRecord {
            item_id: snapshot.item_id.clone(),
            snapshot_revision: snapshot.snapshot_revision,
            schema_version: snapshot.schema_version,
            covers_through_event: snapshot.covers_through_event.clone(),
            aggregate_data: snapshot.aggregate_data(),
        };

        let result = store.full_resync_with_tail(vec![record], vec![]).unwrap();
        assert_eq!(result.checkpoints_applied, 1);
        assert_eq!(result.tail_events_applied, 0);

        let db = store_db(&dir);
        assert!(db.fetch_items_by_item_ids(&[stale_id]).unwrap().is_empty());

        let all_items = db.fetch_all_items().unwrap();
        assert_eq!(all_items.len(), 1);
        assert_eq!(all_items[0].text_content(), "remote truth");
    }

    #[test]
    fn remote_bookmark_events_materialize_item_tags() {
        let (store, dir) = test_store();

        let created = ItemEvent::new_local(
            "remote-bookmark-item".to_string(),
            "device-A",
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("bookmark me"),
            },
        );
        store
            .apply_remote_event(purr::interface::SyncEventRecord {
                event_id: created.event_id.clone(),
                item_id: created.item_id.clone(),
                origin_device_id: created.origin_device_id.clone(),
                schema_version: created.schema_version,
                recorded_at: created.recorded_at,
                payload_type: created.payload_type(),
                payload_data: created.payload_data(),
            })
            .unwrap();

        let bookmarked = ItemEvent::new_local(
            "remote-bookmark-item".to_string(),
            "device-A",
            ItemEventPayload::BookmarkSet {
                base_bookmark_version: 0,
            },
        );
        store
            .apply_remote_event(purr::interface::SyncEventRecord {
                event_id: bookmarked.event_id.clone(),
                item_id: bookmarked.item_id.clone(),
                origin_device_id: bookmarked.origin_device_id.clone(),
                schema_version: bookmarked.schema_version,
                recorded_at: bookmarked.recorded_at,
                payload_type: bookmarked.payload_type(),
                payload_data: bookmarked.payload_data(),
            })
            .unwrap();

        let db = store_db(&dir);
        let item_id = db.fetch_all_items().unwrap()[0].item_id.clone();
        let mut items = store.fetch_by_ids(vec![item_id]).unwrap();
        let item = items.pop().unwrap();
        assert_eq!(
            item.item_metadata.tags,
            vec![purr::interface::ItemTag::Bookmark]
        );
    }

    #[test]
    fn remote_edit_materializes_without_churning_local_id() {
        let (store, dir) = test_store();

        let created = ItemEvent::new_local(
            "remote-stable-id".to_string(),
            "device-A",
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("before edit"),
            },
        );
        store
            .apply_remote_event(purr::interface::SyncEventRecord {
                event_id: created.event_id.clone(),
                item_id: created.item_id.clone(),
                origin_device_id: created.origin_device_id.clone(),
                schema_version: created.schema_version,
                recorded_at: created.recorded_at,
                payload_type: created.payload_type(),
                payload_data: created.payload_data(),
            })
            .unwrap();

        let db = store_db(&dir);
        let before_items = db.fetch_all_items().unwrap();
        assert_eq!(before_items.len(), 1);
        let before_id = before_items[0].id.unwrap();

        let edited = ItemEvent::new_local(
            "remote-stable-id".to_string(),
            "device-A",
            ItemEventPayload::TextEdited {
                new_text: "after edit".to_string(),
                base_content_version: 1,
            },
        );
        store
            .apply_remote_event(purr::interface::SyncEventRecord {
                event_id: edited.event_id.clone(),
                item_id: edited.item_id.clone(),
                origin_device_id: edited.origin_device_id.clone(),
                schema_version: edited.schema_version,
                recorded_at: edited.recorded_at,
                payload_type: edited.payload_type(),
                payload_data: edited.payload_data(),
            })
            .unwrap();

        let after_items = db.fetch_all_items().unwrap();
        assert_eq!(after_items.len(), 1);
        assert_eq!(after_items[0].id.unwrap(), before_id);
        assert_eq!(after_items[0].text_content(), "after edit");
    }

    #[test]
    fn duplicate_remote_event_rehydrates_missing_read_model() {
        let (store, dir) = test_store();

        let created = ItemEvent::new_local(
            "remote-heal-event".to_string(),
            "device-A",
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("healed from sync state"),
            },
        );
        let make_record = || purr::interface::SyncEventRecord {
            event_id: created.event_id.clone(),
            item_id: created.item_id.clone(),
            origin_device_id: created.origin_device_id.clone(),
            schema_version: created.schema_version,
            recorded_at: created.recorded_at,
            payload_type: created.payload_type(),
            payload_data: created.payload_data(),
        };

        store.apply_remote_event(make_record()).unwrap();

        let db = store_db(&dir);
        let row_id = db.fetch_all_items().unwrap()[0].id.unwrap();
        db.delete_item(row_id).unwrap();
        assert!(db.fetch_all_items().unwrap().is_empty());

        let outcome = store.apply_remote_event(make_record()).unwrap();
        assert!(matches!(
            outcome,
            purr::interface::SyncApplyOutcome::Ignored
        ));

        let healed_items = db.fetch_all_items().unwrap();
        assert_eq!(healed_items.len(), 1);
        assert_eq!(healed_items[0].text_content(), "healed from sync state");
    }

    #[test]
    fn duplicate_remote_snapshot_rehydrates_missing_read_model() {
        let (store, dir) = test_store();

        let snapshot = ItemSnapshot::initial(
            "remote-heal-snapshot".to_string(),
            live_aggregate(text_snapshot("snapshot healed"), default_versions()),
        );
        let make_record = || purr::interface::SyncSnapshotRecord {
            item_id: snapshot.item_id.clone(),
            snapshot_revision: snapshot.snapshot_revision,
            schema_version: snapshot.schema_version,
            covers_through_event: snapshot.covers_through_event.clone(),
            aggregate_data: snapshot.aggregate_data(),
        };

        assert!(store.apply_remote_snapshot(make_record()).unwrap());

        let db = store_db(&dir);
        let row_id = db.fetch_all_items().unwrap()[0].id.unwrap();
        db.delete_item(row_id).unwrap();
        assert!(db.fetch_all_items().unwrap().is_empty());

        assert!(!store.apply_remote_snapshot(make_record()).unwrap());

        let healed_items = db.fetch_all_items().unwrap();
        assert_eq!(healed_items.len(), 1);
        assert_eq!(healed_items[0].text_content(), "snapshot healed");
    }

    #[test]
    fn cloud_cleanup_waits_for_remote_delete_before_pruning_dedup() {
        let (store, dir) = test_store();

        let created = ItemEvent::new_local(
            "remote-cleanup-item".to_string(),
            "device-A",
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("cleanup me"),
            },
        );
        store
            .apply_remote_event(purr::interface::SyncEventRecord {
                event_id: created.event_id.clone(),
                item_id: created.item_id.clone(),
                origin_device_id: created.origin_device_id.clone(),
                schema_version: created.schema_version,
                recorded_at: created.recorded_at,
                payload_type: created.payload_type(),
                payload_data: created.payload_data(),
            })
            .unwrap();

        let db = store_db(&dir);
        let sync = SyncStore::new(db.pool());
        store
            .mark_snapshot_uploaded(created.item_id.clone())
            .unwrap();
        sync.mark_events_compacted(&[created.event_id.as_str()])
            .unwrap();

        let aged_recorded_at = chrono::Utc::now().timestamp() - (31 * 24 * 3600);
        let conn = db.pool().get().unwrap();
        conn.execute(
            "UPDATE sync_events SET recorded_at = ?1 WHERE event_id = ?2",
            rusqlite::params![aged_recorded_at, created.event_id.clone()],
        )
        .unwrap();

        let compaction = store.run_compaction().unwrap();
        assert_eq!(compaction.events_purged, 0);
        assert!(sync.is_event_applied(&created.event_id).unwrap());
        assert_eq!(
            store.purgeable_cloud_event_ids(30).unwrap(),
            vec![created.event_id.clone()]
        );

        let purged = store
            .purge_cloud_events(vec![created.event_id.clone()])
            .unwrap();
        assert_eq!(purged, 1);
        assert!(!sync.is_event_applied(&created.event_id).unwrap());
        assert!(store.purgeable_cloud_event_ids(30).unwrap().is_empty());
    }

    #[test]
    fn remote_fork_creates_new_local_synced_item() {
        let (store, dir) = test_store();

        let created = ItemEvent::new_local(
            "shared-item".to_string(),
            "device-A",
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("before edit"),
            },
        );
        store
            .apply_remote_event(purr::interface::SyncEventRecord {
                event_id: created.event_id.clone(),
                item_id: created.item_id.clone(),
                origin_device_id: created.origin_device_id.clone(),
                schema_version: created.schema_version,
                recorded_at: created.recorded_at,
                payload_type: created.payload_type(),
                payload_data: created.payload_data(),
            })
            .unwrap();

        let first_edit = ItemEvent::new_local(
            "shared-item".to_string(),
            "device-A",
            ItemEventPayload::TextEdited {
                new_text: "edited by A".to_string(),
                base_content_version: 1,
            },
        );
        store
            .apply_remote_event(purr::interface::SyncEventRecord {
                event_id: first_edit.event_id.clone(),
                item_id: first_edit.item_id.clone(),
                origin_device_id: first_edit.origin_device_id.clone(),
                schema_version: first_edit.schema_version,
                recorded_at: first_edit.recorded_at,
                payload_type: first_edit.payload_type(),
                payload_data: first_edit.payload_data(),
            })
            .unwrap();

        let conflicting_edit = ItemEvent::new_local(
            "shared-item".to_string(),
            "device-B",
            ItemEventPayload::TextEdited {
                new_text: "edited by B".to_string(),
                base_content_version: 1,
            },
        );
        let fork_result = store
            .apply_remote_event(purr::interface::SyncEventRecord {
                event_id: conflicting_edit.event_id.clone(),
                item_id: conflicting_edit.item_id.clone(),
                origin_device_id: conflicting_edit.origin_device_id.clone(),
                schema_version: conflicting_edit.schema_version,
                recorded_at: conflicting_edit.recorded_at,
                payload_type: conflicting_edit.payload_type(),
                payload_data: conflicting_edit.payload_data(),
            })
            .unwrap();
        assert!(matches!(
            fork_result,
            purr::interface::SyncApplyOutcome::Forked { .. }
        ));

        let db = store_db(&dir);
        let all_items = db.fetch_all_items().unwrap();
        assert_eq!(all_items.len(), 2);

        let original_item = all_items
            .iter()
            .find(|item| item.item_id == "shared-item")
            .unwrap();
        assert_eq!(original_item.text_content(), "edited by A");

        let forked_item = all_items
            .iter()
            .find(|item| item.text_content() == "edited by B")
            .unwrap();
        assert_ne!(forked_item.item_id, "shared-item");

        let pending_events = store.pending_local_events().unwrap();
        assert_eq!(pending_events.len(), 1);
        assert_eq!(pending_events[0].item_id, forked_item.item_id);
        assert_eq!(pending_events[0].payload_type, "item_created");

        let sync = SyncStore::new(db.pool());
        let projection = sync
            .fetch_projection(&forked_item.item_id)
            .unwrap()
            .unwrap();
        match projection.state {
            ProjectionState::Materialized { versions } => {
                assert_eq!(versions.content, 1);
                assert_eq!(versions.existence, 1);
            }
            other => panic!("expected materialized fork projection, got {other:?}"),
        }
    }

    #[test]
    fn remote_snapshot_and_delete_in_same_batch_removes_local_row() {
        let (store, dir) = test_store();

        let snapshot = ItemSnapshot::compacted(
            "remote-snapshot-delete-batch".to_string(),
            0,
            "checkpoint-1".to_string(),
            live_aggregate(text_snapshot("create then delete"), default_versions()),
        );
        let deleted = ItemEvent::new_local(
            "remote-snapshot-delete-batch".to_string(),
            "device-A",
            ItemEventPayload::ItemDeleted {
                base_existence_version: 1,
            },
        );

        let outcome = store
            .apply_remote_batch(
                vec![purr::interface::SyncEventRecord {
                    event_id: deleted.event_id.clone(),
                    item_id: deleted.item_id.clone(),
                    origin_device_id: deleted.origin_device_id.clone(),
                    schema_version: deleted.schema_version,
                    recorded_at: deleted.recorded_at,
                    payload_type: deleted.payload_type(),
                    payload_data: deleted.payload_data(),
                }],
                vec![purr::interface::SyncSnapshotRecord {
                    item_id: snapshot.item_id.clone(),
                    snapshot_revision: snapshot.snapshot_revision,
                    schema_version: snapshot.schema_version,
                    covers_through_event: snapshot.covers_through_event.clone(),
                    aggregate_data: snapshot.aggregate_data(),
                }],
            )
            .unwrap();

        match outcome {
            purr::interface::SyncDownloadBatchOutcome::Applied {
                events_applied,
                snapshots_applied,
            } => {
                assert_eq!(events_applied, 1);
                assert_eq!(snapshots_applied, 1);
            }
            other => panic!("expected applied outcome, got {other:?}"),
        }

        let db = store_db(&dir);
        assert!(db.fetch_all_items().unwrap().is_empty());

        let sync = SyncStore::new(db.pool());
        let projection = sync
            .fetch_projection("remote-snapshot-delete-batch")
            .unwrap()
            .unwrap();
        assert_projection_tombstoned(&projection);
    }

    #[test]
    fn remote_delete_batch_removes_materialized_local_row() {
        let (store, dir) = test_store();

        let created = ItemEvent::new_local(
            "remote-delete-batch".to_string(),
            "device-A",
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("delete me remotely"),
            },
        );
        store
            .apply_remote_event(purr::interface::SyncEventRecord {
                event_id: created.event_id.clone(),
                item_id: created.item_id.clone(),
                origin_device_id: created.origin_device_id.clone(),
                schema_version: created.schema_version,
                recorded_at: created.recorded_at,
                payload_type: created.payload_type(),
                payload_data: created.payload_data(),
            })
            .unwrap();

        let deleted = ItemEvent::new_local(
            "remote-delete-batch".to_string(),
            "device-A",
            ItemEventPayload::ItemDeleted {
                base_existence_version: 1,
            },
        );
        let outcome = store
            .apply_remote_batch(
                vec![purr::interface::SyncEventRecord {
                    event_id: deleted.event_id.clone(),
                    item_id: deleted.item_id.clone(),
                    origin_device_id: deleted.origin_device_id.clone(),
                    schema_version: deleted.schema_version,
                    recorded_at: deleted.recorded_at,
                    payload_type: deleted.payload_type(),
                    payload_data: deleted.payload_data(),
                }],
                vec![],
            )
            .unwrap();

        match outcome {
            purr::interface::SyncDownloadBatchOutcome::Applied { events_applied, .. } => {
                assert_eq!(events_applied, 1);
            }
            other => panic!("expected applied outcome, got {other:?}"),
        }

        let db = store_db(&dir);
        assert!(db.fetch_all_items().unwrap().is_empty());

        let sync = SyncStore::new(db.pool());
        let projection = sync
            .fetch_projection("remote-delete-batch")
            .unwrap()
            .unwrap();
        assert_projection_tombstoned(&projection);
    }

    #[test]
    fn full_resync_with_tail_preserves_forked_conflict_items() {
        let (store, dir) = test_store();

        let checkpoint = ItemSnapshot::initial(
            "shared-item".to_string(),
            live_aggregate(text_snapshot("before edit"), default_versions()),
        );
        let first_edit = ItemEvent::new_local(
            "shared-item".to_string(),
            "device-A",
            ItemEventPayload::TextEdited {
                new_text: "edited by A".to_string(),
                base_content_version: 1,
            },
        );
        let conflicting_edit = ItemEvent::new_local(
            "shared-item".to_string(),
            "device-B",
            ItemEventPayload::TextEdited {
                new_text: "edited by B".to_string(),
                base_content_version: 1,
            },
        );

        let result = store
            .full_resync_with_tail(
                vec![purr::interface::SyncSnapshotRecord {
                    item_id: checkpoint.item_id.clone(),
                    snapshot_revision: checkpoint.snapshot_revision,
                    schema_version: checkpoint.schema_version,
                    covers_through_event: checkpoint.covers_through_event.clone(),
                    aggregate_data: checkpoint.aggregate_data(),
                }],
                vec![
                    purr::interface::SyncEventRecord {
                        event_id: first_edit.event_id.clone(),
                        item_id: first_edit.item_id.clone(),
                        origin_device_id: first_edit.origin_device_id.clone(),
                        schema_version: first_edit.schema_version,
                        recorded_at: first_edit.recorded_at,
                        payload_type: first_edit.payload_type(),
                        payload_data: first_edit.payload_data(),
                    },
                    purr::interface::SyncEventRecord {
                        event_id: conflicting_edit.event_id.clone(),
                        item_id: conflicting_edit.item_id.clone(),
                        origin_device_id: conflicting_edit.origin_device_id.clone(),
                        schema_version: conflicting_edit.schema_version,
                        recorded_at: conflicting_edit.recorded_at,
                        payload_type: conflicting_edit.payload_type(),
                        payload_data: conflicting_edit.payload_data(),
                    },
                ],
            )
            .unwrap();

        assert_eq!(result.checkpoints_applied, 1);
        assert_eq!(result.tail_events_applied, 2);
        assert_eq!(result.tail_events_forked, 1);

        let db = store_db(&dir);
        let all_items = db.fetch_all_items().unwrap();
        assert_eq!(all_items.len(), 2);
        assert!(all_items
            .iter()
            .any(|item| item.item_id == "shared-item" && item.text_content() == "edited by A"));
        let forked_item = all_items
            .iter()
            .find(|item| item.text_content() == "edited by B")
            .unwrap();
        assert_ne!(forked_item.item_id, "shared-item");

        let pending_events = store.pending_local_events().unwrap();
        assert_eq!(pending_events.len(), 1);
        assert_eq!(pending_events[0].item_id, forked_item.item_id);
        assert_eq!(pending_events[0].payload_type, "item_created");
    }

    #[test]
    fn serde_roundtrip_for_apply_result_types() {
        // Verify the new Serialize/Deserialize derives work.
        let delta = ProjectionDelta {
            new_aggregate: ItemAggregate::Live(LiveItemState {
                snapshot: text_snapshot("serde test"),
                versions: default_versions(),
            }),
            bumped_domains: vec![VersionDomain::Content, VersionDomain::Touch],
            read_model_dirty: true,
            index_dirty: false,
        };
        let json = serde_json::to_string(&delta).unwrap();
        let restored: ProjectionDelta = serde_json::from_str(&json).unwrap();
        assert_eq!(delta, restored);

        let fork = ForkPlan {
            forked_snapshot: text_snapshot("forked"),
            reason: "conflict".to_string(),
            forked_from: Some("original-item".to_string()),
        };
        let json = serde_json::to_string(&fork).unwrap();
        let restored: ForkPlan = serde_json::from_str(&json).unwrap();
        assert_eq!(fork, restored);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// FORWARD COMPATIBILITY TESTS
// ═══════════════════════════════════════════════════════════════════════════════

mod forward_compat_tests {
    use super::*;

    #[test]
    fn test_unknown_schema_version_ignored() {
        let db = test_db();

        // Create the item first so the event isn't deferred due to missing item.
        let create = ItemEvent::new_local(
            "item-fwd".to_string(),
            "device-A",
            ItemEventPayload::ItemCreated {
                snapshot: text_snapshot("forward compat test"),
            },
        );
        replay::apply_remote_event(db.pool(), &create).unwrap();

        // Construct an event with a future schema version.
        let future_event = ItemEvent {
            event_id: uuid::Uuid::new_v4().to_string(),
            item_id: "item-fwd".to_string(),
            origin_device_id: "device-future".to_string(),
            schema_version: 999,
            recorded_at: chrono::Utc::now().timestamp(),
            payload: ItemEventPayload::TextEdited {
                new_text: "from the future".to_string(),
                base_content_version: 1,
            },
        };

        let result = replay::apply_remote_event(db.pool(), &future_event).unwrap();
        match result {
            ApplyResult::Ignored(IgnoreReason::UnsupportedVersion {
                event_version,
                max_supported,
            }) => {
                assert_eq!(event_version, 999);
                assert_eq!(max_supported, SYNC_SCHEMA_VERSION);
            }
            other => panic!("Expected UnsupportedVersion, got {other:?}"),
        }

        // Verify it's been marked as applied (won't be re-processed).
        let sync = SyncStore::new(db.pool());
        assert!(sync.is_event_applied(&future_event.event_id).unwrap());
    }

    #[test]
    fn test_unknown_payload_type_ignored() {
        let db = test_db();

        // Use from_stored with a payload that can't be deserialized into any known variant.
        let event = ItemEvent::from_stored(
            uuid::Uuid::new_v4().to_string(),
            "item-unknown".to_string(),
            "device-future".to_string(),
            SYNC_SCHEMA_VERSION,
            chrono::Utc::now().timestamp(),
            "new_payload_type_v2",
            r#"{"some_field": "some_value"}"#,
        )
        .unwrap();

        // Verify it was parsed as Unknown.
        assert!(
            matches!(event.payload, ItemEventPayload::Unknown { .. }),
            "Expected Unknown payload, got {:?}",
            event.payload
        );

        let result = replay::apply_remote_event(db.pool(), &event).unwrap();
        match result {
            ApplyResult::Ignored(IgnoreReason::UnknownPayload { raw_type }) => {
                assert_eq!(raw_type, "new_payload_type_v2");
            }
            other => panic!("Expected UnknownPayload, got {other:?}"),
        }

        // Verify marked as applied.
        let sync = SyncStore::new(db.pool());
        assert!(sync.is_event_applied(&event.event_id).unwrap());
    }

    #[test]
    fn test_unknown_payload_projector_ignores() {
        let payload = ItemEventPayload::Unknown {
            raw_type: "future_event_type".to_string(),
            raw_data: "{}".to_string(),
        };

        let snapshot = text_snapshot("test");
        let agg = live_aggregate(snapshot, default_versions());
        let result = projector::apply_event(Some(&agg), &payload);

        assert!(
            matches!(
                result,
                ApplyResult::Ignored(IgnoreReason::UnknownPayload { .. })
            ),
            "Projector should ignore unknown payload, got {result:?}"
        );
    }

    #[test]
    fn test_from_stored_with_invalid_json_returns_unknown() {
        let event = ItemEvent::from_stored(
            "evt-1".to_string(),
            "item-1".to_string(),
            "device-1".to_string(),
            1,
            1000000,
            "text_edited",
            "this is not valid json at all",
        )
        .unwrap();

        match &event.payload {
            ItemEventPayload::Unknown { raw_type, raw_data } => {
                assert_eq!(raw_type, "text_edited");
                assert_eq!(raw_data, "this is not valid json at all");
            }
            other => panic!("Expected Unknown, got {other:?}"),
        }
    }
}
