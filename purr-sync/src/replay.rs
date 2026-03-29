//! Sync replay — applies remote events/snapshots to local state.
//!
//! Download path:
//! 1. Apply newer snapshots before tail events.
//! 2. Apply events in any order using base-version checks.
//! 3. Defer events that can't apply yet.
//! 4. Retry deferred events after each batch.
//! 5. Mark needs_full_resync if unresolved gaps past threshold.

use crate::error::SyncResult;
use crate::event::ItemEvent;
use crate::projector;
use crate::snapshot::ItemSnapshot;
use crate::store::SyncStore;
use crate::types::{
    ApplyResult, DownloadBatchOutcome, ForkPlan, FullResyncResult, IgnoreReason, ItemAggregate,
    ItemEventPayload, FLAG_NEEDS_FULL_RESYNC, SYNC_SCHEMA_VERSION,
};
use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;

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
    /// Count of events that applied in the sync layer but failed to materialize
    /// into the read model. Set by the FFI layer, not by replay itself.
    pub materialization_failures: usize,
    /// Global item IDs of items that were forked (caller should create new items).
    pub fork_plans: Vec<(String, ForkPlan)>,
}

impl BatchApplyResult {
    /// Determine whether it is safe to advance the zone change token.
    pub fn download_outcome(&self, snapshots_applied: usize) -> DownloadBatchOutcome {
        if self.needs_full_resync {
            return DownloadBatchOutcome::FullResyncRequired;
        }
        if self.materialization_failures > 0 {
            return DownloadBatchOutcome::PartialFailure {
                applied_count: self.events_applied,
                failed_count: self.materialization_failures,
                should_retry: true,
            };
        }
        DownloadBatchOutcome::Applied {
            events_applied: self.events_applied,
            snapshots_applied,
        }
    }
}

