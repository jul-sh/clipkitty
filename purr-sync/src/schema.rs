//! Sync schema setup — creates all sync tables on a shared connection.

use crate::error::SyncResult;

fn table_has_column(
    conn: &rusqlite::Connection,
    table: &str,
    column: &str,
) -> SyncResult<bool> {
    let pragma = format!("PRAGMA table_info({table})");
    let mut stmt = conn.prepare(&pragma)?;
    let mut rows = stmt.query([])?;
    while let Some(row) = rows.next()? {
        let name: String = row.get(1)?;
        if name == column {
            return Ok(true);
        }
    }
    Ok(false)
}

fn reset_pre_release_sync_schema_if_needed(conn: &rusqlite::Connection) -> SyncResult<()> {
    let has_legacy_event_id = table_has_column(conn, "sync_events", "global_item_id")?;
    let has_legacy_snapshot_id = table_has_column(conn, "sync_snapshots", "global_item_id")?;
    let has_legacy_projection_id = table_has_column(conn, "sync_projection", "global_item_id")?;
    let has_legacy_projection_mapping = table_has_column(conn, "sync_projection", "local_item_id")?;
    let has_legacy_deferred_id = table_has_column(conn, "sync_deferred_events", "global_item_id")?;

    if !(has_legacy_event_id
        || has_legacy_snapshot_id
        || has_legacy_projection_id
        || has_legacy_projection_mapping
        || has_legacy_deferred_id)
    {
        return Ok(());
    }

    conn.execute_batch(
        r#"
        DROP TABLE IF EXISTS sync_events;
        DROP TABLE IF EXISTS sync_snapshots;
        DROP TABLE IF EXISTS sync_projection;
        DROP TABLE IF EXISTS sync_deferred_events;
        DROP TABLE IF EXISTS sync_dedup;
        DROP TABLE IF EXISTS sync_device_state;
        DROP TABLE IF EXISTS sync_dirty_flags;
        "#,
    )?;

    Ok(())
}

/// Create all sync tables on the given connection.
/// Called by the host crate during database initialization.
pub fn setup_sync_schema(conn: &rusqlite::Connection) -> SyncResult<()> {
    reset_pre_release_sync_schema_if_needed(conn)?;

    conn.execute_batch(
        r#"
        -- Local append-only event log. Immutable once written.
        CREATE TABLE IF NOT EXISTS sync_events (
            event_id TEXT PRIMARY KEY,
            item_id TEXT NOT NULL,
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
            ON sync_events(item_id, recorded_at);
        CREATE INDEX IF NOT EXISTS idx_sync_events_pending_upload
            ON sync_events(uploaded) WHERE uploaded = 0 AND is_local = 1;
        CREATE INDEX IF NOT EXISTS idx_sync_events_compactable
            ON sync_events(item_id, compacted) WHERE compacted = 0;

        -- Latest known snapshot per item. Mutable (overwritten on compaction).
        -- Acts as a checkpoint: tracks whether it has been uploaded to CloudKit.
        CREATE TABLE IF NOT EXISTS sync_snapshots (
            item_id TEXT PRIMARY KEY,
            snapshot_revision INTEGER NOT NULL DEFAULT 0,
            schema_version INTEGER NOT NULL DEFAULT 1,
            covers_through_event TEXT,
            aggregate_state TEXT NOT NULL,
            uploaded INTEGER NOT NULL DEFAULT 0,
            uploaded_at INTEGER
        );

        -- Per-domain version counters and lifecycle state.
        CREATE TABLE IF NOT EXISTS sync_projection (
            item_id TEXT PRIMARY KEY,
            content_version INTEGER NOT NULL DEFAULT 0,
            bookmark_version INTEGER NOT NULL DEFAULT 0,
            existence_version INTEGER NOT NULL DEFAULT 0,
            touch_version INTEGER NOT NULL DEFAULT 0,
            metadata_version INTEGER NOT NULL DEFAULT 0,
            is_tombstoned INTEGER NOT NULL DEFAULT 0,
            is_materialized INTEGER NOT NULL DEFAULT 0
        );

        -- Events that arrived out of order or have unsatisfied base versions.
        CREATE TABLE IF NOT EXISTS sync_deferred_events (
            event_id TEXT PRIMARY KEY,
            item_id TEXT NOT NULL,
            origin_device_id TEXT NOT NULL,
            schema_version INTEGER NOT NULL DEFAULT 1,
            recorded_at INTEGER NOT NULL,
            payload_type TEXT NOT NULL,
            payload_data TEXT NOT NULL,
            deferred_reason TEXT NOT NULL,
            deferred_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_sync_deferred_item
            ON sync_deferred_events(item_id);

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

    // Idempotent migration for existing databases: add checkpoint upload columns.
    let _ = conn.execute(
        "ALTER TABLE sync_snapshots ADD COLUMN uploaded INTEGER NOT NULL DEFAULT 0",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE sync_snapshots ADD COLUMN uploaded_at INTEGER",
        [],
    );

    Ok(())
}
