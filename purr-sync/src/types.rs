//! Core sync domain types.
//!
//! Models state as exhaustive sum types — no parallel booleans.

use serde::{Deserialize, Serialize};

/// Current schema version for sync events and snapshots.
pub const SYNC_SCHEMA_VERSION: u32 = 1;

/// Minimum schema version we can still process (forward compatibility window).
/// Events with `schema_version` in `[SYNC_MIN_COMPATIBLE_VERSION, SYNC_SCHEMA_VERSION]`
/// are applied normally. Events above SYNC_SCHEMA_VERSION but still deserializable
/// are applied with a warning. Events with unknown payload types are ignored gracefully.
pub const SYNC_MIN_COMPATIBLE_VERSION: u32 = 1;

// ─────────────────────────────────────────────────────────────────────────────
// Version Counters
// ─────────────────────────────────────────────────────────────────────────────

/// Per-domain version counters tracked in the projection.
/// Each domain increments independently so base-version checks
/// only conflict within the same domain.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct VersionVector {
    pub content: u64,
    pub bookmark: u64,
    pub existence: u64,
    pub touch: u64,
    pub metadata: u64,
}

// ─────────────────────────────────────────────────────────────────────────────
// Link Metadata Snapshot
// ─────────────────────────────────────────────────────────────────────────────

/// Snapshot of link metadata for sync transport.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LinkMetadataSnapshot {
    pub title: Option<String>,
    pub description: Option<String>,
    /// Base64-encoded image data for transport.
    pub image_data_base64: Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Event Payloads
// ─────────────────────────────────────────────────────────────────────────────

/// Semantic payload of a single sync event.
/// Each variant carries the data needed to apply and the base version
/// it was written against, enabling out-of-order conflict detection.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ItemEventPayload {
    ItemCreated {
        snapshot: ItemSnapshotData,
    },
    TextEdited {
        new_text: String,
        base_content_version: u64,
    },
    BookmarkSet {
        base_bookmark_version: u64,
    },
    BookmarkCleared {
        base_bookmark_version: u64,
    },
    ItemDeleted {
        base_existence_version: u64,
    },
    ItemTouched {
        new_last_used_at_unix: i64,
        base_touch_version: u64,
    },
    LinkMetadataUpdated {
        metadata: LinkMetadataSnapshot,
        base_metadata_version: u64,
    },
    ImageDescriptionUpdated {
        description: String,
        base_content_version: u64,
    },
    /// Payload from a newer schema version that we don't understand.
    /// Preserved for round-tripping but ignored by the projector.
    Unknown {
        raw_type: String,
        raw_data: String,
    },
}

impl ItemEventPayload {
    /// Returns the string tag used for `payload_type` in the database and CloudKit.
    pub fn type_tag(&self) -> String {
        match self {
            Self::ItemCreated { .. } => "item_created".to_string(),
            Self::TextEdited { .. } => "text_edited".to_string(),
            Self::BookmarkSet { .. } => "bookmark_set".to_string(),
            Self::BookmarkCleared { .. } => "bookmark_cleared".to_string(),
            Self::ItemDeleted { .. } => "item_deleted".to_string(),
            Self::ItemTouched { .. } => "item_touched".to_string(),
            Self::LinkMetadataUpdated { .. } => "link_metadata_updated".to_string(),
            Self::ImageDescriptionUpdated { .. } => "image_description_updated".to_string(),
            Self::Unknown { raw_type, .. } => raw_type.clone(),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Snapshot Data
// ─────────────────────────────────────────────────────────────────────────────

/// The full materialized state of an item, used in ItemCreated events
/// and in compacted snapshots. Serializable for CloudKit transport.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ItemSnapshotData {
    pub content_type: String,
    pub content_text: String,
    pub content_hash: String,
    pub source_app: Option<String>,
    pub source_app_bundle_id: Option<String>,
    pub timestamp_unix: i64,
    pub is_bookmarked: bool,
    /// Base64-encoded thumbnail for transport.
    pub thumbnail_base64: Option<String>,
    pub color_rgba: Option<u32>,
    /// Type-specific data (text value, image bytes, link url, file entries, etc.)
    pub type_specific: TypeSpecificData,
}

/// Type-specific content carried in a snapshot.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum TypeSpecificData {
    Text {
        value: String,
    },
    Color {
        value: String,
    },
    Link {
        url: String,
        metadata: Option<LinkMetadataSnapshot>,
    },
    Image {
        /// Base64-encoded image data for transport.
        data_base64: String,
        description: String,
        is_animated: bool,
    },
    File {
        display_name: String,
        files: Vec<FileSnapshotEntry>,
    },
}

/// A single file entry in a snapshot.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileSnapshotEntry {
    pub path: String,
    pub filename: String,
    pub file_size: u64,
    pub uti: String,
    /// Base64-encoded bookmark data for transport.
    pub bookmark_data_base64: String,
    pub file_status: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// Aggregate State (the "current truth" for one item)
// ─────────────────────────────────────────────────────────────────────────────

/// The aggregate state of a single logical item.
/// Explicitly models live vs tombstoned — no `is_deleted` boolean.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ItemAggregate {
    Live(LiveItemState),
    Tombstoned(TombstoneState),
}

/// State of a live (non-deleted) item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LiveItemState {
    pub snapshot: ItemSnapshotData,
    pub versions: VersionVector,
}

/// State of a deleted item — kept for tombstone protection.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TombstoneState {
    pub deleted_at_unix: i64,
    pub versions: VersionVector,
    /// Content type preserved for logging/diagnostics.
    pub content_type: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// Apply Result
// ─────────────────────────────────────────────────────────────────────────────

