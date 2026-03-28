use crate::interface::ItemTag;
use purr_core::database::{Database, DatabaseResult};
use purr_sync::{
    initial_sync_version, new_sync_identifier, next_sync_version, SyncDomain, SyncShadowRow,
    SyncShadowState, SyncVersion,
};
use rusqlite::params;

pub(crate) fn sync_device_id(db: &Database) -> DatabaseResult<String> {
    with_sync_conn(db, sync_device_id_with_conn)
}

#[cfg_attr(not(test), allow(dead_code))]
pub(crate) fn get_sync_shadow_by_item_id(
    db: &Database,
    item_id: i64,
) -> DatabaseResult<Option<SyncShadowRow>> {
    with_sync_conn(db, |conn| get_sync_shadow_by_item_id_with_conn(conn, item_id))
}

pub(crate) fn get_sync_shadow_by_global_id(
    db: &Database,
    global_item_id: &str,
) -> DatabaseResult<Option<SyncShadowRow>> {
    with_sync_conn(db, |conn| {
        get_sync_shadow_by_global_id_with_conn(conn, global_item_id)
    })
}

pub(crate) fn pending_sync_shadows(
    db: &Database,
    limit: usize,
) -> DatabaseResult<Vec<SyncShadowRow>> {
    with_sync_conn(db, |conn| pending_sync_shadows_with_conn(conn, limit))
}

pub(crate) fn backfill_missing_sync_shadows(db: &Database, limit: usize) -> DatabaseResult<usize> {
    with_sync_conn(db, |conn| {
        let device_id = sync_device_id_with_conn(conn)?;
        let mut stmt = conn.prepare(
            r#"
            SELECT items.id
            FROM items
            LEFT JOIN sync_shadow ON sync_shadow.itemId = items.id
            WHERE items.contentType != 'file' AND sync_shadow.itemId IS NULL
            ORDER BY items.timestamp DESC
            LIMIT ?1
            "#,
        )?;
        let item_ids: Vec<i64> = stmt
            .query_map([limit as i64], |row| row.get(0))?
            .collect::<Result<Vec<_>, _>>()?;

        for item_id in &item_ids {
            if let Some(row) = new_backfilled_sync_shadow(conn, *item_id, &device_id)? {
                save_sync_shadow_with_conn(conn, &row)?;
            }
        }

        Ok(item_ids.len())
    })
}

pub(crate) fn stage_local_item_created(db: &Database, item_id: i64) -> DatabaseResult<()> {
    with_sync_conn(db, |conn| {
        let device_id = sync_device_id_with_conn(conn)?;
        if get_sync_shadow_by_item_id_with_conn(conn, item_id)?.is_some() {
            return Ok(());
        }

        if let Some(row) = new_backfilled_sync_shadow(conn, item_id, &device_id)? {
            save_sync_shadow_with_conn(conn, &row)?;
        }
        Ok(())
    })
}

pub(crate) fn stage_local_item_domain_change(
    db: &Database,
    item_id: i64,
    domain: SyncDomain,
) -> DatabaseResult<()> {
    with_sync_conn(db, |conn| {
        let device_id = sync_device_id_with_conn(conn)?;
        let mut row = match get_sync_shadow_by_item_id_with_conn(conn, item_id)? {
            Some(row) => row,
            None => {
                let Some(row) = new_backfilled_sync_shadow(conn, item_id, &device_id)? else {
                    return Ok(());
                };
                row
            }
        };

        match domain {
            SyncDomain::Content => {
                row.content_version = next_sync_version(&row.content_version, &device_id);
            }
            SyncDomain::Bookmark => {
                row.bookmark_version = next_sync_version(&row.bookmark_version, &device_id);
            }
            SyncDomain::Activity => {
                row.activity_version = next_sync_version(&row.activity_version, &device_id);
            }
        }

        row.pending_upload = true;
        row.state = SyncShadowState::Live;
        row.item_id = Some(item_id);
        save_sync_shadow_with_conn(conn, &row)
    })
}

pub(crate) fn stage_local_item_delete(
    db: &Database,
    item_id: i64,
) -> DatabaseResult<Option<SyncShadowRow>> {
    with_sync_conn(db, |conn| {
        let device_id = sync_device_id_with_conn(conn)?;
        let mut row = match get_sync_shadow_by_item_id_with_conn(conn, item_id)? {
            Some(row) => row,
            None => {
                let Some(row) = new_backfilled_sync_shadow(conn, item_id, &device_id)? else {
                    return Ok(None);
                };
                row
            }
        };

        row.delete_version = next_sync_version(&row.delete_version, &device_id);
        row.pending_upload = true;
        row.state = SyncShadowState::Tombstone;
        row.item_id = None;
        save_sync_shadow_with_conn(conn, &row)?;
        Ok(Some(row))
    })
}

