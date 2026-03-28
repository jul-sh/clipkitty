//! Sync schema setup — creates all sync tables on a shared connection.

use crate::error::SyncResult;

/// Create all sync tables on the given connection.
/// Called by the host crate during database initialization.
pub fn setup_sync_schema(conn: &rusqlite::Connection) -> SyncResult<()> {
    conn.execute_batch(
        r#"
        -- Local append-only event log. Immutable once written.
        CREATE TABLE IF NOT EXISTS sync_events (
            event_id TEXT PRIMARY KEY,
            global_item_id TEXT NOT NULL,
            origin_device_id TEXT NOT NULL,
            schema_version INTEGER NOT NULL DEFAULT 1,
            recorded_at INTEGER NOT NULL,
            payload_type TEXT NOT NULL,
            payload_data TEXT NOT NULL,
            is_local INTEGER NOT NULL DEFAULT 0,
            uploaded INTEGER NOT NULL DEFAULT 0,
            compacted INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_sync_events_item
            ON sync_events(global_item_id, recorded_at);
        CREATE INDEX IF NOT EXISTS idx_sync_events_pending_upload
            ON sync_events(uploaded) WHERE uploaded = 0 AND is_local = 1;
        CREATE INDEX IF NOT EXISTS idx_sync_events_compactable
            ON sync_events(global_item_id, compacted) WHERE compacted = 0;

        -- Latest known snapshot per item. Mutable (overwritten on compaction).
        CREATE TABLE IF NOT EXISTS sync_snapshots (
            global_item_id TEXT PRIMARY KEY,
            snapshot_revision INTEGER NOT NULL DEFAULT 0,
            schema_version INTEGER NOT NULL DEFAULT 1,
            covers_through_event TEXT,
            aggregate_state TEXT NOT NULL
        );

        -- Map global_item_id -> local_item_id plus per-domain version counters.
        CREATE TABLE IF NOT EXISTS sync_projection (
            global_item_id TEXT PRIMARY KEY,
            local_item_id INTEGER,
            content_version INTEGER NOT NULL DEFAULT 0,
            bookmark_version INTEGER NOT NULL DEFAULT 0,
            existence_version INTEGER NOT NULL DEFAULT 0,
            touch_version INTEGER NOT NULL DEFAULT 0,
            metadata_version INTEGER NOT NULL DEFAULT 0,
            is_tombstoned INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_sync_projection_local
            ON sync_projection(local_item_id) WHERE local_item_id IS NOT NULL;

        -- Events that arrived out of order or have unsatisfied base versions.
        CREATE TABLE IF NOT EXISTS sync_deferred_events (
            event_id TEXT PRIMARY KEY,
            global_item_id TEXT NOT NULL,
            origin_device_id TEXT NOT NULL,
            schema_version INTEGER NOT NULL DEFAULT 1,
            recorded_at INTEGER NOT NULL,
            payload_type TEXT NOT NULL,
            payload_data TEXT NOT NULL,
            deferred_reason TEXT NOT NULL,
            deferred_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_sync_deferred_item
            ON sync_deferred_events(global_item_id);

        -- Tracks which remote event_ids have been applied (prevents double-apply).
        CREATE TABLE IF NOT EXISTS sync_dedup (
            event_id TEXT PRIMARY KEY,
            applied_at INTEGER NOT NULL
        );

        -- Per-device sync cursor and health.
        CREATE TABLE IF NOT EXISTS sync_device_state (
            device_id TEXT PRIMARY KEY,
            last_zone_change_token BLOB,
            last_full_resync_at INTEGER,
            heartbeat_at INTEGER NOT NULL
        );

        -- Flags that drive background maintenance work.
        CREATE TABLE IF NOT EXISTS sync_dirty_flags (
            flag_name TEXT PRIMARY KEY,
            flag_value INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL
        );
        "#,
    )?;
    Ok(())
}
