//! Sync replay — applies remote events/snapshots to local state.
//!
//! Download path:
//! 1. Apply newer snapshots before tail events.
//! 2. Apply events in any order using base-version checks.
//! 3. Defer events that can't apply yet.
//! 4. Retry deferred events after each batch.
//! 5. Mark needs_full_resync if unresolved gaps past threshold.

use crate::database::Database;
use crate::database::DatabaseResult;
use crate::sync::event::ItemEvent;
use crate::sync::projector;
use crate::sync::snapshot::ItemSnapshot;
use crate::sync::store::SyncStore;
use crate::sync::types::*;

/// Maximum deferred event retries before marking full resync needed.
const MAX_DEFERRED_RETRY_ROUNDS: usize = 3;

/// Result of applying a batch of remote changes.
#[derive(Debug, Default)]
pub struct BatchApplyResult {
    pub events_applied: usize,
    pub events_ignored: usize,
    pub events_deferred: usize,
    pub events_forked: usize,
    pub snapshots_applied: usize,
    pub needs_full_resync: bool,
    /// Global item IDs of items that were forked (caller should create new items).
    pub fork_plans: Vec<(String, ForkPlan)>,
}

/// Apply a batch of remote snapshots. Snapshots should be applied before events.
pub fn apply_remote_snapshots(
    db: &Database,
    snapshots: &[ItemSnapshot],
) -> DatabaseResult<usize> {
    let sync = SyncStore::new(db);
    let mut applied = 0;

    for snapshot in snapshots {
        let existing = sync.fetch_snapshot(&snapshot.global_item_id)?;
        let should_apply = match &existing {
            None => true,
            Some(existing) => snapshot.snapshot_revision > existing.snapshot_revision,
        };

        if should_apply {
            sync.upsert_snapshot(snapshot)?;

            // Update projection from snapshot aggregate.
            let (versions, is_tombstoned) = match &snapshot.aggregate {
                ItemAggregate::Live(live) => (live.versions, false),
                ItemAggregate::Tombstoned(tomb) => (tomb.versions, true),
            };

            let existing_proj = sync.fetch_projection(&snapshot.global_item_id)?;
            let local_id = existing_proj.and_then(|p| p.local_item_id);

            sync.upsert_projection(
                &snapshot.global_item_id,
                local_id,
                &versions,
                is_tombstoned,
            )?;

            applied += 1;
        }
    }

    Ok(applied)
}

/// Apply a single remote event.
/// Returns the apply result for the caller to act on.
pub fn apply_remote_event(
    db: &Database,
    event: &ItemEvent,
) -> DatabaseResult<ApplyResult> {
    let sync = SyncStore::new(db);

    // Dedup check.
    if sync.is_event_applied(&event.event_id)? {
        return Ok(ApplyResult::Ignored(IgnoreReason::AlreadyApplied));
    }

    // Load current aggregate from projection + snapshot.
    let aggregate = load_aggregate(&sync, &event.global_item_id)?;

    let result = projector::apply_event(aggregate.as_ref(), &event.payload);

    match &result {
        ApplyResult::Applied(delta) => {
            // Persist the event.
            sync.append_remote_event(event)?;
            sync.mark_event_applied(&event.event_id)?;

            // Update snapshot with new aggregate so subsequent loads see current state.
            let existing_snap = sync.fetch_snapshot(&event.global_item_id)?;
            let prev_rev = existing_snap.map(|s| s.snapshot_revision).unwrap_or(0);
            let updated_snap = ItemSnapshot::compacted(
                event.global_item_id.clone(),
                prev_rev,
                event.event_id.clone(),
                delta.new_aggregate.clone(),
            );
            sync.upsert_snapshot(&updated_snap)?;

            // Update projection.
            let (versions, is_tombstoned) = match &delta.new_aggregate {
                ItemAggregate::Live(live) => (live.versions, false),
                ItemAggregate::Tombstoned(tomb) => (tomb.versions, true),
            };

            let existing_proj = sync.fetch_projection(&event.global_item_id)?;
            let local_id = existing_proj.and_then(|p| p.local_item_id);

            sync.upsert_projection(
                &event.global_item_id,
                local_id,
                &versions,
                is_tombstoned,
            )?;
        }
        ApplyResult::Ignored(_) => {
            // Mark as applied so we don't re-process.
            sync.mark_event_applied(&event.event_id)?;
        }
        ApplyResult::Deferred(reason) => {
            sync.defer_event(event, reason)?;
        }
        ApplyResult::Forked(_) => {
            // Mark original event as applied.
            sync.append_remote_event(event)?;
            sync.mark_event_applied(&event.event_id)?;
            // Caller handles creating the forked item.
        }
    }

    Ok(result)
}

/// Apply a batch of remote events and retry deferred events.
pub fn apply_remote_event_batch(
    db: &Database,
    events: &[ItemEvent],
) -> DatabaseResult<BatchApplyResult> {
    let mut result = BatchApplyResult::default();

    // Apply all new events.
    for event in events {
        match apply_remote_event(db, event)? {
            ApplyResult::Applied(_) => result.events_applied += 1,
            ApplyResult::Ignored(_) => result.events_ignored += 1,
            ApplyResult::Deferred(_) => result.events_deferred += 1,
            ApplyResult::Forked(plan) => {
                result.events_forked += 1;
                result
                    .fork_plans
                    .push((event.global_item_id.clone(), plan));
            }
        }
    }

    // Retry deferred events.
    retry_deferred_events(db, &mut result)?;

    Ok(result)
}