pub(crate) fn acknowledge_sync_change_uploaded(
    db: &Database,
    global_item_id: &str,
    record_change_tag: Option<&str>,
) -> DatabaseResult<()> {
    with_sync_conn(db, |conn| {
        conn.execute(
            "UPDATE sync_shadow SET pendingUpload = 0, recordChangeTag = ?1 WHERE globalItemId = ?2",
            params![record_change_tag, global_item_id],
        )?;
        Ok(())
    })
}

pub(crate) fn save_sync_shadow(db: &Database, row: &SyncShadowRow) -> DatabaseResult<()> {
    with_sync_conn(db, |conn| save_sync_shadow_with_conn(conn, row))
}

pub(crate) fn remove_sync_shadow_by_item_ids(
    db: &Database,
    item_ids: &[i64],
) -> DatabaseResult<()> {
    if item_ids.is_empty() {
        return Ok(());
    }

    with_sync_conn(db, |conn| {
        let placeholders = item_ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
        let sql = format!("DELETE FROM sync_shadow WHERE itemId IN ({placeholders})");
        let params: Vec<rusqlite::types::Value> = item_ids.iter().map(|&id| id.into()).collect();
        conn.execute(&sql, rusqlite::params_from_iter(params))?;
        Ok(())
    })
}

pub(crate) fn clear_sync_shadow(db: &Database) -> DatabaseResult<()> {
    with_sync_conn(db, |conn| {
        conn.execute("DELETE FROM sync_shadow", [])?;
        Ok(())
    })
}

fn with_sync_conn<T, F>(db: &Database, f: F) -> DatabaseResult<T>
where
    F: FnOnce(&rusqlite::Connection) -> DatabaseResult<T>,
{
    db.with_connection(|conn| {
        ensure_sync_schema_with_conn(conn)?;
        f(conn)
    })
}

fn ensure_sync_schema_with_conn(conn: &rusqlite::Connection) -> DatabaseResult<()> {
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS sync_shadow (
            globalItemId TEXT PRIMARY KEY,
            itemId INTEGER UNIQUE REFERENCES items(id) ON DELETE SET NULL,
            state TEXT NOT NULL DEFAULT 'live',
            recordChangeTag TEXT,
            pendingUpload INTEGER NOT NULL DEFAULT 1,
            contentCounter INTEGER NOT NULL DEFAULT 0,
            contentDeviceId TEXT NOT NULL DEFAULT '',
            bookmarkCounter INTEGER NOT NULL DEFAULT 0,
            bookmarkDeviceId TEXT NOT NULL DEFAULT '',
            activityCounter INTEGER NOT NULL DEFAULT 0,
            activityDeviceId TEXT NOT NULL DEFAULT '',
            deleteCounter INTEGER NOT NULL DEFAULT 0,
            deleteDeviceId TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS idx_sync_shadow_item ON sync_shadow(itemId);
        CREATE INDEX IF NOT EXISTS idx_sync_shadow_pending ON sync_shadow(pendingUpload, globalItemId);

        CREATE TABLE IF NOT EXISTS sync_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        "#,
    )?;
    Ok(())
}

fn sync_device_id_with_conn(conn: &rusqlite::Connection) -> DatabaseResult<String> {
    let result = conn.query_row(
        "SELECT value FROM sync_state WHERE key = 'device_id'",
        [],
        |row| row.get::<_, String>(0),
    );
    match result {
        Ok(device_id) => Ok(device_id),
        Err(rusqlite::Error::QueryReturnedNoRows) => {
            let device_id = new_sync_identifier();
            conn.execute(
                "INSERT INTO sync_state (key, value) VALUES ('device_id', ?1)",
                params![device_id],
            )?;
            Ok(device_id)
        }
        Err(error) => Err(error.into()),
    }
}

fn row_to_sync_shadow(row: &rusqlite::Row<'_>) -> rusqlite::Result<SyncShadowRow> {
    let state: String = row.get(2)?;
    Ok(SyncShadowRow {
        global_item_id: row.get(0)?,
        item_id: row.get(1)?,
        state: SyncShadowState::from_database_str(&state).map_err(|message| {
            rusqlite::Error::FromSqlConversionFailure(
                2,
                rusqlite::types::Type::Text,
                Box::new(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    message,
                )),
            )
        })?,
        record_change_tag: row.get(3)?,
        pending_upload: row.get::<_, i64>(4)? != 0,
        content_version: SyncVersion {
            counter: row.get(5)?,
            device_id: row.get(6)?,
        },
        bookmark_version: SyncVersion {
            counter: row.get(7)?,
            device_id: row.get(8)?,
        },
        activity_version: SyncVersion {
            counter: row.get(9)?,
            device_id: row.get(10)?,
        },
        delete_version: SyncVersion {
            counter: row.get(11)?,
            device_id: row.get(12)?,
        },
    })
}

