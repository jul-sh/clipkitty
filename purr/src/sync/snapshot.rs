//! Sync snapshot envelope — the mutable compaction artifact.

use crate::sync::types::{ItemAggregate, SYNC_SCHEMA_VERSION};
use serde::{Deserialize, Serialize};

/// A compacted snapshot of a single logical item's aggregate state.
/// One mutable record per `global_item_id` — overwritten on each compaction.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ItemSnapshot {
    pub global_item_id: String,
    pub snapshot_revision: u64,
    pub schema_version: u32,
    /// The event_id of the last event folded into this snapshot.
    pub covers_through_event: Option<String>,
    pub aggregate: ItemAggregate,
}

impl ItemSnapshot {
    /// Create the initial snapshot from an ItemCreated event.
    pub fn initial(global_item_id: String, aggregate: ItemAggregate) -> Self {
        Self {
            global_item_id,
            snapshot_revision: 1,
            schema_version: SYNC_SCHEMA_VERSION,
            covers_through_event: None,
            aggregate,
        }
    }

    /// Create a new compacted revision.
    pub fn compacted(
        global_item_id: String,
        previous_revision: u64,
        covers_through_event: String,
        aggregate: ItemAggregate,
    ) -> Self {
        Self {
            global_item_id,
            snapshot_revision: previous_revision + 1,
            schema_version: SYNC_SCHEMA_VERSION,
            covers_through_event: Some(covers_through_event),
            aggregate,
        }
    }

    /// Serialize the aggregate state for storage.
    pub fn aggregate_data(&self) -> String {
        serde_json::to_string(&self.aggregate).expect("aggregate serialization cannot fail")
    }

    /// Deserialize from stored fields.
    pub fn from_stored(
        global_item_id: String,
        snapshot_revision: u64,
        schema_version: u32,
        covers_through_event: Option<String>,
        aggregate_data: &str,
    ) -> Result<Self, String> {
        let aggregate: ItemAggregate = serde_json::from_str(aggregate_data)
            .map_err(|e| format!("aggregate deserialize: {e}"))?;
        Ok(Self {
            global_item_id,
            snapshot_revision,
            schema_version,
            covers_through_event,
            aggregate,
        })
    }
}