/// Retry deferred events, up to MAX_DEFERRED_RETRY_ROUNDS.
fn retry_deferred_events(
    db: &Database,
    result: &mut BatchApplyResult,
) -> DatabaseResult<()> {
    let sync = SyncStore::new(db);

    for _round in 0..MAX_DEFERRED_RETRY_ROUNDS {
        let deferred = sync.fetch_all_deferred_events()?;
        if deferred.is_empty() {
            return Ok(());
        }

        let mut progress = false;
        for event in &deferred {
            let aggregate = load_aggregate(&sync, &event.global_item_id)?;
            let apply_result = projector::apply_event(aggregate.as_ref(), &event.payload);

            match apply_result {
                ApplyResult::Applied(delta) => {
                    sync.remove_deferred_event(&event.event_id)?;
                    sync.append_remote_event(event)?;
                    sync.mark_event_applied(&event.event_id)?;

                    // Update snapshot with new aggregate.
                    let existing_snap = sync.fetch_snapshot(&event.global_item_id)?;
                    let prev_rev = existing_snap.map(|s| s.snapshot_revision).unwrap_or(0);
                    let updated_snap = ItemSnapshot::compacted(
                        event.global_item_id.clone(),
                        prev_rev,
                        event.event_id.clone(),
                        delta.new_aggregate.clone(),
                    );
                    sync.upsert_snapshot(&updated_snap)?;

                    let (versions, is_tombstoned) = match &delta.new_aggregate {
                        ItemAggregate::Live(live) => (live.versions, false),
                        ItemAggregate::Tombstoned(tomb) => (tomb.versions, true),
                    };
                    let existing_proj = sync.fetch_projection(&event.global_item_id)?;
                    let local_id = existing_proj.and_then(|p| p.local_item_id);
                    sync.upsert_projection(
                        &event.global_item_id,
                        local_id,
                        &versions,
                        is_tombstoned,
                    )?;

                    result.events_applied += 1;
                    result.events_deferred = result.events_deferred.saturating_sub(1);
                    progress = true;
                }
                ApplyResult::Ignored(_) => {
                    sync.remove_deferred_event(&event.event_id)?;
                    sync.mark_event_applied(&event.event_id)?;
                    result.events_ignored += 1;
                    result.events_deferred = result.events_deferred.saturating_sub(1);
                    progress = true;
                }
                ApplyResult::Forked(plan) => {
                    sync.remove_deferred_event(&event.event_id)?;
                    sync.append_remote_event(event)?;
                    sync.mark_event_applied(&event.event_id)?;
                    result.events_forked += 1;
                    result.events_deferred = result.events_deferred.saturating_sub(1);
                    result
                        .fork_plans
                        .push((event.global_item_id.clone(), plan));
                    progress = true;
                }
                ApplyResult::Deferred(_) => {
                    // Still deferred — leave in place.
                }
            }
        }

        if !progress {
            break;
        }
    }

    // If deferred events remain, flag for full resync.
    if sync.count_deferred_events()? > 0 {
        result.needs_full_resync = true;
        sync.set_dirty_flag(FLAG_NEEDS_FULL_RESYNC, true)?;
    }

    Ok(())
}

/// Full resync: clear local sync state and rebuild from snapshots.
///
/// 1. Clear sync log, deferred events, dedup, and projection.
/// 2. Rebuild projection from the provided snapshots.
///
/// The caller is responsible for:
/// - Fetching all current ItemSnapshot records from CloudKit.
/// - Rebuilding the local SQLite read model from snapshot data.
/// - Rebuilding the Tantivy index.
/// - Storing a fresh zone token and resuming incremental sync.
pub fn full_resync_from_snapshots(
    db: &Database,
    snapshots: &[ItemSnapshot],
) -> DatabaseResult<usize> {
    let sync = SyncStore::new(db);

    // Clear all sync state.
    sync.clear_sync_state()?;

    // Rebuild from snapshots.
    let mut applied = 0;
    for snapshot in snapshots {
        sync.upsert_snapshot(snapshot)?;

        let (versions, is_tombstoned) = match &snapshot.aggregate {
            ItemAggregate::Live(live) => (live.versions, false),
            ItemAggregate::Tombstoned(tomb) => (tomb.versions, true),
        };

        // local_item_id is None — the caller will rebuild the read model
        // and set local IDs via upsert_projection.
        sync.upsert_projection(
            &snapshot.global_item_id,
            None,
            &versions,
            is_tombstoned,
        )?;

        applied += 1;
    }

    // Clear the full resync flag.
    sync.set_dirty_flag(FLAG_NEEDS_FULL_RESYNC, false)?;

    Ok(applied)
}

/// Load the current aggregate for an item from the projection and snapshot.
fn load_aggregate(
    sync: &SyncStore<'_>,
    global_item_id: &str,
) -> DatabaseResult<Option<ItemAggregate>> {
    // First check projection for version info.
    let projection = sync.fetch_projection(global_item_id)?;
    if projection.is_none() {
        // No projection entry — check if there's a snapshot.
        let snapshot = sync.fetch_snapshot(global_item_id)?;
        return Ok(snapshot.map(|s| s.aggregate));
    }

    // Projection exists — use snapshot as authoritative aggregate.
    let snapshot = sync.fetch_snapshot(global_item_id)?;
    Ok(snapshot.map(|s| s.aggregate))
}