fn get_sync_shadow_by_item_id_with_conn(
    conn: &rusqlite::Connection,
    item_id: i64,
) -> DatabaseResult<Option<SyncShadowRow>> {
    let result = conn.query_row(
        r#"
        SELECT globalItemId, itemId, state, recordChangeTag, pendingUpload,
               contentCounter, contentDeviceId,
               bookmarkCounter, bookmarkDeviceId,
               activityCounter, activityDeviceId,
               deleteCounter, deleteDeviceId
        FROM sync_shadow
        WHERE itemId = ?1
        "#,
        [item_id],
        row_to_sync_shadow,
    );
    match result {
        Ok(row) => Ok(Some(row)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(error) => Err(error.into()),
    }
}

fn get_sync_shadow_by_global_id_with_conn(
    conn: &rusqlite::Connection,
    global_item_id: &str,
) -> DatabaseResult<Option<SyncShadowRow>> {
    let result = conn.query_row(
        r#"
        SELECT globalItemId, itemId, state, recordChangeTag, pendingUpload,
               contentCounter, contentDeviceId,
               bookmarkCounter, bookmarkDeviceId,
               activityCounter, activityDeviceId,
               deleteCounter, deleteDeviceId
        FROM sync_shadow
        WHERE globalItemId = ?1
        "#,
        [global_item_id],
        row_to_sync_shadow,
    );
    match result {
        Ok(row) => Ok(Some(row)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(error) => Err(error.into()),
    }
}

fn save_sync_shadow_with_conn(
    conn: &rusqlite::Connection,
    row: &SyncShadowRow,
) -> DatabaseResult<()> {
    conn.execute(
        r#"
        INSERT INTO sync_shadow (
            globalItemId, itemId, state, recordChangeTag, pendingUpload,
            contentCounter, contentDeviceId,
            bookmarkCounter, bookmarkDeviceId,
            activityCounter, activityDeviceId,
            deleteCounter, deleteDeviceId
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
        ON CONFLICT(globalItemId) DO UPDATE SET
            itemId = excluded.itemId,
            state = excluded.state,
            recordChangeTag = excluded.recordChangeTag,
            pendingUpload = excluded.pendingUpload,
            contentCounter = excluded.contentCounter,
            contentDeviceId = excluded.contentDeviceId,
            bookmarkCounter = excluded.bookmarkCounter,
            bookmarkDeviceId = excluded.bookmarkDeviceId,
            activityCounter = excluded.activityCounter,
            activityDeviceId = excluded.activityDeviceId,
            deleteCounter = excluded.deleteCounter,
            deleteDeviceId = excluded.deleteDeviceId
        "#,
        params![
            row.global_item_id,
            row.item_id,
            row.state.database_str(),
            row.record_change_tag,
            if row.pending_upload { 1 } else { 0 },
            row.content_version.counter,
            row.content_version.device_id,
            row.bookmark_version.counter,
            row.bookmark_version.device_id,
            row.activity_version.counter,
            row.activity_version.device_id,
            row.delete_version.counter,
            row.delete_version.device_id,
        ],
    )?;
    Ok(())
}

fn pending_sync_shadows_with_conn(
    conn: &rusqlite::Connection,
    limit: usize,
) -> DatabaseResult<Vec<SyncShadowRow>> {
    let mut stmt = conn.prepare(
        r#"
        SELECT globalItemId, itemId, state, recordChangeTag, pendingUpload,
               contentCounter, contentDeviceId,
               bookmarkCounter, bookmarkDeviceId,
               activityCounter, activityDeviceId,
               deleteCounter, deleteDeviceId
        FROM sync_shadow
        WHERE pendingUpload = 1
        ORDER BY globalItemId
        LIMIT ?1
        "#,
    )?;
    let rows = stmt
        .query_map([limit as i64], row_to_sync_shadow)?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

fn new_backfilled_sync_shadow(
    conn: &rusqlite::Connection,
    item_id: i64,
    device_id: &str,
) -> DatabaseResult<Option<SyncShadowRow>> {
    let content_type = match conn.query_row(
        "SELECT contentType FROM items WHERE id = ?1",
        [item_id],
        |row| row.get::<_, String>(0),
    ) {
        Ok(value) => value,
        Err(rusqlite::Error::QueryReturnedNoRows) => return Ok(None),
        Err(error) => return Err(error.into()),
    };

    if content_type == "file" {
        return Ok(None);
    }

    let bookmark_exists: i64 = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM item_tags WHERE itemId = ?1 AND tag = ?2)",
        params![item_id, ItemTag::Bookmark.database_str()],
        |row| row.get(0),
    )?;
    let is_bookmarked = bookmark_exists != 0;

    Ok(Some(SyncShadowRow {
        global_item_id: new_sync_identifier(),
        item_id: Some(item_id),
        state: SyncShadowState::Live,
        record_change_tag: None,
        pending_upload: true,
        content_version: initial_sync_version(device_id, 1),
        bookmark_version: initial_sync_version(device_id, if is_bookmarked { 1 } else { 0 }),
        activity_version: initial_sync_version(device_id, 1),
        delete_version: initial_sync_version(device_id, 0),
    }))
}