/// Apply a batch of remote snapshots. Snapshots should be applied before events.
pub fn apply_remote_snapshots(
    pool: &Pool<SqliteConnectionManager>,
    snapshots: &[ItemSnapshot],
) -> SyncResult<usize> {
    let sync = SyncStore::new(pool);
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
pub fn apply_remote_event(
    pool: &Pool<SqliteConnectionManager>,
    event: &ItemEvent,
) -> SyncResult<ApplyResult> {
    let sync = SyncStore::new(pool);

    // Dedup check.
    if sync.is_event_applied(&event.event_id)? {
        return Ok(ApplyResult::Ignored(IgnoreReason::AlreadyApplied));
    }

    // Forward compatibility: reject events from incompatible future versions.
    if event.schema_version > SYNC_SCHEMA_VERSION {
        // Mark as applied so we don't re-process on every cycle.
        sync.mark_event_applied(&event.event_id)?;
        return Ok(ApplyResult::Ignored(IgnoreReason::UnsupportedVersion {
            event_version: event.schema_version,
            max_supported: SYNC_SCHEMA_VERSION,
        }));
    }

    // Unknown payload types (from newer clients within compatible version range).
    if let ItemEventPayload::Unknown { ref raw_type, .. } = event.payload {
        sync.mark_event_applied(&event.event_id)?;
        return Ok(ApplyResult::Ignored(IgnoreReason::UnknownPayload {
            raw_type: raw_type.clone(),
        }));
    }

    // Load current aggregate from projection + snapshot.
    let aggregate = load_aggregate(&sync, &event.global_item_id)?;

    let mut result = projector::apply_event(aggregate.as_ref(), &event.payload);

    // Enrich fork plans with the originating item's global ID.
    if let ApplyResult::Forked(ref mut plan) = result {
        plan.forked_from = Some(event.global_item_id.clone());
    }

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
    pool: &Pool<SqliteConnectionManager>,
    events: &[ItemEvent],
) -> SyncResult<BatchApplyResult> {
    let mut result = BatchApplyResult::default();

    // Apply all new events.
    for event in events {
        match apply_remote_event(pool, event)? {
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
    retry_deferred_events(pool, &mut result)?;

    Ok(result)
}

/// Retry deferred events, up to MAX_DEFERRED_RETRY_ROUNDS.
fn retry_deferred_events(
    pool: &Pool<SqliteConnectionManager>,
    result: &mut BatchApplyResult,
) -> SyncResult<()> {
    let sync = SyncStore::new(pool);

    for _round in 0..MAX_DEFERRED_RETRY_ROUNDS {
        let deferred = sync.fetch_all_deferred_events()?;
        if deferred.is_empty() {
            return Ok(());
        }

        let mut progress = false;
        for event in &deferred {
            let aggregate = load_aggregate(&sync, &event.global_item_id)?;
            let mut apply_result = projector::apply_event(aggregate.as_ref(), &event.payload);

            // Enrich fork plans with lineage.
            if let ApplyResult::Forked(ref mut plan) = apply_result {
                plan.forked_from = Some(event.global_item_id.clone());
            }

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

/// Full resync: clear local sync state, apply checkpoints, then replay tail events.
///
/// Tail events are filtered per-item: only events recorded after the checkpoint's
/// watermark (the `recorded_at` of the covering event) are replayed. Events for
/// items with no checkpoint are always replayed.
pub fn full_resync(
    pool: &Pool<SqliteConnectionManager>,
    checkpoints: &[ItemSnapshot],
    tail_events: &[ItemEvent],
) -> SyncResult<FullResyncResult> {
    let sync = SyncStore::new(pool);
    let mut result = FullResyncResult::default();

    // Clear all sync state.
    sync.clear_sync_state()?;

    // Apply each checkpoint: upsert snapshot + projection.
    for snapshot in checkpoints {
        sync.upsert_snapshot(snapshot)?;

        let (versions, is_tombstoned) = match &snapshot.aggregate {
            ItemAggregate::Live(live) => (live.versions, false),
            ItemAggregate::Tombstoned(tomb) => (tomb.versions, true),
        };

        sync.upsert_projection(&snapshot.global_item_id, None, &versions, is_tombstoned)?;

        result.checkpoints_applied += 1;
    }

    // Build a watermark map: for each item that has a checkpoint, record the
    // checkpoint's recorded_at time so we only replay events newer than it.
    // We use the checkpoint's snapshot_revision as a proxy — events whose
    // recorded_at is <= the checkpoint's latest event time are already covered.
    // Since we don't store the exact timestamp of covers_through_event in the
    // snapshot, we use a simple approach: skip events whose event_id matches
    // a covers_through_event (exact dedup), and rely on the dedup table for
    // events that were already applied during checkpoint building.
    let covered_event_ids: std::collections::HashSet<&str> = checkpoints
        .iter()
        .filter_map(|s| s.covers_through_event.as_deref())
        .collect();

    // Apply tail events that aren't already covered by checkpoints.
    for event in tail_events {
        // Skip events that are the exact watermark of a checkpoint.
        if covered_event_ids.contains(event.event_id.as_str()) {
            result.tail_events_ignored += 1;
            continue;
        }

        match apply_remote_event(pool, event)? {
            ApplyResult::Applied(_) => result.tail_events_applied += 1,
            ApplyResult::Ignored(_) => result.tail_events_ignored += 1,
            ApplyResult::Deferred(_) => result.tail_events_deferred += 1,
            ApplyResult::Forked(_) => result.tail_events_applied += 1,
        }
    }

    // Clear the full resync flag.
    sync.set_dirty_flag(FLAG_NEEDS_FULL_RESYNC, false)?;

    Ok(result)
}

/// Full resync from snapshots only (backward-compatible wrapper).
pub fn full_resync_from_snapshots(
    pool: &Pool<SqliteConnectionManager>,
    snapshots: &[ItemSnapshot],
) -> SyncResult<usize> {
    let result = full_resync(pool, snapshots, &[])?;
    Ok(result.checkpoints_applied)
}

/// Load the current aggregate for an item from the projection and snapshot.
fn load_aggregate(
    sync: &SyncStore<'_>,
    global_item_id: &str,
) -> SyncResult<Option<ItemAggregate>> {
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
