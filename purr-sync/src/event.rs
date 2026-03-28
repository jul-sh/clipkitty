//! Sync event envelope — the immutable record of a single mutation.

use crate::types::{ItemEventPayload, SYNC_SCHEMA_VERSION};
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
    ///
    /// If the payload cannot be deserialized (e.g. from a newer schema version),
    /// returns an event with `ItemEventPayload::Unknown` so the caller can
    /// gracefully ignore it rather than failing the entire batch.
    pub fn from_stored(
        event_id: String,
        global_item_id: String,
        origin_device_id: String,
        schema_version: u32,
        recorded_at: i64,
        payload_type: &str,
        payload_data: &str,
    ) -> Result<Self, String> {
        let payload = match serde_json::from_str::<ItemEventPayload>(payload_data) {
            Ok(p) => p,
            Err(_) => ItemEventPayload::Unknown {
                raw_type: payload_type.to_string(),
                raw_data: payload_data.to_string(),
            },
        };
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
    ///
    /// For Unknown payloads, returns the original raw JSON to preserve
    /// round-trip fidelity — re-serializing would wrap it in `{"Unknown":...}`.
    pub fn payload_data(&self) -> String {
        match &self.payload {
            ItemEventPayload::Unknown { raw_data, .. } => raw_data.clone(),
            _ => serde_json::to_string(&self.payload).expect("payload serialization cannot fail"),
        }
    }

    /// The type tag string for database/CloudKit `payload_type` column.
    pub fn payload_type(&self) -> String {
        self.payload.type_tag()
    }

    /// Approximate byte size of the serialized payload (for compaction thresholds).
    pub fn payload_size(&self) -> usize {
        self.payload_data().len()
    }
}
