//! Sync event envelope — the immutable record of a single mutation.

use crate::sync::types::{ItemEventPayload, SYNC_SCHEMA_VERSION};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// An immutable event record describing one mutation to one logical item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ItemEvent {
    pub event_id: String,
    pub global_item_id: String,
    pub origin_device_id: String,
    pub schema_version: u32,
    pub recorded_at: i64,
    pub payload: ItemEventPayload,
}

impl ItemEvent {
    /// Create a new local event with a fresh UUID and current timestamp.
    pub fn new_local(
        global_item_id: String,
        device_id: &str,
        payload: ItemEventPayload,
    ) -> Self {
        Self {
            event_id: Uuid::new_v4().to_string(),
            global_item_id,
            origin_device_id: device_id.to_string(),
            schema_version: SYNC_SCHEMA_VERSION,
            recorded_at: Utc::now().timestamp(),
            payload,
        }
    }

    /// Reconstruct from database/CloudKit fields.
    pub fn from_stored(
        event_id: String,
        global_item_id: String,
        origin_device_id: String,
        schema_version: u32,
        recorded_at: i64,
        payload_type: &str,
        payload_data: &str,
    ) -> Result<Self, String> {
        let _ = payload_type; // type tag is embedded in the JSON discriminant
        let payload: ItemEventPayload =
            serde_json::from_str(payload_data).map_err(|e| format!("payload deserialize: {e}"))?;
        Ok(Self {
            event_id,
            global_item_id,
            origin_device_id,
            schema_version,
            recorded_at,
            payload,
        })
    }

    /// Serialize the payload for storage.
    pub fn payload_data(&self) -> String {
        serde_json::to_string(&self.payload).expect("payload serialization cannot fail")
    }

    /// The type tag string for database/CloudKit `payload_type` column.
    pub fn payload_type(&self) -> &'static str {
        self.payload.type_tag()
    }

    /// Approximate byte size of the serialized payload (for compaction thresholds).
    pub fn payload_size(&self) -> usize {
        self.payload_data().len()
    }
}
