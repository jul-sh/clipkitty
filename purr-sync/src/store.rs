//! Sync store — local persistence layer for sync state.
//!
//! CRUD operations on all sync tables through a shared connection pool.

use crate::error::{SyncError, SyncResult};
use crate::event::ItemEvent;
use crate::snapshot::ItemSnapshot;
use crate::types::{
    CheckpointState, DeferredReason, IndexQueueEntry, IndexQueueOperation, VersionVector,
    INDEX_QUEUE_RESET_KEY,
};
use chrono::Utc;
use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;
use rusqlite::params;

/// Sync-specific persistence operations layered on top of a shared pool.
pub struct SyncStore<'a> {
    pool: &'a Pool<SqliteConnectionManager>,
}

impl<'a> SyncStore<'a> {
    pub fn new(pool: &'a Pool<SqliteConnectionManager>) -> Self {
        Self { pool }
    }

    fn get_conn(&self) -> SyncResult<r2d2::PooledConnection<SqliteConnectionManager>> {
        Ok(self.pool.get()?)
    }

    // ── Events ───────────────────────────────────────────────────────────

    /// Append a local event to sync_events.
    pub fn append_local_event(&self, event: &ItemEvent) -> SyncResult<()> {
        let conn = self.get_conn()?;
        conn.execute(
            r#"INSERT INTO sync_events
               (event_id, item_id, origin_device_id, schema_version, recorded_at,
                payload_type, payload_data, is_local, uploaded, compacted)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 1, 0, 0)"#,
            params![
                event.event_id,
                event.item_id,
                event.origin_device_id,
                event.schema_version,
                event.recorded_at,
                event.payload_type(),
                event.payload_data(),
            ],
        )?;
        Ok(())
    }

    /// Append a remote event to sync_events (non-local).
    pub fn append_remote_event(&self, event: &ItemEvent) -> SyncResult<()> {
        let conn = self.get_conn()?;
        conn.execute(
            r#"INSERT OR IGNORE INTO sync_events
               (event_id, item_id, origin_device_id, schema_version, recorded_at,
                payload_type, payload_data, is_local, uploaded, compacted)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0, 1, 0)"#,
            params![
                event.event_id,
                event.item_id,
                event.origin_device_id,
                event.schema_version,
                event.recorded_at,
                event.payload_type(),
                event.payload_data(),
            ],
        )?;
        Ok(())
    }

    /// Fetch uncompacted events for a given item in the same deterministic order
    /// replay uses when interpreting checkpoint watermarks.
    pub fn fetch_uncompacted_events(&self, item_id: &str) -> SyncResult<Vec<ItemEvent>> {
        let conn = self.get_conn()?;
        let mut stmt = conn.prepare(
            r#"SELECT event_id, item_id, origin_device_id, schema_version,
                      recorded_at, payload_type, payload_data
               FROM sync_events
               WHERE item_id = ?1 AND compacted = 0
               ORDER BY recorded_at ASC, event_id ASC"#,
        )?;
        let events = stmt
            .query_map(params![item_id], |row| {
                let event_id: String = row.get(0)?;
                let gid: String = row.get(1)?;
                let device: String = row.get(2)?;
                let schema: u32 = row.get(3)?;
                let recorded: i64 = row.get(4)?;
                let ptype: String = row.get(5)?;
                let pdata: String = row.get(6)?;
                Ok((event_id, gid, device, schema, recorded, ptype, pdata))
            })?
            .collect::<Result<Vec<_>, _>>()?;

        events
            .into_iter()
            .map(|(eid, gid, dev, schema, rec, pt, pd)| {
                ItemEvent::from_stored(eid, gid, dev, schema, rec, &pt, &pd)
                    .map_err(SyncError::InconsistentData)
            })
            .collect()
    }

    /// Fetch pending local events that haven't been uploaded yet.
    pub fn fetch_pending_upload_events(&self) -> SyncResult<Vec<ItemEvent>> {
        let conn = self.get_conn()?;
        let mut stmt = conn.prepare(
            r#"SELECT event_id, item_id, origin_device_id, schema_version,
                      recorded_at, payload_type, payload_data
               FROM sync_events
               WHERE is_local = 1 AND uploaded = 0
               ORDER BY recorded_at ASC"#,
        )?;
        let events = stmt
            .query_map([], |row| {
                let event_id: String = row.get(0)?;
                let gid: String = row.get(1)?;
                let device: String = row.get(2)?;
                let schema: u32 = row.get(3)?;
                let recorded: i64 = row.get(4)?;
                let ptype: String = row.get(5)?;
                let pdata: String = row.get(6)?;
                Ok((event_id, gid, device, schema, recorded, ptype, pdata))
            })?
            .collect::<Result<Vec<_>, _>>()?;

        events
            .into_iter()
            .map(|(eid, gid, dev, schema, rec, pt, pd)| {
                ItemEvent::from_stored(eid, gid, dev, schema, rec, &pt, &pd)
                    .map_err(SyncError::InconsistentData)
            })
            .collect()
    }

    /// Mark events as uploaded.
    pub fn mark_events_uploaded(&self, event_ids: &[&str]) -> SyncResult<()> {
        if event_ids.is_empty() {
            return Ok(());
        }
        let conn = self.get_conn()?;
        let placeholders: Vec<String> = (1..=event_ids.len()).map(|i| format!("?{i}")).collect();
        let sql = format!(
            "UPDATE sync_events SET uploaded = 1 WHERE event_id IN ({})",
            placeholders.join(", ")
        );
        let params: Vec<&dyn rusqlite::ToSql> = event_ids
            .iter()
            .map(|id| id as &dyn rusqlite::ToSql)
            .collect();
        conn.execute(&sql, params.as_slice())?;
        Ok(())
    }

    /// Mark events as compacted.
    pub fn mark_events_compacted(&self, event_ids: &[&str]) -> SyncResult<()> {
        if event_ids.is_empty() {
            return Ok(());
        }
        let conn = self.get_conn()?;
        let placeholders: Vec<String> = (1..=event_ids.len()).map(|i| format!("?{i}")).collect();
        let sql = format!(
            "UPDATE sync_events SET compacted = 1 WHERE event_id IN ({})",
            placeholders.join(", ")
        );
        let params: Vec<&dyn rusqlite::ToSql> = event_ids
            .iter()
            .map(|id| id as &dyn rusqlite::ToSql)
            .collect();
        conn.execute(&sql, params.as_slice())?;
        Ok(())
    }

    /// Delete compacted events older than the given threshold.
    pub fn delete_compacted_events_before(&self, threshold_unix: i64) -> SyncResult<usize> {
        let conn = self.get_conn()?;
        let count = conn.execute(
            "DELETE FROM sync_events WHERE compacted = 1 AND recorded_at < ?1",
            params![threshold_unix],
        )?;
        Ok(count)
    }

    /// Count uncompacted events for an item.
    pub fn count_uncompacted_events(&self, item_id: &str) -> SyncResult<usize> {
        let conn = self.get_conn()?;
        let count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM sync_events WHERE item_id = ?1 AND compacted = 0",
            params![item_id],
            |row| row.get(0),
        )?;
        Ok(count as usize)
    }

    /// Sum payload sizes of uncompacted events for an item.
    pub fn uncompacted_payload_size(&self, item_id: &str) -> SyncResult<usize> {
        let conn = self.get_conn()?;
        let size: i64 = conn.query_row(
            "SELECT COALESCE(SUM(LENGTH(payload_data)), 0) FROM sync_events WHERE item_id = ?1 AND compacted = 0",
            params![item_id],
            |row| row.get(0),
        )?;
        Ok(size as usize)
    }

    /// Get the oldest uncompacted event timestamp for an item.
    pub fn oldest_uncompacted_event_time(&self, item_id: &str) -> SyncResult<Option<i64>> {
        let conn = self.get_conn()?;
        let result = conn.query_row(
            "SELECT MIN(recorded_at) FROM sync_events WHERE item_id = ?1 AND compacted = 0",
            params![item_id],
            |row| row.get::<_, Option<i64>>(0),
        )?;
        Ok(result)
    }

    /// Fetch all item_ids that have uncompacted events.
    pub fn items_with_uncompacted_events(&self) -> SyncResult<Vec<String>> {
        let conn = self.get_conn()?;
        let mut stmt =
            conn.prepare("SELECT DISTINCT item_id FROM sync_events WHERE compacted = 0")?;
        let ids = stmt
            .query_map([], |row| row.get(0))?
            .collect::<Result<Vec<String>, _>>()?;
        Ok(ids)
    }

    // ── Snapshots ────────────────────────────────────────────────────────

    /// Upsert a snapshot (insert or replace).
    pub fn upsert_snapshot(&self, snapshot: &ItemSnapshot) -> SyncResult<()> {
        let conn = self.get_conn()?;
        conn.execute(
            r#"INSERT INTO sync_snapshots
               (item_id, snapshot_revision, schema_version,
                covers_through_event, aggregate_state, uploaded, uploaded_at)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
               ON CONFLICT(item_id) DO UPDATE SET
                 snapshot_revision = excluded.snapshot_revision,
                 schema_version = excluded.schema_version,
                 covers_through_event = excluded.covers_through_event,
                 aggregate_state = excluded.aggregate_state,
                 uploaded = excluded.uploaded,
                 uploaded_at = excluded.uploaded_at"#,
            params![
                snapshot.item_id,
                snapshot.snapshot_revision as i64,
                snapshot.schema_version,
                snapshot.covers_through_event,
                snapshot.aggregate_data(),
                snapshot.uploaded as i32,
                snapshot.uploaded_at,
            ],
        )?;
        Ok(())
    }

    /// Fetch snapshot for an item.
    pub fn fetch_snapshot(&self, item_id: &str) -> SyncResult<Option<ItemSnapshot>> {
        let conn = self.get_conn()?;
        let result = conn.query_row(
            r#"SELECT item_id, snapshot_revision, schema_version,
                      covers_through_event, aggregate_state, uploaded, uploaded_at
               FROM sync_snapshots WHERE item_id = ?1"#,
            params![item_id],
            |row| {
                let gid: String = row.get(0)?;
                let rev: i64 = row.get(1)?;
                let schema: u32 = row.get(2)?;
                let covers: Option<String> = row.get(3)?;
                let agg: String = row.get(4)?;
                let uploaded: bool = row.get::<_, i32>(5)? != 0;
                let uploaded_at: Option<i64> = row.get(6)?;
                Ok((gid, rev as u64, schema, covers, agg, uploaded, uploaded_at))
            },
        );
        match result {
            Ok((gid, rev, schema, covers, agg, uploaded, uploaded_at)) => {
                let snap = ItemSnapshot::from_stored(
                    gid,
                    rev,
                    schema,
                    covers,
                    &agg,
                    uploaded,
                    uploaded_at,
                )
                .map_err(SyncError::InconsistentData)?;
                Ok(Some(snap))
            }
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// Fetch all snapshots (for full resync).
    pub fn fetch_all_snapshots(&self) -> SyncResult<Vec<ItemSnapshot>> {
        let conn = self.get_conn()?;
        let mut stmt = conn.prepare(
            r#"SELECT item_id, snapshot_revision, schema_version,
                      covers_through_event, aggregate_state, uploaded, uploaded_at
               FROM sync_snapshots"#,
        )?;
        let rows = stmt
            .query_map([], |row| {
                let gid: String = row.get(0)?;
                let rev: i64 = row.get(1)?;
                let schema: u32 = row.get(2)?;
                let covers: Option<String> = row.get(3)?;
                let agg: String = row.get(4)?;
                let uploaded: bool = row.get::<_, i32>(5)? != 0;
                let uploaded_at: Option<i64> = row.get(6)?;
                Ok((gid, rev as u64, schema, covers, agg, uploaded, uploaded_at))
            })?
            .collect::<Result<Vec<_>, _>>()?;

        rows.into_iter()
            .map(|(gid, rev, schema, covers, agg, uploaded, uploaded_at)| {
                ItemSnapshot::from_stored(gid, rev, schema, covers, &agg, uploaded, uploaded_at)
                    .map_err(SyncError::InconsistentData)
            })
            .collect()
    }

    /// Delete a snapshot.
    pub fn delete_snapshot(&self, item_id: &str) -> SyncResult<()> {
        let conn = self.get_conn()?;
        conn.execute(
            "DELETE FROM sync_snapshots WHERE item_id = ?1",
            params![item_id],
        )?;
        Ok(())
    }

    /// Mark a snapshot as uploaded to CloudKit.
    pub fn mark_snapshot_uploaded(&self, item_id: &str) -> SyncResult<()> {
        let conn = self.get_conn()?;
        let now = Utc::now().timestamp();
        conn.execute(
            "UPDATE sync_snapshots SET uploaded = 1, uploaded_at = ?1 WHERE item_id = ?2",
            params![now, item_id],
        )?;
        Ok(())
    }

    /// Fetch snapshots that have not been uploaded yet (for the upload queue).
    pub fn fetch_pending_upload_snapshots(&self) -> SyncResult<Vec<ItemSnapshot>> {
        let conn = self.get_conn()?;
        let mut stmt = conn.prepare(
            r#"SELECT item_id, snapshot_revision, schema_version,
                      covers_through_event, aggregate_state, uploaded, uploaded_at
               FROM sync_snapshots WHERE uploaded = 0"#,
        )?;
        let rows = stmt
            .query_map([], |row| {
                let gid: String = row.get(0)?;
                let rev: i64 = row.get(1)?;
                let schema: u32 = row.get(2)?;
                let covers: Option<String> = row.get(3)?;
                let agg: String = row.get(4)?;
                let uploaded: bool = row.get::<_, i32>(5)? != 0;
                let uploaded_at: Option<i64> = row.get(6)?;
                Ok((gid, rev as u64, schema, covers, agg, uploaded, uploaded_at))
            })?
            .collect::<Result<Vec<_>, _>>()?;

        rows.into_iter()
            .map(|(gid, rev, schema, covers, agg, uploaded, uploaded_at)| {
                ItemSnapshot::from_stored(gid, rev, schema, covers, &agg, uploaded, uploaded_at)
                    .map_err(SyncError::InconsistentData)
            })
            .collect()
    }

    /// Check whether a specific item's snapshot has been uploaded.
    pub fn is_snapshot_uploaded(&self, item_id: &str) -> SyncResult<bool> {
        let conn = self.get_conn()?;
        let result = conn.query_row(
            "SELECT uploaded FROM sync_snapshots WHERE item_id = ?1",
            params![item_id],
            |row| row.get::<_, i32>(0),
        );
        match result {
            Ok(v) => Ok(v != 0),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(false),
            Err(e) => Err(e.into()),
        }
    }

    /// Get the checkpoint state for an item.
    pub fn checkpoint_state(&self, item_id: &str) -> SyncResult<CheckpointState> {
        let conn = self.get_conn()?;
        let result = conn.query_row(
            r#"SELECT covers_through_event, uploaded, uploaded_at
               FROM sync_snapshots WHERE item_id = ?1"#,
            params![item_id],
            |row| {
                let covers: Option<String> = row.get(0)?;
                let uploaded: bool = row.get::<_, i32>(1)? != 0;
                let uploaded_at: Option<i64> = row.get(2)?;
                Ok((covers, uploaded, uploaded_at))
            },
        );
        match result {
            Ok((Some(covers), true, Some(at))) => Ok(CheckpointState::Uploaded {
                covers_through_event: covers,
                uploaded_at: at,
            }),
            Ok((Some(covers), false, _)) => Ok(CheckpointState::LocalOnly {
                covers_through_event: covers,
            }),
            Ok((None, _, _)) | Ok((_, _, _)) => Ok(CheckpointState::Absent),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(CheckpointState::Absent),
            Err(e) => Err(e.into()),
        }
    }

    /// Fetch event IDs that are safe to purge: compacted AND covered by an uploaded checkpoint.
    pub fn fetch_checkpoint_safe_purgeable_events(
        &self,
        older_than_unix: i64,
    ) -> SyncResult<Vec<String>> {
        let conn = self.get_conn()?;
        let mut stmt = conn.prepare(
            r#"SELECT e.event_id
               FROM sync_events e
               INNER JOIN sync_snapshots s ON e.item_id = s.item_id
               WHERE e.compacted = 1
                 AND e.recorded_at < ?1
                 AND s.uploaded = 1"#,
        )?;
        let ids = stmt
            .query_map(params![older_than_unix], |row| row.get(0))?
            .collect::<Result<Vec<String>, _>>()?;
        Ok(ids)
    }

    // ── Projection ───────────────────────────────────────────────────────

    /// Upsert a projection entry tracking lifecycle state and versions.
    pub fn upsert_projection(&self, item_id: &str, state: &ProjectionState) -> SyncResult<()> {
        let (versions, is_tombstoned, is_materialized) = match state {
            ProjectionState::PendingMaterialization { versions } => (versions, false, false),
            ProjectionState::Materialized { versions } => (versions, false, true),
            ProjectionState::Tombstoned { versions } => (versions, true, false),
        };
        let conn = self.get_conn()?;
        conn.execute(
            r#"INSERT INTO sync_projection
               (item_id, content_version, bookmark_version,
                existence_version, touch_version, metadata_version,
                is_tombstoned, is_materialized)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
               ON CONFLICT(item_id) DO UPDATE SET
                 content_version = excluded.content_version,
                 bookmark_version = excluded.bookmark_version,
                 existence_version = excluded.existence_version,
                 touch_version = excluded.touch_version,
                 metadata_version = excluded.metadata_version,
                 is_tombstoned = excluded.is_tombstoned,
                 is_materialized = excluded.is_materialized"#,
            params![
                item_id,
                versions.content as i64,
                versions.bookmark as i64,
                versions.existence as i64,
                versions.touch as i64,
                versions.metadata as i64,
                is_tombstoned as i32,
                is_materialized as i32,
            ],
        )?;
        Ok(())
    }

    /// Fetch the projection entry for a global item.
    pub fn fetch_projection(&self, item_id: &str) -> SyncResult<Option<ProjectionEntry>> {
        let conn = self.get_conn()?;
        let result = conn.query_row(
            r#"SELECT item_id, content_version, bookmark_version,
                      existence_version, touch_version, metadata_version,
                      is_tombstoned, is_materialized
               FROM sync_projection WHERE item_id = ?1"#,
            params![item_id],
            |row| {
                let versions = VersionVector {
                    content: row.get::<_, i64>(1)? as u64,
                    bookmark: row.get::<_, i64>(2)? as u64,
                    existence: row.get::<_, i64>(3)? as u64,
                    touch: row.get::<_, i64>(4)? as u64,
                    metadata: row.get::<_, i64>(5)? as u64,
                };
                let is_tombstoned = row.get::<_, i32>(6)? != 0;
                let is_materialized = row.get::<_, i32>(7)? != 0;
                let state = if is_tombstoned {
                    ProjectionState::Tombstoned { versions }
                } else if is_materialized {
                    ProjectionState::Materialized { versions }
                } else {
                    ProjectionState::PendingMaterialization { versions }
                };
                Ok(ProjectionEntry {
                    item_id: row.get(0)?,
                    state,
                })
            },
        );
        match result {
            Ok(entry) => Ok(Some(entry)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// Clear all projection entries (for full resync).
    pub fn clear_projections(&self) -> SyncResult<()> {
        let conn = self.get_conn()?;
        conn.execute("DELETE FROM sync_projection", [])?;
        Ok(())
    }

    /// Delete a single projection entry.
    pub fn delete_projection(&self, item_id: &str) -> SyncResult<()> {
        let conn = self.get_conn()?;
        conn.execute(
            "DELETE FROM sync_projection WHERE item_id = ?1",
            params![item_id],
        )?;
        Ok(())
    }

    // ── Deferred Events ──────────────────────────────────────────────────

    /// Store a deferred event.
    pub fn defer_event(&self, event: &ItemEvent, reason: &DeferredReason) -> SyncResult<()> {
        let reason_str = match reason {
            DeferredReason::MissingItem => "missing_item".to_string(),
            DeferredReason::FutureVersion {
                domain,
                event_base,
                current,
            } => format!("future_version:{:?}:{}:{}", domain, event_base, current),
        };
        let conn = self.get_conn()?;
        conn.execute(
            r#"INSERT OR REPLACE INTO sync_deferred_events
               (event_id, item_id, origin_device_id, schema_version, recorded_at,
                payload_type, payload_data, deferred_reason, deferred_at)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)"#,
            params![
                event.event_id,
                event.item_id,
                event.origin_device_id,
                event.schema_version,
                event.recorded_at,
                event.payload_type(),
                event.payload_data(),
                reason_str,
                Utc::now().timestamp(),
            ],
        )?;
        Ok(())
    }

    /// Fetch all deferred events for a given item.
    pub fn fetch_deferred_events_for_item(&self, item_id: &str) -> SyncResult<Vec<ItemEvent>> {
        let conn = self.get_conn()?;
        let mut stmt = conn.prepare(
            r#"SELECT event_id, item_id, origin_device_id, schema_version,
                      recorded_at, payload_type, payload_data
               FROM sync_deferred_events
               WHERE item_id = ?1
               ORDER BY recorded_at ASC"#,
        )?;
        let events = stmt
            .query_map(params![item_id], |row| {
                let event_id: String = row.get(0)?;
                let gid: String = row.get(1)?;
                let device: String = row.get(2)?;
                let schema: u32 = row.get(3)?;
                let recorded: i64 = row.get(4)?;
                let ptype: String = row.get(5)?;
                let pdata: String = row.get(6)?;
                Ok((event_id, gid, device, schema, recorded, ptype, pdata))
            })?
            .collect::<Result<Vec<_>, _>>()?;

        events
            .into_iter()
            .map(|(eid, gid, dev, schema, rec, pt, pd)| {
                ItemEvent::from_stored(eid, gid, dev, schema, rec, &pt, &pd)
                    .map_err(SyncError::InconsistentData)
            })
            .collect()
    }

    /// Fetch all deferred events.
    pub fn fetch_all_deferred_events(&self) -> SyncResult<Vec<ItemEvent>> {
        let conn = self.get_conn()?;
        let mut stmt = conn.prepare(
            r#"SELECT event_id, item_id, origin_device_id, schema_version,
                      recorded_at, payload_type, payload_data
               FROM sync_deferred_events
               ORDER BY recorded_at ASC"#,
        )?;
        let events = stmt
            .query_map([], |row| {
                let event_id: String = row.get(0)?;
                let gid: String = row.get(1)?;
                let device: String = row.get(2)?;
                let schema: u32 = row.get(3)?;
                let recorded: i64 = row.get(4)?;
                let ptype: String = row.get(5)?;
                let pdata: String = row.get(6)?;
                Ok((event_id, gid, device, schema, recorded, ptype, pdata))
            })?
            .collect::<Result<Vec<_>, _>>()?;

        events
            .into_iter()
            .map(|(eid, gid, dev, schema, rec, pt, pd)| {
                ItemEvent::from_stored(eid, gid, dev, schema, rec, &pt, &pd)
                    .map_err(SyncError::InconsistentData)
            })
            .collect()
    }

    /// Remove a deferred event (after it's been successfully applied or discarded).
    pub fn remove_deferred_event(&self, event_id: &str) -> SyncResult<()> {
        let conn = self.get_conn()?;
        conn.execute(
            "DELETE FROM sync_deferred_events WHERE event_id = ?1",
            params![event_id],
        )?;
        Ok(())
    }

    /// Clear all deferred events (for full resync).
    pub fn clear_deferred_events(&self) -> SyncResult<()> {
        let conn = self.get_conn()?;
        conn.execute("DELETE FROM sync_deferred_events", [])?;
        Ok(())
    }

    /// Count deferred events (to detect if we're stuck).
    pub fn count_deferred_events(&self) -> SyncResult<usize> {
        let conn = self.get_conn()?;
        let count: i64 =
            conn.query_row("SELECT COUNT(*) FROM sync_deferred_events", [], |row| {
                row.get(0)
            })?;
        Ok(count as usize)
    }

    // ── Dedup ────────────────────────────────────────────────────────────

    /// Check if a remote event has already been applied.
    pub fn is_event_applied(&self, event_id: &str) -> SyncResult<bool> {
        let conn = self.get_conn()?;
        let count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM sync_dedup WHERE event_id = ?1",
            params![event_id],
            |row| row.get(0),
        )?;
        Ok(count > 0)
    }

    /// Mark a remote event as applied.
    pub fn mark_event_applied(&self, event_id: &str) -> SyncResult<()> {
        let conn = self.get_conn()?;
        conn.execute(
            "INSERT OR IGNORE INTO sync_dedup (event_id, applied_at) VALUES (?1, ?2)",
            params![event_id, Utc::now().timestamp()],
        )?;
        Ok(())
    }

    /// Clear dedup table (for full resync).
    pub fn clear_dedup(&self) -> SyncResult<()> {
        let conn = self.get_conn()?;
        conn.execute("DELETE FROM sync_dedup", [])?;
        Ok(())
    }

    // ── Device State ─────────────────────────────────────────────────────

    /// Upsert device state.
    pub fn upsert_device_state(
        &self,
        device_id: &str,
        zone_change_token: Option<&[u8]>,
    ) -> SyncResult<()> {
        let now = Utc::now().timestamp();
        let conn = self.get_conn()?;
        conn.execute(
            r#"INSERT INTO sync_device_state
               (device_id, last_zone_change_token, heartbeat_at)
               VALUES (?1, ?2, ?3)
               ON CONFLICT(device_id) DO UPDATE SET
                 last_zone_change_token = COALESCE(excluded.last_zone_change_token, last_zone_change_token),
                 heartbeat_at = excluded.heartbeat_at"#,
            params![device_id, zone_change_token, now],
        )?;
        Ok(())
    }

    /// Fetch the zone change token for a device.
    pub fn fetch_zone_change_token(&self, device_id: &str) -> SyncResult<Option<Vec<u8>>> {
        let conn = self.get_conn()?;
        let result = conn.query_row(
            "SELECT last_zone_change_token FROM sync_device_state WHERE device_id = ?1",
            params![device_id],
            |row| row.get::<_, Option<Vec<u8>>>(0),
        );
        match result {
            Ok(token) => Ok(token),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// Mark the last full resync time for a device.
    pub fn mark_full_resync(&self, device_id: &str) -> SyncResult<()> {
        let now = Utc::now().timestamp();
        let conn = self.get_conn()?;
        conn.execute(
            r#"UPDATE sync_device_state SET last_full_resync_at = ?1, heartbeat_at = ?2
               WHERE device_id = ?3"#,
            params![now, now, device_id],
        )?;
        Ok(())
    }

    // ── Dirty Flags ──────────────────────────────────────────────────────

    /// Get a dirty flag value.
    pub fn get_dirty_flag(&self, flag_name: &str) -> SyncResult<bool> {
        let conn = self.get_conn()?;
        let result = conn.query_row(
            "SELECT flag_value FROM sync_dirty_flags WHERE flag_name = ?1",
            params![flag_name],
            |row| row.get::<_, i64>(0),
        );
        match result {
            Ok(v) => Ok(v != 0),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(false),
            Err(e) => Err(e.into()),
        }
    }

    /// Set a dirty flag.
    pub fn set_dirty_flag(&self, flag_name: &str, value: bool) -> SyncResult<()> {
        let now = Utc::now().timestamp();
        let conn = self.get_conn()?;
        conn.execute(
            r#"INSERT INTO sync_dirty_flags (flag_name, flag_value, updated_at)
               VALUES (?1, ?2, ?3)
               ON CONFLICT(flag_name) DO UPDATE SET
                 flag_value = excluded.flag_value,
                 updated_at = excluded.updated_at"#,
            params![flag_name, value as i64, now],
        )?;
        Ok(())
    }

    // ── Search Index Queue ───────────────────────────────────────────────

    fn enqueue_index_operation(
        &self,
        item_id: &str,
        operation: IndexQueueOperation,
    ) -> SyncResult<()> {
        debug_assert_ne!(operation, IndexQueueOperation::Reset);
        let now = Utc::now().timestamp();
        let conn = self.get_conn()?;
        conn.execute(
            r#"INSERT INTO sync_index_queue (queue_key, operation, item_id, updated_at)
               VALUES (?1, ?2, ?1, ?3)
               ON CONFLICT(queue_key) DO UPDATE SET
                 operation = excluded.operation,
                 item_id = excluded.item_id,
                 updated_at = excluded.updated_at"#,
            params![item_id, operation.as_str(), now],
        )?;
        Ok(())
    }

    pub fn enqueue_index_reset(&self) -> SyncResult<()> {
        let now = Utc::now().timestamp();
        let conn = self.get_conn()?;
        conn.execute(
            r#"INSERT INTO sync_index_queue (queue_key, operation, item_id, updated_at)
               VALUES (?1, ?2, NULL, ?3)
               ON CONFLICT(queue_key) DO UPDATE SET
                 operation = excluded.operation,
                 item_id = excluded.item_id,
                 updated_at = excluded.updated_at"#,
            params![
                INDEX_QUEUE_RESET_KEY,
                IndexQueueOperation::Reset.as_str(),
                now
            ],
        )?;
        Ok(())
    }

    pub fn enqueue_index_upsert(&self, item_id: &str) -> SyncResult<()> {
        self.enqueue_index_operation(item_id, IndexQueueOperation::Upsert)
    }

    pub fn enqueue_index_delete(&self, item_id: &str) -> SyncResult<()> {
        self.enqueue_index_operation(item_id, IndexQueueOperation::Delete)
    }

    pub fn fetch_index_queue(&self, limit: usize) -> SyncResult<Vec<IndexQueueEntry>> {
        if limit == 0 {
            return Ok(Vec::new());
        }

        let conn = self.get_conn()?;
        let mut stmt = conn.prepare(
            r#"SELECT queue_key, operation, item_id
               FROM sync_index_queue
               ORDER BY
                 CASE operation WHEN 'reset' THEN 0 ELSE 1 END,
                 updated_at ASC,
                 queue_key ASC
               LIMIT ?1"#,
        )?;
        let entries = stmt
            .query_map(params![limit as i64], |row| {
                let queue_key: String = row.get(0)?;
                let operation_raw: String = row.get(1)?;
                let item_id: Option<String> = row.get(2)?;
                Ok((queue_key, operation_raw, item_id))
            })?
            .collect::<Result<Vec<_>, _>>()?;

        entries
            .into_iter()
            .map(|(queue_key, operation_raw, item_id)| {
                let operation = IndexQueueOperation::from_str(&operation_raw).ok_or_else(|| {
                    SyncError::InconsistentData(format!(
                        "unknown index queue operation `{operation_raw}`"
                    ))
                })?;
                match operation {
                    IndexQueueOperation::Reset => {
                        if queue_key == INDEX_QUEUE_RESET_KEY && item_id.is_none() {
                            Ok(IndexQueueEntry::Reset)
                        } else {
                            Err(SyncError::InconsistentData(
                                "index queue reset row has item data".to_string(),
                            ))
                        }
                    }
                    IndexQueueOperation::Upsert => item_id
                        .map(|item_id| IndexQueueEntry::Upsert { item_id })
                        .ok_or_else(|| {
                            SyncError::InconsistentData(
                                "index queue upsert row is missing item_id".to_string(),
                            )
                        }),
                    IndexQueueOperation::Delete => item_id
                        .map(|item_id| IndexQueueEntry::Delete { item_id })
                        .ok_or_else(|| {
                            SyncError::InconsistentData(
                                "index queue delete row is missing item_id".to_string(),
                            )
                        }),
                }
            })
            .collect()
    }

    pub fn remove_index_queue_entries(&self, queue_keys: &[&str]) -> SyncResult<usize> {
        if queue_keys.is_empty() {
            return Ok(0);
        }
        let conn = self.get_conn()?;
        let placeholders: Vec<String> = (1..=queue_keys.len()).map(|i| format!("?{i}")).collect();
        let sql = format!(
            "DELETE FROM sync_index_queue WHERE queue_key IN ({})",
            placeholders.join(", ")
        );
        let params: Vec<&dyn rusqlite::ToSql> = queue_keys
            .iter()
            .map(|id| id as &dyn rusqlite::ToSql)
            .collect();
        Ok(conn.execute(&sql, params.as_slice())?)
    }

    pub fn count_index_queue_entries(&self) -> SyncResult<usize> {
        let conn = self.get_conn()?;
        let count: i64 = conn.query_row("SELECT COUNT(*) FROM sync_index_queue", [], |row| {
            row.get(0)
        })?;
        Ok(count as usize)
    }

    pub fn clear_index_queue(&self) -> SyncResult<()> {
        let conn = self.get_conn()?;
        conn.execute("DELETE FROM sync_index_queue", [])?;
        Ok(())
    }

    // ── Bulk Operations (for full resync) ────────────────────────────────

    /// Fetch event IDs that are compacted, uploaded, and older than the given threshold.
    /// These are safe to delete from CloudKit since they've been superseded by snapshots.
    pub fn fetch_purgeable_cloud_event_ids(&self, older_than_unix: i64) -> SyncResult<Vec<String>> {
        let conn = self.get_conn()?;
        let mut stmt = conn.prepare(
            r#"SELECT event_id FROM sync_events
               WHERE compacted = 1 AND uploaded = 1 AND recorded_at < ?1"#,
        )?;
        let ids = stmt
            .query_map(params![older_than_unix], |row| row.get(0))?
            .collect::<Result<Vec<String>, _>>()?;
        Ok(ids)
    }

    /// Delete specific events by their IDs (after CloudKit confirms deletion).
    pub fn delete_events_by_ids(&self, event_ids: &[&str]) -> SyncResult<usize> {
        if event_ids.is_empty() {
            return Ok(0);
        }
        let conn = self.get_conn()?;
        let placeholders: Vec<String> = (1..=event_ids.len()).map(|i| format!("?{i}")).collect();
        let sql = format!(
            "DELETE FROM sync_events WHERE event_id IN ({})",
            placeholders.join(", ")
        );
        let params: Vec<&dyn rusqlite::ToSql> = event_ids
            .iter()
            .map(|id| id as &dyn rusqlite::ToSql)
            .collect();
        let count = conn.execute(&sql, params.as_slice())?;
        Ok(count)
    }

    /// Delete specific events and their dedup markers after CloudKit confirms deletion.
    pub fn delete_events_and_dedup_by_ids(&self, event_ids: &[&str]) -> SyncResult<usize> {
        if event_ids.is_empty() {
            return Ok(0);
        }

        let conn = self.get_conn()?;
        let tx = conn.unchecked_transaction()?;
        let placeholders: Vec<String> = (1..=event_ids.len()).map(|i| format!("?{i}")).collect();
        let event_sql = format!(
            "DELETE FROM sync_events WHERE event_id IN ({})",
            placeholders.join(", ")
        );
        let dedup_sql = format!(
            "DELETE FROM sync_dedup WHERE event_id IN ({})",
            placeholders.join(", ")
        );
        let params: Vec<&dyn rusqlite::ToSql> = event_ids
            .iter()
            .map(|id| id as &dyn rusqlite::ToSql)
            .collect();

        let deleted_events = tx.execute(&event_sql, params.as_slice())?;
        tx.execute(&dedup_sql, params.as_slice())?;
        tx.commit()?;
        Ok(deleted_events)
    }

    /// Clear all sync state except device_state (preserves device_id).
    pub fn clear_sync_state(&self) -> SyncResult<()> {
        let conn = self.get_conn()?;
        conn.execute_batch(
            r#"
            DELETE FROM sync_events;
            DELETE FROM sync_snapshots;
            DELETE FROM sync_projection;
            DELETE FROM sync_deferred_events;
            DELETE FROM sync_dedup;
            DELETE FROM sync_dirty_flags;
            DELETE FROM sync_index_queue;
            "#,
        )?;
        Ok(())
    }
}

/// A row from sync_projection.
#[derive(Debug, Clone, PartialEq)]
pub struct ProjectionEntry {
    pub item_id: String,
    pub state: ProjectionState,
}

/// The sync projection's materialization state at the domain boundary.
#[derive(Debug, Clone, PartialEq)]
pub enum ProjectionState {
    PendingMaterialization { versions: VersionVector },
    Materialized { versions: VersionVector },
    Tombstoned { versions: VersionVector },
}
