//! Sync compactor — folds event tails into snapshots.
//!
//! Compaction triggers:
//! - More than 32 uncompacted events for one item
//! - More than 128 KB of uncompacted payload for one item
//! - Oldest uncompacted event older than 7 days
//! - Tombstone older than 30 days still accumulating stale events

use crate::error::SyncResult;
use crate::projector;
use crate::snapshot::ItemSnapshot;
use crate::store::SyncStore;
use crate::types::{
    ApplyResult, ItemAggregate, COMPACTED_EVENT_RETENTION_SECS, COMPACTION_AGE_THRESHOLD_SECS,
    COMPACTION_EVENT_THRESHOLD, COMPACTION_PAYLOAD_THRESHOLD, TOMBSTONE_COMPACTION_AGE_SECS,
    TOMBSTONE_SNAPSHOT_RETENTION_SECS,
};
use chrono::Utc;
use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;

/// Result of a compaction attempt on a single item.
#[derive(Debug, PartialEq, Eq)]
pub enum CompactionOutcome {
    /// A new snapshot was produced.
    Compacted {
        snapshot: ItemSnapshot,
        events_compacted: usize,
    },
    /// No compaction was needed.
    NotNeeded,
    /// No events exist for this item.
    NoEvents,
}

/// Check whether an item needs compaction.
pub fn needs_compaction(sync: &SyncStore<'_>, global_item_id: &str) -> SyncResult<bool> {
    let count = sync.count_uncompacted_events(global_item_id)?;
    if count == 0 {
        return Ok(false);
    }
    if count >= COMPACTION_EVENT_THRESHOLD {
        return Ok(true);
    }

    let payload_size = sync.uncompacted_payload_size(global_item_id)?;
    if payload_size >= COMPACTION_PAYLOAD_THRESHOLD {
        return Ok(true);
    }

    let now = Utc::now().timestamp();
    if let Some(oldest) = sync.oldest_uncompacted_event_time(global_item_id)? {
        if now - oldest >= COMPACTION_AGE_THRESHOLD_SECS {
            return Ok(true);
        }
    }

    // Check tombstone compaction trigger.
    if let Some(snapshot) = sync.fetch_snapshot(global_item_id)? {
        if let ItemAggregate::Tombstoned(ref tomb) = snapshot.aggregate {
            if now - tomb.deleted_at_unix >= TOMBSTONE_COMPACTION_AGE_SECS && count > 0 {
                return Ok(true);
            }
        }
    }

    Ok(false)
}

/// Run compaction for a single item.
pub fn compact_item(pool: &Pool<SqliteConnectionManager>, global_item_id: &str) -> SyncResult<CompactionOutcome> {
    let sync = SyncStore::new(pool);
    let events = sync.fetch_uncompacted_events(global_item_id)?;
    if events.is_empty() {
        return Ok(CompactionOutcome::NoEvents);
    }

    // Start from existing snapshot or None.
    let existing_snapshot = sync.fetch_snapshot(global_item_id)?;
    let mut aggregate = existing_snapshot.as_ref().map(|s| s.aggregate.clone());

    let mut applied_event_ids = Vec::new();
    for event in &events {
        let current_ref = aggregate.as_ref();
        match projector::apply_event(current_ref, &event.payload) {
            ApplyResult::Applied(delta) => {
                aggregate = Some(delta.new_aggregate);
                applied_event_ids.push(event.event_id.as_str());
            }
            ApplyResult::Ignored(_) => {
                // Stale/duplicate — still mark as compacted.
                applied_event_ids.push(event.event_id.as_str());
            }
            ApplyResult::Deferred(_) | ApplyResult::Forked(_) => {
                // Skip — these can't be folded into the snapshot cleanly.
            }
        }
    }

    if applied_event_ids.is_empty() {
        return Ok(CompactionOutcome::NotNeeded);
    }

    let Some(final_aggregate) = aggregate else {
        return Ok(CompactionOutcome::NotNeeded);
    };

    let previous_revision = existing_snapshot
        .as_ref()
        .map(|s| s.snapshot_revision)
        .unwrap_or(0);

    let last_event_id = applied_event_ids
        .last()
        .expect("non-empty applied events")
        .to_string();

    let snapshot = ItemSnapshot::compacted(
        global_item_id.to_string(),
        previous_revision,
        last_event_id,
        final_aggregate,
    );

    sync.upsert_snapshot(&snapshot)?;
    sync.mark_events_compacted(&applied_event_ids)?;

    Ok(CompactionOutcome::Compacted {
        snapshot,
        events_compacted: applied_event_ids.len(),
    })
}

/// Run compaction across all items that need it.
pub fn compact_all(pool: &Pool<SqliteConnectionManager>) -> SyncResult<usize> {
    let sync = SyncStore::new(pool);
    let item_ids = sync.items_with_uncompacted_events()?;
    let mut compacted_count = 0;

    for gid in &item_ids {
        if needs_compaction(&sync, gid)? {
            match compact_item(pool, gid)? {
                CompactionOutcome::Compacted { .. } => compacted_count += 1,
                _ => {}
            }
        }
    }

    Ok(compacted_count)
}

/// Delete compacted events that have exceeded retention AND are covered by
/// an uploaded checkpoint. Events are only safe to delete when a checkpoint
/// that covers them has been replicated to CloudKit, ensuring lagging devices
/// can still recover via full resync.
pub fn purge_retained_events(pool: &Pool<SqliteConnectionManager>) -> SyncResult<usize> {
    let sync = SyncStore::new(pool);
    let threshold = Utc::now().timestamp() - COMPACTED_EVENT_RETENTION_SECS;
    let purgeable_ids = sync.fetch_checkpoint_safe_purgeable_events(threshold)?;
    if purgeable_ids.is_empty() {
        return Ok(0);
    }
    let refs: Vec<&str> = purgeable_ids.iter().map(|s| s.as_str()).collect();
    sync.delete_events_by_ids(&refs)
}

/// Delete tombstone snapshots that have exceeded retention.
pub fn purge_tombstone_snapshots(pool: &Pool<SqliteConnectionManager>) -> SyncResult<usize> {
    let sync = SyncStore::new(pool);
    let threshold = Utc::now().timestamp() - TOMBSTONE_SNAPSHOT_RETENTION_SECS;
    let all_snapshots = sync.fetch_all_snapshots()?;
    let mut purged = 0;

    for snapshot in &all_snapshots {
        if let ItemAggregate::Tombstoned(ref tomb) = snapshot.aggregate {
            if tomb.deleted_at_unix < threshold {
                sync.delete_snapshot(&snapshot.global_item_id)?;
                purged += 1;
            }
        }
    }

    Ok(purged)
}