/// Outcome of applying a single event to an aggregate.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ApplyResult {
    /// Event was successfully applied; delta describes what changed.
    Applied(ProjectionDelta),
    /// Event was recognized but had no effect (e.g., stale version, no-op).
    Ignored(IgnoreReason),
    /// Event cannot be applied yet (missing prerequisite state).
    Deferred(DeferredReason),
    /// Event conflicts in a way that requires creating a fork (new item).
    Forked(ForkPlan),
}

/// What changed as a result of applying an event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectionDelta {
    pub new_aggregate: ItemAggregate,
    /// Which version domains were bumped.
    pub bumped_domains: Vec<VersionDomain>,
    /// If true, the local read model (items table) needs updating.
    pub read_model_dirty: bool,
    /// If true, the Tantivy index needs updating.
    pub index_dirty: bool,
}

/// Identifies a version domain for delta reporting.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum VersionDomain {
    Content,
    Bookmark,
    Existence,
    Touch,
    Metadata,
}

/// Why an event was ignored (no state change).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum IgnoreReason {
    /// The event's base version is behind the current version (stale).
    StaleVersion {
        domain: VersionDomain,
        event_base: u64,
        current: u64,
    },
    /// Operation on a tombstoned item that doesn't warrant resurrection.
    OperationOnTombstone,
    /// Duplicate event (already applied).
    AlreadyApplied,
    /// Event's schema version is too new and incompatible.
    UnsupportedVersion {
        event_version: u32,
        max_supported: u32,
    },
    /// Payload type is unknown (from a newer client).
    UnknownPayload { raw_type: String },
}

/// Why an event was deferred (cannot apply yet).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum DeferredReason {
    /// The item hasn't been created locally yet.
    MissingItem,
    /// The base version is ahead of the current version (future event).
    FutureVersion {
        domain: VersionDomain,
        event_base: u64,
        current: u64,
    },
}

/// Plan for resolving an event that requires forking a new item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ForkPlan {
    /// The new item's snapshot data (created from the conflicting event).
    pub forked_snapshot: ItemSnapshotData,
    /// Human-readable reason for the fork.
    pub reason: String,
    /// The item_id of the original item that triggered the fork.
    /// Set by the replay layer (not the projector) since the projector
    /// operates on aggregates without item identity.
    #[serde(default)]
    pub forked_from: Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Dirty Flags
// ─────────────────────────────────────────────────────────────────────────────

/// Well-known dirty flag names stored in sync_dirty_flags.
pub const FLAG_INDEX_DIRTY: &str = "index_dirty";
pub const FLAG_NEEDS_FULL_RESYNC: &str = "needs_full_resync";

// ─────────────────────────────────────────────────────────────────────────────
// Compaction Constants
// ─────────────────────────────────────────────────────────────────────────────

/// Maximum uncompacted events per item before compaction triggers.
pub const COMPACTION_EVENT_THRESHOLD: usize = 32;
/// Maximum uncompacted payload bytes per item before compaction triggers.
pub const COMPACTION_PAYLOAD_THRESHOLD: usize = 128 * 1024;
/// Oldest uncompacted event age (seconds) before compaction triggers.
pub const COMPACTION_AGE_THRESHOLD_SECS: i64 = 7 * 24 * 3600;
/// Tombstone age (seconds) after which stale events trigger compaction.
pub const TOMBSTONE_COMPACTION_AGE_SECS: i64 = 30 * 24 * 3600;

/// Retention: keep tombstone snapshots for 90 days.
pub const TOMBSTONE_SNAPSHOT_RETENTION_SECS: i64 = 90 * 24 * 3600;
/// Retention: keep compacted raw events for 30 days after snapshot coverage.
pub const COMPACTED_EVENT_RETENTION_SECS: i64 = 30 * 24 * 3600;

// ─────────────────────────────────────────────────────────────────────────────
// Download Batch Outcome
// ─────────────────────────────────────────────────────────────────────────────

/// Outcome of applying a downloaded batch of remote changes.
/// Used to decide whether the CloudKit zone change token should be advanced.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DownloadBatchOutcome {
    /// All events and snapshots applied successfully.
    Applied {
        events_applied: usize,
        snapshots_applied: usize,
    },
    /// Some events failed to materialize into the read model.
    /// Token must NOT be advanced — retry on next cycle.
    PartialFailure {
        applied_count: usize,
        failed_count: usize,
        should_retry: bool,
    },
    /// Deferred events exceeded retry threshold; full resync needed.
    FullResyncRequired,
}

// ─────────────────────────────────────────────────────────────────────────────
// Checkpoint State
// ─────────────────────────────────────────────────────────────────────────────

/// Whether a checkpoint (compacted snapshot) has been replicated to CloudKit.
/// Drives cleanup gating: events are only purgeable when covered by an
/// uploaded checkpoint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CheckpointState {
    /// No snapshot exists for this item.
    Absent,
    /// Snapshot exists locally but has not been uploaded to CloudKit.
    LocalOnly { covers_through_event: String },
    /// Snapshot has been confirmed in CloudKit.
    Uploaded {
        covers_through_event: String,
        uploaded_at: i64,
    },
}

// ─────────────────────────────────────────────────────────────────────────────
// Full Resync Result
// ─────────────────────────────────────────────────────────────────────────────

/// Result of a full resync operation (checkpoints + tail events).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FullResyncResult {
    pub checkpoints_applied: usize,
    pub tail_events_applied: usize,
    pub tail_events_ignored: usize,
    pub tail_events_deferred: usize,
    pub tail_events_forked: usize,
    pub fork_plans: Vec<(String, ForkPlan)>,
}
