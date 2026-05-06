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
use crate::store::{ProjectionEntry, ProjectionState, SyncStore};
use crate::types::{
    ApplyResult, DownloadBatchOutcome, ForkPlan, FullResyncResult, IgnoreReason, ItemAggregate,
    ItemEventPayload, FLAG_NEEDS_FULL_RESYNC, SYNC_SCHEMA_VERSION,
};
use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;
use std::collections::{BTreeMap, HashMap};

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
        let existing = sync.fetch_snapshot(&snapshot.item_id)?;
        let should_apply = match &existing {
            None => true,
            Some(existing) => snapshot.snapshot_revision > existing.snapshot_revision,
        };

        if should_apply {
            sync.upsert_snapshot(snapshot)?;

            // Update projection from snapshot aggregate.
            let projection_state = projection_state_for_aggregate(
                sync.fetch_projection(&snapshot.item_id)?,
                &snapshot.aggregate,
            );

            sync.upsert_projection(&snapshot.item_id, &projection_state)?;

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
    let aggregate = load_aggregate(&sync, &event.item_id)?;

    let mut result = projector::apply_event(aggregate.as_ref(), &event.payload);

    // Enrich fork plans with the originating item's global ID.
    if let ApplyResult::Forked(ref mut plan) = result {
        plan.forked_from = Some(event.item_id.clone());
    }

    match &result {
        ApplyResult::Applied(delta) => {
            // Persist the event.
            sync.append_remote_event(event)?;
            sync.mark_event_applied(&event.event_id)?;

            // Update snapshot with new aggregate so subsequent loads see current state.
            let existing_snap = sync.fetch_snapshot(&event.item_id)?;
            let prev_rev = existing_snap.map(|s| s.snapshot_revision).unwrap_or(0);
            let updated_snap = ItemSnapshot::compacted(
                event.item_id.clone(),
                prev_rev,
                event.event_id.clone(),
                delta.new_aggregate.clone(),
            );
            sync.upsert_snapshot(&updated_snap)?;

            // Update projection.
            let projection_state = projection_state_for_aggregate(
                sync.fetch_projection(&event.item_id)?,
                &delta.new_aggregate,
            );

            sync.upsert_projection(&event.item_id, &projection_state)?;
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
                result.fork_plans.push((event.item_id.clone(), plan));
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
            let aggregate = load_aggregate(&sync, &event.item_id)?;
            let mut apply_result = projector::apply_event(aggregate.as_ref(), &event.payload);

            // Enrich fork plans with lineage.
            if let ApplyResult::Forked(ref mut plan) = apply_result {
                plan.forked_from = Some(event.item_id.clone());
            }

            match apply_result {
                ApplyResult::Applied(delta) => {
                    sync.remove_deferred_event(&event.event_id)?;
                    sync.append_remote_event(event)?;
                    sync.mark_event_applied(&event.event_id)?;

                    // Update snapshot with new aggregate.
                    let existing_snap = sync.fetch_snapshot(&event.item_id)?;
                    let prev_rev = existing_snap.map(|s| s.snapshot_revision).unwrap_or(0);
                    let updated_snap = ItemSnapshot::compacted(
                        event.item_id.clone(),
                        prev_rev,
                        event.event_id.clone(),
                        delta.new_aggregate.clone(),
                    );
                    sync.upsert_snapshot(&updated_snap)?;

                    let projection_state = projection_state_for_aggregate(
                        sync.fetch_projection(&event.item_id)?,
                        &delta.new_aggregate,
                    );
                    sync.upsert_projection(&event.item_id, &projection_state)?;

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
                    result.fork_plans.push((event.item_id.clone(), plan));
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

fn events_after_checkpoints<'a>(
    checkpoints: &[ItemSnapshot],
    tail_events: &'a [ItemEvent],
) -> (Vec<&'a ItemEvent>, usize) {
    let checkpoint_watermarks: HashMap<&str, &str> = checkpoints
        .iter()
        .filter_map(|snapshot| {
            snapshot
                .covers_through_event
                .as_deref()
                .map(|event_id| (snapshot.item_id.as_str(), event_id))
        })
        .collect();

    let mut events_by_item: BTreeMap<&str, Vec<&ItemEvent>> = BTreeMap::new();
    for event in tail_events {
        events_by_item
            .entry(event.item_id.as_str())
            .or_default()
            .push(event);
    }

    let mut filtered = Vec::new();
    let mut covered_count = 0;

    for (item_id, mut events) in events_by_item {
        events.sort_by(|left, right| {
            left.recorded_at
                .cmp(&right.recorded_at)
                .then_with(|| left.event_id.cmp(&right.event_id))
        });

        if let Some(watermark_event_id) = checkpoint_watermarks.get(item_id) {
            if let Some(watermark_index) = events
                .iter()
                .position(|event| event.event_id == *watermark_event_id)
            {
                covered_count += watermark_index + 1;
                filtered.extend(events.into_iter().skip(watermark_index + 1));
                continue;
            }
        }

        filtered.extend(events);
    }

    (filtered, covered_count)
}

/// Full resync: clear local sync state, apply checkpoints, then replay tail events.
///
/// Tail events are filtered per-item: when a checkpoint references a
/// `covers_through_event` that is still present in the CloudKit tail query,
/// all events through that watermark are skipped. Events for items with no
/// checkpoint are replayed in deterministic recorded_at/event_id order.
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

        let projection_state = match &snapshot.aggregate {
            ItemAggregate::Live(live) => ProjectionState::PendingMaterialization {
                versions: live.versions,
            },
            ItemAggregate::Tombstoned(tomb) => ProjectionState::Tombstoned {
                versions: tomb.versions,
            },
        };

        sync.upsert_projection(&snapshot.item_id, &projection_state)?;

        result.checkpoints_applied += 1;
    }

    let (tail_events_to_apply, covered_tail_events) =
        events_after_checkpoints(checkpoints, tail_events);
    result.tail_events_ignored += covered_tail_events;

    // Apply tail events that aren't already covered by checkpoints.
    let tail_events_to_apply: Vec<ItemEvent> = tail_events_to_apply.into_iter().cloned().collect();
    let batch_result = apply_remote_event_batch(pool, &tail_events_to_apply)?;
    result.tail_events_applied += batch_result.events_applied + batch_result.events_forked;
    result.tail_events_ignored += batch_result.events_ignored;
    result.tail_events_deferred += batch_result.events_deferred;
    result.tail_events_forked += batch_result.events_forked;
    result.fork_plans.extend(batch_result.fork_plans);

    // Keep the full resync flag set when replay still has unresolved gaps.
    sync.set_dirty_flag(FLAG_NEEDS_FULL_RESYNC, result.tail_events_deferred > 0)?;

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
fn load_aggregate(sync: &SyncStore<'_>, item_id: &str) -> SyncResult<Option<ItemAggregate>> {
    // First check projection for version info.
    let projection = sync.fetch_projection(item_id)?;
    if projection.is_none() {
        // No projection entry — check if there's a snapshot.
        let snapshot = sync.fetch_snapshot(item_id)?;
        return Ok(snapshot.map(|s| s.aggregate));
    }

    // Projection exists — use snapshot as authoritative aggregate.
    let snapshot = sync.fetch_snapshot(item_id)?;
    Ok(snapshot.map(|s| s.aggregate))
}

fn projection_state_for_aggregate(
    existing_projection: Option<ProjectionEntry>,
    aggregate: &ItemAggregate,
) -> ProjectionState {
    match aggregate {
        ItemAggregate::Live(live) => match existing_projection.map(|entry| entry.state) {
            Some(ProjectionState::Materialized { .. }) => ProjectionState::Materialized {
                versions: live.versions,
            },
            Some(ProjectionState::PendingMaterialization { .. })
            | Some(ProjectionState::Tombstoned { .. })
            | None => ProjectionState::PendingMaterialization {
                versions: live.versions,
            },
        },
        ItemAggregate::Tombstoned(tomb) => ProjectionState::Tombstoned {
            versions: tomb.versions,
        },
    }
}
