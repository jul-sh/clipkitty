//! Multi-device integration tests for the sync system.
//!
//! Simulates two devices with independent sync stores sharing events
//! through manual event passing (no CloudKit involved).

use purr_sync::event::ItemEvent;
use purr_sync::replay;
use purr_sync::store::SyncStore;
use purr_sync::types::{
    ApplyResult, DeferredReason, IgnoreReason, ItemEventPayload, ItemSnapshotData,
    TypeSpecificData,
};

use purr::database::Database;
use purr::ClipboardStore;
use purr::ClipboardStoreApi;
use tempfile::TempDir;

// ═══════════════════════════════════════════════════════════════════════════════
// Test helpers
// ═══════════════════════════════════════════════════════════════════════════════

struct TestDevice {
    store: ClipboardStore,
    _dir: TempDir,
    db: Database,
}

impl TestDevice {
    fn new() -> Self {
        let dir = TempDir::new().unwrap();
        let db_path = dir.path().join("test.db").to_string_lossy().to_string();
        let store = ClipboardStore::new(db_path.clone()).unwrap();
        let db = Database::open(&db_path).unwrap();
        Self {
            store,
            _dir: dir,
            db,
        }
    }

    fn sync_store(&self) -> SyncStore<'_> {
        SyncStore::new(self.db.pool())
    }

    /// Get pending local events for "upload".
    fn pending_events(&self) -> Vec<ItemEvent> {
        self.sync_store().fetch_pending_upload_events().unwrap()
    }

    /// Mark events as uploaded.
    fn mark_uploaded(&self, events: &[ItemEvent]) {
        let ids: Vec<&str> = events.iter().map(|e| e.event_id.as_str()).collect();
        self.sync_store().mark_events_uploaded(&ids).unwrap();
    }

    /// Apply remote events from another device.
    fn apply_remote_events(&self, events: &[ItemEvent]) -> Vec<ApplyResult> {
        events
            .iter()
            .map(|e| replay::apply_remote_event(self.db.pool(), e).unwrap())
            .collect()
    }
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

// ═══════════════════════════════════════════════════════════════════════════════
// Multi-device tests
// ═══════════════════════════════════════════════════════════════════════════════

#[test]
fn test_two_devices_create_and_sync() {
    let device_a = TestDevice::new();
    let device_b = TestDevice::new();

    // Device A creates an item.
    device_a
        .store
        .save_text("hello from A".into(), None, None)
        .unwrap();

    // Device A has pending events.
    let events_a = device_a.pending_events();
    assert_eq!(events_a.len(), 1);
    assert!(matches!(
        events_a[0].payload,
        ItemEventPayload::ItemCreated { .. }
    ));

    // "Upload" from A.
    device_a.mark_uploaded(&events_a);

    // Device B receives and applies the event.
    let results = device_b.apply_remote_events(&events_a);
    assert_eq!(results.len(), 1);
    assert!(matches!(results[0], ApplyResult::Applied(_)));

    // Verify Device B's projection has the item.
    let sync_b = device_b.sync_store();
    let proj = sync_b
        .fetch_projection(&events_a[0].global_item_id)
        .unwrap();
    assert!(proj.is_some());
    let proj = proj.unwrap();
    assert!(!proj.is_tombstoned);
    assert_eq!(proj.versions.existence, 1);
}

#[test]
fn test_concurrent_edit_conflict_forks() {
    let device_a = TestDevice::new();
    let device_b = TestDevice::new();

    // Both devices start with the same item (simulate via ItemCreated event).
    let create_event = ItemEvent::new_local(
        "shared-item-1".to_string(),
        "device-a",
        ItemEventPayload::ItemCreated {
            snapshot: text_snapshot("original text"),
        },
    );

    // Apply the create event on both devices.
    let result_a = replay::apply_remote_event(device_a.db.pool(), &create_event).unwrap();
    assert!(matches!(result_a, ApplyResult::Applied(_)));
    let result_b = replay::apply_remote_event(device_b.db.pool(), &create_event).unwrap();
    assert!(matches!(result_b, ApplyResult::Applied(_)));

    // Device A edits the text (base version = 1).
    let edit_a = ItemEvent::new_local(
        "shared-item-1".to_string(),
        "device-a",
        ItemEventPayload::TextEdited {
            new_text: "edited by A".to_string(),
            base_content_version: 1,
        },
    );

    // Device B also edits the text (same base version = 1, concurrent edit).
    let edit_b = ItemEvent::new_local(
        "shared-item-1".to_string(),
        "device-b",
        ItemEventPayload::TextEdited {
            new_text: "edited by B".to_string(),
            base_content_version: 1,
        },
    );

    // A applies its own edit first.
    let result_a = replay::apply_remote_event(device_a.db.pool(), &edit_a).unwrap();
    assert!(matches!(result_a, ApplyResult::Applied(_)));

    // A then receives B's concurrent edit — should fork (stale base version).
    let result_ab = replay::apply_remote_event(device_a.db.pool(), &edit_b).unwrap();
    assert!(
        matches!(result_ab, ApplyResult::Forked(_)),
        "Expected fork for concurrent edit conflict, got {result_ab:?}"
    );
}

#[test]
fn test_offline_reconnect_batch() {
    let device_a = TestDevice::new();
    let device_b = TestDevice::new();

    // Device A creates multiple items while B is "offline".
    device_a
        .store
        .save_text("item 1".into(), None, None)
        .unwrap();
    device_a
        .store
        .save_text("item 2".into(), None, None)
        .unwrap();
    device_a
        .store
        .save_text("item 3".into(), None, None)
        .unwrap();

    let events = device_a.pending_events();
    assert_eq!(events.len(), 3);
    device_a.mark_uploaded(&events);

    // B comes back online and receives all events as a batch.
    let batch_result = replay::apply_remote_event_batch(device_b.db.pool(), &events).unwrap();
    assert_eq!(batch_result.events_applied, 3);
    assert_eq!(batch_result.events_ignored, 0);
    assert_eq!(batch_result.events_deferred, 0);
    assert!(!batch_result.needs_full_resync);
}

#[test]
fn test_out_of_order_events_deferred_then_resolved() {
    let device_a = TestDevice::new();
    let device_b = TestDevice::new();

    // Create an item on device A.
    let create_event = ItemEvent::new_local(
        "item-ooo".to_string(),
        "device-a",
        ItemEventPayload::ItemCreated {
            snapshot: text_snapshot("original"),
        },
    );

    // Apply create on A.
    replay::apply_remote_event(device_a.db.pool(), &create_event).unwrap();

    // A edits the item.
    let edit_event = ItemEvent::new_local(
        "item-ooo".to_string(),
        "device-a",
        ItemEventPayload::TextEdited {
            new_text: "edited".to_string(),
            base_content_version: 1,
        },
    );

    // Device B receives the edit BEFORE the create (out of order).
    let result = replay::apply_remote_event(device_b.db.pool(), &edit_event).unwrap();
    assert!(
        matches!(result, ApplyResult::Deferred(DeferredReason::MissingItem)),
        "Expected Deferred(MissingItem), got {result:?}"
    );

    // Now B receives the create event. The batch apply should retry deferred.
    let batch = replay::apply_remote_event_batch(device_b.db.pool(), &[create_event]).unwrap();
    assert_eq!(batch.events_applied, 2); // 1 create + 1 deferred edit resolved
    assert_eq!(batch.events_deferred, 0);
}

#[test]
fn test_delete_on_one_device_tombstones_on_other() {
    let device_a = TestDevice::new();
    let device_b = TestDevice::new();

    // Shared item created on both devices.
    let create_event = ItemEvent::new_local(
        "item-del".to_string(),
        "device-a",
        ItemEventPayload::ItemCreated {
            snapshot: text_snapshot("will be deleted"),
        },
    );
    replay::apply_remote_event(device_a.db.pool(), &create_event).unwrap();
    replay::apply_remote_event(device_b.db.pool(), &create_event).unwrap();

    // Device A deletes the item.
    let delete_event = ItemEvent::new_local(
        "item-del".to_string(),
        "device-a",
        ItemEventPayload::ItemDeleted {
            base_existence_version: 1,
        },
    );
    replay::apply_remote_event(device_a.db.pool(), &delete_event).unwrap();

    // Device B receives the delete.
    let result = replay::apply_remote_event(device_b.db.pool(), &delete_event).unwrap();
    assert!(matches!(result, ApplyResult::Applied(_)));

    // Verify tombstone on B.
    let sync_b = device_b.sync_store();
    let proj = sync_b.fetch_projection("item-del").unwrap().unwrap();
    assert!(proj.is_tombstoned);
}

#[test]
fn test_bookmark_and_edit_apply_independently() {
    let device_a = TestDevice::new();
    let device_b = TestDevice::new();

    // Shared item.
    let create_event = ItemEvent::new_local(
        "item-indep".to_string(),
        "device-a",
        ItemEventPayload::ItemCreated {
            snapshot: text_snapshot("independent domains"),
        },
    );
    replay::apply_remote_event(device_a.db.pool(), &create_event).unwrap();
    replay::apply_remote_event(device_b.db.pool(), &create_event).unwrap();

    // A bookmarks, B edits — different domains, no conflict.
    let bookmark_event = ItemEvent::new_local(
        "item-indep".to_string(),
        "device-a",
        ItemEventPayload::BookmarkSet {
            base_bookmark_version: 0,
        },
    );
    let edit_event = ItemEvent::new_local(
        "item-indep".to_string(),
        "device-b",
        ItemEventPayload::TextEdited {
            new_text: "edited independently".to_string(),
            base_content_version: 1,
        },
    );

    // Apply both on device A (both should succeed since they're different domains).
    let r1 = replay::apply_remote_event(device_a.db.pool(), &bookmark_event).unwrap();
    assert!(matches!(r1, ApplyResult::Applied(_)));
    let r2 = replay::apply_remote_event(device_a.db.pool(), &edit_event).unwrap();
    assert!(matches!(r2, ApplyResult::Applied(_)));

    // Verify both changes applied.
    let sync_a = device_a.sync_store();
    let proj = sync_a.fetch_projection("item-indep").unwrap().unwrap();
    assert_eq!(proj.versions.bookmark, 1); // bookmark bumped
    assert_eq!(proj.versions.content, 2); // content bumped
}

#[test]
fn test_duplicate_event_across_devices() {
    let device_a = TestDevice::new();
    let device_b = TestDevice::new();

    let create_event = ItemEvent::new_local(
        "item-dup".to_string(),
        "device-a",
        ItemEventPayload::ItemCreated {
            snapshot: text_snapshot("dedup test"),
        },
    );

    // Apply on both.
    replay::apply_remote_event(device_a.db.pool(), &create_event).unwrap();
    replay::apply_remote_event(device_b.db.pool(), &create_event).unwrap();

    // Apply the same event again on B (duplicate delivery).
    let result = replay::apply_remote_event(device_b.db.pool(), &create_event).unwrap();
    assert!(
        matches!(result, ApplyResult::Ignored(IgnoreReason::AlreadyApplied)),
        "Duplicate should be ignored, got {result:?}"
    );
}
