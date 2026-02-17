//! SQLite database layer for clipboard storage
//!
//! Normalized schema: base `items` table + type-specific child tables.
//! Uses r2d2 connection pooling to allow concurrent reads without mutex blocking.

use crate::interface::{
    ClipboardContent, ContentTypeFilter, FileEntry, FileStatus, ItemMetadata, ItemIcon,
    LinkMetadataState,
};
use crate::models::StoredItem;
use crate::search::{generate_preview, SNIPPET_CONTEXT_CHARS};
use chrono::{DateTime, TimeZone, Utc};
use r2d2::{Pool, PooledConnection};
use r2d2_sqlite::SqliteConnectionManager;
use rusqlite::params;
use std::path::Path;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum DatabaseError {
    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("Database not initialized")]
    NotInitialized,
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("Connection pool error: {0}")]
    Pool(#[from] r2d2::Error),
}

pub type DatabaseResult<T> = Result<T, DatabaseError>;

/// Parse timestamp string from database to DateTime<Utc>
fn parse_db_timestamp(timestamp_str: &str) -> DateTime<Utc> {
    chrono::NaiveDateTime::parse_from_str(timestamp_str, "%Y-%m-%d %H:%M:%S%.f")
        .or_else(|_| chrono::NaiveDateTime::parse_from_str(timestamp_str, "%Y-%m-%d %H:%M:%S"))
        .map(|dt| Utc.from_utc_datetime(&dt))
        .unwrap_or_else(|_| Utc::now())
}

/// Thread-safe database wrapper using connection pooling
///
/// Uses r2d2 connection pool for concurrent read access.
/// WAL mode enables readers to proceed without blocking each other.
pub struct Database {
    pool: Pool<SqliteConnectionManager>,
}

impl Database {
    /// Open or create a database at the given path with connection pooling
    pub fn open<P: AsRef<Path>>(path: P) -> DatabaseResult<Self> {
        let manager = SqliteConnectionManager::file(path)
            .with_init(|conn| {
                conn.execute_batch("
                    PRAGMA journal_mode=WAL;
                    PRAGMA synchronous=NORMAL;
                    PRAGMA foreign_keys=ON;
                    PRAGMA mmap_size=67108864;
                    PRAGMA cache_size=-32000;
                ")?;
                Ok(())
            });

        let pool = Pool::builder()
            .max_size(8)
            .build(manager)?;

        let db = Self { pool };
        db.setup_schema()?;
        Ok(db)
    }

    /// Open an in-memory database (for testing)
    #[cfg(test)]
    pub fn open_in_memory() -> DatabaseResult<Self> {
        let manager = SqliteConnectionManager::memory()
            .with_init(|conn| {
                conn.execute_batch("
                    PRAGMA journal_mode=WAL;
                    PRAGMA synchronous=NORMAL;
                    PRAGMA foreign_keys=ON;
                ")?;
                Ok(())
            });

        // In-memory needs single connection to maintain state
        let pool = Pool::builder()
            .max_size(1)
            .build(manager)?;

        let db = Self { pool };
        db.setup_schema()?;
        Ok(db)
    }

    /// Get a connection from the pool
    fn get_conn(&self) -> DatabaseResult<PooledConnection<SqliteConnectionManager>> {
        Ok(self.pool.get()?)
    }

    /// Set up the database schema (normalized: items + child tables)
    fn setup_schema(&self) -> DatabaseResult<()> {
        let conn = self.get_conn()?;

        // Migration: detect old schema by checking for `imageData` column in items
        let has_old_schema = conn
            .prepare("SELECT imageData FROM items LIMIT 0")
            .is_ok();

        if has_old_schema {
            Self::migrate_from_old_schema(&conn)?;
            return Ok(());
        }

        conn.execute_batch(r#"
            CREATE TABLE IF NOT EXISTS items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                contentType TEXT NOT NULL,
                contentHash TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp TEXT NOT NULL,
                sourceApp TEXT,
                sourceAppBundleId TEXT,
                thumbnail BLOB,
                colorRgba INTEGER
            );

            CREATE TABLE IF NOT EXISTS text_items (
                itemId INTEGER PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS image_items (
                itemId INTEGER PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
                data BLOB NOT NULL,
                description TEXT NOT NULL DEFAULT 'Image'
            );

            CREATE TABLE IF NOT EXISTS link_items (
                itemId INTEGER PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
                url TEXT NOT NULL,
                title TEXT,
                description TEXT
            );

            CREATE TABLE IF NOT EXISTS file_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                itemId INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL DEFAULT 0,
                path TEXT NOT NULL,
                filename TEXT NOT NULL,
                fileSize INTEGER NOT NULL DEFAULT 0,
                uti TEXT NOT NULL DEFAULT 'public.item',
                bookmarkData BLOB NOT NULL,
                fileStatus TEXT NOT NULL DEFAULT 'available'
            );

            CREATE INDEX IF NOT EXISTS idx_items_hash ON items(contentHash);
            CREATE INDEX IF NOT EXISTS idx_items_timestamp ON items(timestamp);
            CREATE INDEX IF NOT EXISTS idx_items_content_prefix ON items(content COLLATE NOCASE);
            CREATE INDEX IF NOT EXISTS idx_file_items_item ON file_items(itemId);
        "#)?;

        Ok(())
    }

    /// Migrate from the old flat schema (single `items` table with imageData, linkTitle, etc.)
    /// to the normalized schema (base `items` + child tables). Preserves all data.
    fn migrate_from_old_schema(conn: &rusqlite::Connection) -> DatabaseResult<()> {
        use base64::Engine;

        // Disable FK enforcement and prevent SQLite from auto-updating FK references
        // when we rename `items` → `items_old` (standard SQLite schema migration pattern)
        conn.execute_batch("PRAGMA foreign_keys = OFF; PRAGMA legacy_alter_table = ON")?;

        // Ensure optional columns exist (may be missing in very old DBs).
        // ALTER TABLE ADD COLUMN is a no-op error if the column already exists.
        for (col, typ) in [("linkDescription", "TEXT"), ("thumbnail", "BLOB"), ("colorRgba", "INTEGER")] {
            let _ = conn.execute_batch(&format!("ALTER TABLE items ADD COLUMN {} {}", col, typ));
        }

        // Check which optional column sets exist
        let has_file_columns = conn.prepare("SELECT filePath FROM items LIMIT 0").is_ok();
        let has_additional_files = has_file_columns
            && conn.prepare("SELECT additionalFiles FROM items LIMIT 0").is_ok();

        // Pre-read file data that needs Rust-side processing (path→filename, JSON parsing)
        let file_items: Vec<(i64, String, i64, String, Vec<u8>, String)> = if has_file_columns {
            let mut stmt = conn.prepare(
                "SELECT id, COALESCE(filePath,''), COALESCE(fileSize,0), COALESCE(fileUti,'public.item'), COALESCE(bookmarkData,X''), COALESCE(fileStatus,'available') FROM items WHERE contentType = 'file' AND filePath IS NOT NULL"
            )?;
            let rows = stmt.query_map([], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?))
            })?.collect::<Result<Vec<_>, _>>()?;
            rows
        } else {
            Vec::new()
        };

        let multi_file_items: Vec<(i64, String)> = if has_additional_files {
            let mut stmt = conn.prepare(
                "SELECT id, additionalFiles FROM items WHERE contentType = 'file' AND additionalFiles IS NOT NULL AND additionalFiles != ''"
            )?;
            let rows = stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
                .collect::<Result<Vec<_>, _>>()?;
            rows
        } else {
            Vec::new()
        };

        // Run the entire migration in a transaction
        let tx = conn.unchecked_transaction()?;

        // 1. Create child tables
        tx.execute_batch(r#"
            CREATE TABLE text_items (
                itemId INTEGER PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
                value TEXT NOT NULL
            );
            CREATE TABLE image_items (
                itemId INTEGER PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
                data BLOB NOT NULL,
                description TEXT NOT NULL DEFAULT 'Image'
            );
            CREATE TABLE link_items (
                itemId INTEGER PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
                url TEXT NOT NULL,
                title TEXT,
                description TEXT
            );
            CREATE TABLE file_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                itemId INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL DEFAULT 0,
                path TEXT NOT NULL,
                filename TEXT NOT NULL,
                fileSize INTEGER NOT NULL DEFAULT 0,
                uti TEXT NOT NULL DEFAULT 'public.item',
                bookmarkData BLOB NOT NULL,
                fileStatus TEXT NOT NULL DEFAULT 'available'
            );
        "#)?;

        // 2. Bulk-migrate text/color/email/phone → text_items
        tx.execute(
            "INSERT INTO text_items (itemId, value) SELECT id, content FROM items WHERE contentType IN ('text','email','phone','color') OR contentType IS NULL",
            [],
        )?;

        // 3. Bulk-migrate images → image_items
        tx.execute(
            "INSERT INTO image_items (itemId, data, description) SELECT id, imageData, content FROM items WHERE contentType = 'image' AND imageData IS NOT NULL",
            [],
        )?;

        // 4. Bulk-migrate links → link_items
        tx.execute(
            "INSERT INTO link_items (itemId, url, title, description) SELECT id, content, linkTitle, linkDescription FROM items WHERE contentType = 'link'",
            [],
        )?;

        // 5. Copy link preview images to the unified thumbnail column
        tx.execute(
            "UPDATE items SET thumbnail = linkImageData WHERE contentType = 'link' AND linkImageData IS NOT NULL AND thumbnail IS NULL",
            [],
        )?;

        // 6. Migrate primary file entries
        for (id, path, file_size, uti, bookmark_data, file_status) in &file_items {
            let filename = std::path::Path::new(path)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or(path)
                .to_string();
            tx.execute(
                "INSERT INTO file_items (itemId, ordinal, path, filename, fileSize, uti, bookmarkData, fileStatus) VALUES (?1, 0, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![id, path, filename, file_size, uti, bookmark_data, file_status],
            )?;
        }

        // 7. Migrate additional files from JSON (multi-file items)
        for (item_id, json_str) in &multi_file_items {
            if let Ok(files) = serde_json::from_str::<Vec<serde_json::Value>>(json_str) {
                for (i, file) in files.iter().enumerate() {
                    let path = file.get("path").and_then(|v| v.as_str()).unwrap_or("");
                    let filename = file.get("filename").and_then(|v| v.as_str()).unwrap_or("");
                    let file_size = file.get("fileSize").and_then(|v| v.as_u64()).unwrap_or(0) as i64;
                    let uti = file.get("uti").and_then(|v| v.as_str()).unwrap_or("public.item");
                    let bookmark_b64 = file.get("bookmarkData").and_then(|v| v.as_str()).unwrap_or("");
                    let bookmark_data = base64::engine::general_purpose::STANDARD
                        .decode(bookmark_b64)
                        .unwrap_or_default();

                    tx.execute(
                        "INSERT INTO file_items (itemId, ordinal, path, filename, fileSize, uti, bookmarkData, fileStatus) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'available')",
                        params![*item_id, (i + 1) as i64, path, filename, file_size, uti, bookmark_data],
                    )?;
                }
            }
        }

        // 8. Rename old table → create new schema → copy data → drop old
        tx.execute_batch("ALTER TABLE items RENAME TO items_old")?;

        tx.execute_batch(r#"
            CREATE TABLE items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                contentType TEXT NOT NULL,
                contentHash TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp TEXT NOT NULL,
                sourceApp TEXT,
                sourceAppBundleId TEXT,
                thumbnail BLOB,
                colorRgba INTEGER
            )
        "#)?;

        // Copy data, converting email/phone contentType → 'text'
        tx.execute(
            r#"INSERT INTO items (id, contentType, contentHash, content, timestamp, sourceApp, sourceAppBundleId, thumbnail, colorRgba)
               SELECT id,
                      CASE WHEN contentType IN ('email', 'phone') THEN 'text'
                           ELSE COALESCE(contentType, 'text') END,
                      contentHash, content, timestamp, sourceApp, sourceAppBundleID, thumbnail, colorRgba
               FROM items_old"#,
            [],
        )?;

        tx.execute_batch("DROP TABLE items_old")?;

        // 9. Create indexes
        tx.execute_batch(r#"
            CREATE INDEX idx_items_hash ON items(contentHash);
            CREATE INDEX idx_items_timestamp ON items(timestamp);
            CREATE INDEX idx_items_content_prefix ON items(content COLLATE NOCASE);
            CREATE INDEX idx_file_items_item ON file_items(itemId);
        "#)?;

        tx.commit()?;

        // Restore normal behavior
        conn.execute_batch("PRAGMA foreign_keys = ON; PRAGMA legacy_alter_table = OFF")?;

        Ok(())
    }

    /// Get the database size in bytes
    pub fn database_size(&self) -> DatabaseResult<i64> {
        let conn = self.get_conn()?;
        let page_count: i64 = conn.query_row("PRAGMA page_count", [], |row| row.get(0))?;
        let page_size: i64 = conn.query_row("PRAGMA page_size", [], |row| row.get(0))?;
        Ok(page_count * page_size)
    }

    /// Get total number of items in the database
    pub fn count_items(&self) -> DatabaseResult<u64> {
        let conn = self.get_conn()?;
        let count: i64 = conn.query_row("SELECT COUNT(*) FROM items", [], |row| row.get(0))?;
        Ok(count as u64)
    }

    /// Insert a new clipboard item using a transaction.
    /// Inserts into `items` + the appropriate child table(s).
    /// Returns the item ID.
    pub fn insert_item(&self, item: &StoredItem) -> DatabaseResult<i64> {
        let conn = self.get_conn()?;
        let tx = conn.unchecked_transaction()?;

        let timestamp = Utc.timestamp_opt(item.timestamp_unix, 0).single().unwrap_or_else(Utc::now);
        let timestamp_str = timestamp.format("%Y-%m-%d %H:%M:%S%.f").to_string();
        let content_type = item.content.database_type();
        let content_text = item.content.text_content().to_string();

        tx.execute(
            r#"INSERT INTO items (contentType, contentHash, content, timestamp, sourceApp, sourceAppBundleId, thumbnail, colorRgba)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)"#,
            params![
                content_type,
                item.content_hash,
                content_text,
                timestamp_str,
                item.source_app,
                item.source_app_bundle_id,
                item.thumbnail,
                item.color_rgba,
            ],
        )?;
        let item_id = tx.last_insert_rowid();

        match &item.content {
            ClipboardContent::Text { value }
            | ClipboardContent::Color { value } => {
                tx.execute(
                    "INSERT INTO text_items (itemId, value) VALUES (?1, ?2)",
                    params![item_id, value],
                )?;
            }
            ClipboardContent::Image { data, description } => {
                tx.execute(
                    "INSERT INTO image_items (itemId, data, description) VALUES (?1, ?2, ?3)",
                    params![item_id, data, description],
                )?;
            }
            ClipboardContent::Link { url, metadata_state } => {
                let (title, description, image_data) = metadata_state.to_database_fields();
                // Store link preview image as items.thumbnail
                if image_data.is_some() {
                    tx.execute(
                        "UPDATE items SET thumbnail = ?1 WHERE id = ?2",
                        params![image_data, item_id],
                    )?;
                }
                tx.execute(
                    "INSERT INTO link_items (itemId, url, title, description) VALUES (?1, ?2, ?3, ?4)",
                    params![item_id, url, title, description],
                )?;
            }
            ClipboardContent::File { files, .. } => {
                for (ordinal, file) in files.iter().enumerate() {
                    tx.execute(
                        r#"INSERT INTO file_items (itemId, ordinal, path, filename, fileSize, uti, bookmarkData, fileStatus)
                           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)"#,
                        params![
                            item_id,
                            ordinal as i64,
                            file.path,
                            file.filename,
                            file.file_size as i64,
                            file.uti,
                            file.bookmark_data,
                            file.file_status.to_database_str(),
                        ],
                    )?;
                }
            }
        }

        tx.commit()?;
        Ok(item_id)
    }

    /// Find an existing item by content hash
    pub fn find_by_hash(&self, hash: &str) -> DatabaseResult<Option<StoredItem>> {
        let conn = self.get_conn()?;
        let result = conn.query_row(
            "SELECT id, contentType, contentHash, content, timestamp, sourceApp, sourceAppBundleId, thumbnail, colorRgba FROM items WHERE contentHash = ?1 LIMIT 1",
            [hash],
            |row| Self::row_to_base_item(row),
        );

        match result {
            Ok(mut item) => {
                if let Some(id) = item.id {
                    Self::populate_child_content(&conn, &mut item, id)?;
                }
                Ok(Some(item))
            }
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// Update the timestamp of an existing item
    pub fn update_timestamp(&self, id: i64, timestamp: DateTime<Utc>) -> DatabaseResult<()> {
        let conn = self.get_conn()?;
        let timestamp_str = timestamp.format("%Y-%m-%d %H:%M:%S%.f").to_string();
        conn.execute(
            "UPDATE items SET timestamp = ?1 WHERE id = ?2",
            params![timestamp_str, id],
        )?;
        Ok(())
    }

    /// Update link metadata for an item.
    /// Updates `link_items` (title, description) and `items.thumbnail` (image).
    pub fn update_link_metadata(
        &self,
        id: i64,
        title: Option<&str>,
        description: Option<&str>,
        image_data: Option<&[u8]>,
    ) -> DatabaseResult<()> {
        let conn = self.get_conn()?;
        conn.execute(
            "UPDATE link_items SET title = ?1, description = ?2 WHERE itemId = ?3",
            params![title.unwrap_or(""), description, id],
        )?;
        // Store link preview image as items.thumbnail
        conn.execute(
            "UPDATE items SET thumbnail = ?1 WHERE id = ?2",
            params![image_data, id],
        )?;
        Ok(())
    }

    /// Update image description
    pub fn update_image_description(&self, id: i64, description: &str) -> DatabaseResult<()> {
        let conn = self.get_conn()?;
        // Update both the denormalized content in items and the child table
        conn.execute(
            "UPDATE items SET content = ?1 WHERE id = ?2 AND contentType = 'image'",
            params![description, id],
        )?;
        conn.execute(
            "UPDATE image_items SET description = ?1 WHERE itemId = ?2",
            params![description, id],
        )?;
        Ok(())
    }

    /// Update file status for a specific file entry.
    /// `file_item_id` is the `file_items.id` — each file has its own status.
    pub fn update_file_status(&self, file_item_id: i64, status: &str, new_path: Option<&str>) -> DatabaseResult<()> {
        let conn = self.get_conn()?;
        if let Some(path) = new_path {
            conn.execute(
                "UPDATE file_items SET fileStatus = ?1, path = ?2 WHERE id = ?3",
                params![status, path, file_item_id],
            )?;
        } else {
            conn.execute(
                "UPDATE file_items SET fileStatus = ?1 WHERE id = ?2",
                params![status, file_item_id],
            )?;
        }
        Ok(())
    }

    /// Delete an item by ID (CASCADE handles child tables)
    pub fn delete_item(&self, id: i64) -> DatabaseResult<()> {
        let conn = self.get_conn()?;
        conn.execute("DELETE FROM items WHERE id = ?1", [id])?;
        Ok(())
    }

    /// Delete all items (CASCADE handles children)
    pub fn clear_all(&self) -> DatabaseResult<()> {
        let conn = self.get_conn()?;
        conn.execute("DELETE FROM items", [])?;
        Ok(())
    }

    /// Fetch lightweight item metadata for list display.
    /// No JOINs needed — `thumbnail` covers link images too.
    pub fn fetch_item_metadata(
        &self,
        before_timestamp: Option<DateTime<Utc>>,
        limit: usize,
        filter: Option<&ContentTypeFilter>,
    ) -> DatabaseResult<(Vec<ItemMetadata>, u64)> {
        let conn = self.get_conn()?;

        let type_filter_clause = Self::content_type_where_clause(filter, "");
        let type_filter_clause_and = Self::content_type_where_clause(filter, "AND");

        let count_sql = format!("SELECT COUNT(*) FROM items {}", type_filter_clause);
        let total_count: i64 = conn.query_row(&count_sql, [], |row| row.get(0))?;
        let total_count = total_count as u64;

        let sql = if before_timestamp.is_some() {
            format!(
                r#"SELECT id, content, contentType, timestamp, sourceApp, sourceAppBundleId, thumbnail, colorRgba
                   FROM items WHERE timestamp < ?1 {} ORDER BY timestamp DESC LIMIT ?2"#,
                type_filter_clause_and
            )
        } else {
            format!(
                r#"SELECT id, content, contentType, timestamp, sourceApp, sourceAppBundleId, thumbnail, colorRgba
                   FROM items {} ORDER BY timestamp DESC LIMIT ?1"#,
                type_filter_clause
            )
        };

        let mut stmt = conn.prepare(&sql)?;
        let items = if let Some(ts) = before_timestamp {
            let ts_str = ts.format("%Y-%m-%d %H:%M:%S%.f").to_string();
            stmt.query_map(params![ts_str, limit as i64], Self::row_to_metadata)?
                .collect::<Result<Vec<_>, _>>()?
        } else {
            stmt.query_map(params![limit as i64], Self::row_to_metadata)?
                .collect::<Result<Vec<_>, _>>()?
        };

        Ok((items, total_count))
    }

    /// Fetch items by IDs, preserving the order of the input IDs
    pub fn fetch_items_by_ids(&self, ids: &[i64]) -> DatabaseResult<Vec<StoredItem>> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }

        let conn = self.get_conn()?;
        let placeholders = ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
        let sql = format!(
            "SELECT id, contentType, contentHash, content, timestamp, sourceApp, sourceAppBundleId, thumbnail, colorRgba FROM items WHERE id IN ({})",
            placeholders
        );

        let mut stmt = conn.prepare(&sql)?;
        let params: Vec<rusqlite::types::Value> = ids.iter().map(|&id| id.into()).collect();
        let mut items: Vec<StoredItem> = stmt
            .query_map(rusqlite::params_from_iter(params), Self::row_to_base_item)?
            .collect::<Result<Vec<_>, _>>()?;

        // Populate child content for each item
        for item in &mut items {
            if let Some(id) = item.id {
                Self::populate_child_content(&conn, item, id)?;
            }
        }

        // Re-sort to match input ID order
        let id_to_item: std::collections::HashMap<i64, StoredItem> = items
            .into_iter()
            .filter_map(|item| item.id.map(|id| (id, item)))
            .collect();

        Ok(ids.iter().filter_map(|id| id_to_item.get(id).cloned()).collect())
    }

    /// Fetch items by IDs with SQLite C-level interrupt support.
    pub fn fetch_items_by_ids_interruptible(
        &self,
        ids: &[i64],
        token: &tokio_util::sync::CancellationToken,
        runtime: &tokio::runtime::Handle,
    ) -> DatabaseResult<Vec<StoredItem>> {
        use tokio_util::task::AbortOnDropHandle;

        if ids.is_empty() {
            return Ok(Vec::new());
        }

        let conn = self.get_conn()?;
        let interrupt_handle = conn.get_interrupt_handle();

        let token_clone = token.clone();
        let watcher = runtime.spawn(async move {
            token_clone.cancelled().await;
            interrupt_handle.interrupt();
        });
        let _abort_guard = AbortOnDropHandle::new(watcher);

        let placeholders = ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
        let sql = format!(
            "SELECT id, contentType, contentHash, content, timestamp, sourceApp, sourceAppBundleId, thumbnail, colorRgba FROM items WHERE id IN ({})",
            placeholders
        );

        let mut stmt = conn.prepare(&sql)?;
        let params: Vec<rusqlite::types::Value> = ids.iter().map(|&id| id.into()).collect();

        let mut items: Vec<StoredItem> = match stmt.query_map(rusqlite::params_from_iter(params), Self::row_to_base_item) {
            Ok(rows) => rows.collect::<Result<Vec<_>, _>>()?,
            Err(rusqlite::Error::SqliteFailure(err, _)) if err.code == rusqlite::ffi::ErrorCode::OperationInterrupted => {
                return Ok(Vec::new());
            }
            Err(e) => return Err(e.into()),
        };

        // Populate child content
        for item in &mut items {
            if let Some(id) = item.id {
                Self::populate_child_content(&conn, item, id)?;
            }
        }

        // Re-sort to match input ID order
        let id_to_item: std::collections::HashMap<i64, StoredItem> = items
            .into_iter()
            .filter_map(|item| item.id.map(|id| (id, item)))
            .collect();

        Ok(ids.iter().filter_map(|id| id_to_item.get(id).cloned()).collect())
    }

    /// Fetch all items (for index rebuilding)
    pub fn fetch_all_items(&self) -> DatabaseResult<Vec<StoredItem>> {
        let conn = self.get_conn()?;
        let mut stmt = conn.prepare(
            "SELECT id, contentType, contentHash, content, timestamp, sourceApp, sourceAppBundleId, thumbnail, colorRgba FROM items ORDER BY timestamp DESC"
        )?;
        let mut items = stmt
            .query_map([], Self::row_to_base_item)?
            .collect::<Result<Vec<_>, _>>()?;

        // Populate child content
        for item in &mut items {
            if let Some(id) = item.id {
                Self::populate_child_content(&conn, item, id)?;
            }
        }

        Ok(items)
    }

    /// Get IDs that would be pruned (for index deletion before database prune)
    pub fn get_prunable_ids(&self, max_bytes: i64, keep_ratio: f64) -> DatabaseResult<Vec<i64>> {
        let current_size = self.database_size()?;
        if current_size <= max_bytes {
            return Ok(Vec::new());
        }

        let conn = self.get_conn()?;

        let count: i64 = conn.query_row("SELECT COUNT(*) FROM items", [], |row| row.get(0))?;
        if count == 0 {
            return Ok(Vec::new());
        }

        let avg_item_size = current_size / count;
        if avg_item_size == 0 {
            return Ok(Vec::new());
        }
        let target_size = (max_bytes as f64 * keep_ratio) as i64;
        let items_to_delete = std::cmp::max(100, ((current_size - target_size) / avg_item_size) as usize);

        let mut stmt = conn.prepare("SELECT id FROM items ORDER BY timestamp ASC LIMIT ?1")?;
        let ids: Vec<i64> = stmt
            .query_map([items_to_delete as i64], |row| row.get(0))?
            .collect::<Result<Vec<_>, _>>()?;

        Ok(ids)
    }

    /// Search for short queries (<3 chars) using prefix matching + substring LIKE on recent items.
    pub fn search_short_query(
        &self,
        query: &str,
        limit: usize,
        filter: Option<&ContentTypeFilter>,
    ) -> DatabaseResult<Vec<(i64, String, i64)>> {
        let conn = self.get_conn()?;
        let query_lower = query.to_lowercase();
        let escaped = query_lower.replace('%', "\\%").replace('_', "\\_");
        let type_filter_and = Self::content_type_where_clause(filter, "AND");

        // Part 1: Prefix match
        let prefix_pattern = format!("{}%", escaped);
        let prefix_sql = format!(
            r#"SELECT id, content, CAST(strftime('%s', timestamp) AS INTEGER)
               FROM items
               WHERE content LIKE ?1 ESCAPE '\' COLLATE NOCASE {}
               ORDER BY timestamp DESC
               LIMIT ?2"#,
            type_filter_and
        );
        let mut stmt_prefix = conn.prepare(&prefix_sql)?;
        let prefix_results: Vec<(i64, String, i64)> = stmt_prefix
            .query_map(params![prefix_pattern, limit as i64], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;

        // Part 2: Substring LIKE on last 2k items
        let like_pattern = format!("%{}%", escaped);
        let like_sql = format!(
            r#"SELECT id, content, CAST(strftime('%s', timestamp) AS INTEGER)
               FROM (SELECT id, content, contentType, timestamp FROM items ORDER BY timestamp DESC LIMIT 2000)
               WHERE content LIKE ?1 ESCAPE '\' COLLATE NOCASE {}
               ORDER BY timestamp DESC
               LIMIT ?2"#,
            type_filter_and
        );
        let mut stmt_like = conn.prepare(&like_sql)?;
        let like_results: Vec<(i64, String, i64)> = stmt_like
            .query_map(params![like_pattern, limit as i64], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;

        // Merge, deduplicate
        let mut seen_ids = std::collections::HashSet::new();
        let mut results = Vec::with_capacity(limit);

        for item in prefix_results {
            if seen_ids.insert(item.0) {
                results.push(item);
            }
        }

        for item in like_results {
            if results.len() >= limit {
                break;
            }
            if seen_ids.insert(item.0) {
                results.push(item);
            }
        }

        Ok(results)
    }

    /// Prune old items to stay under max size (CASCADE handles children)
    pub fn prune_to_size(&self, max_bytes: i64, keep_ratio: f64) -> DatabaseResult<usize> {
        let current_size = self.database_size()?;
        if current_size <= max_bytes {
            return Ok(0);
        }

        let conn = self.get_conn()?;

        let count: i64 = conn.query_row("SELECT COUNT(*) FROM items", [], |row| row.get(0))?;
        if count == 0 {
            return Ok(0);
        }

        let avg_item_size = current_size / count;
        if avg_item_size == 0 {
            return Ok(0);
        }
        let target_size = (max_bytes as f64 * keep_ratio) as i64;
        let items_to_delete = std::cmp::max(100, ((current_size - target_size) / avg_item_size) as usize);

        conn.execute(
            r#"DELETE FROM items WHERE id IN (
                SELECT id FROM items ORDER BY timestamp ASC LIMIT ?1
            )"#,
            [items_to_delete as i64],
        )?;

        Ok(items_to_delete)
    }

    /// Build a SQL clause for filtering by content type.
    fn content_type_where_clause(filter: Option<&ContentTypeFilter>, prefix: &str) -> String {
        let types = match filter {
            Some(f) => f.database_types(),
            None => None,
        };
        match types {
            None => String::new(),
            Some(types) => {
                let quoted: Vec<String> = types.iter().map(|t| format!("'{}'", t)).collect();
                let keyword = if prefix.is_empty() { "WHERE" } else { prefix };
                format!("{} contentType IN ({})", keyword, quoted.join(","))
            }
        }
    }

    /// Read base item fields from a row (no child table data yet).
    /// Content is populated with a placeholder — call `populate_child_content` after.
    fn row_to_base_item(row: &rusqlite::Row) -> rusqlite::Result<StoredItem> {
        let id: i64 = row.get(0)?;
        let content_type: String = row.get(1)?;
        let content_hash: String = row.get(2)?;
        let content_text: String = row.get(3)?;
        let timestamp_str: String = row.get(4)?;
        let source_app: Option<String> = row.get(5)?;
        let source_app_bundle_id: Option<String> = row.get(6)?;
        let thumbnail: Option<Vec<u8>> = row.get(7)?;
        let color_rgba: Option<u32> = row.get(8)?;

        let timestamp = parse_db_timestamp(&timestamp_str);

        // Placeholder content — will be replaced by populate_child_content
        let content = match content_type.as_str() {
            "color" => ClipboardContent::Color { value: content_text },
            "image" => ClipboardContent::Image { data: Vec::new(), description: content_text },
            "link" => ClipboardContent::Link {
                url: content_text,
                metadata_state: LinkMetadataState::Pending,
            },
            "file" => ClipboardContent::File {
                display_name: content_text,
                files: Vec::new(),
            },
            _ => ClipboardContent::Text { value: content_text },
        };

        Ok(StoredItem {
            id: Some(id),
            content,
            content_hash,
            timestamp_unix: timestamp.timestamp(),
            source_app,
            source_app_bundle_id,
            thumbnail,
            color_rgba,
        })
    }

    /// Populate the child table content for a StoredItem.
    /// Must be called after `row_to_base_item` to fill in type-specific data.
    fn populate_child_content(conn: &rusqlite::Connection, item: &mut StoredItem, item_id: i64) -> DatabaseResult<()> {
        match &item.content {
            ClipboardContent::Image { description, .. } => {
                let description = description.clone();
                let data: Vec<u8> = conn.query_row(
                    "SELECT data FROM image_items WHERE itemId = ?1",
                    [item_id],
                    |row| row.get(0),
                ).unwrap_or_default();
                item.content = ClipboardContent::Image { data, description };
            }
            ClipboardContent::Link { url, .. } => {
                let url = url.clone();
                let result = conn.query_row(
                    "SELECT title, description FROM link_items WHERE itemId = ?1",
                    [item_id],
                    |row| {
                        let title: Option<String> = row.get(0)?;
                        let desc: Option<String> = row.get(1)?;
                        Ok((title, desc))
                    },
                );
                let metadata_state = match result {
                    Ok((title, desc)) => {
                        // Reconstruct from link_items + items.thumbnail for image
                        LinkMetadataState::from_database(
                            title.as_deref(),
                            desc.as_deref(),
                            item.thumbnail.clone(),
                        )
                    }
                    Err(_) => LinkMetadataState::Pending,
                };
                item.content = ClipboardContent::Link { url, metadata_state };
            }
            ClipboardContent::File { display_name, .. } => {
                let display_name = display_name.clone();
                let mut stmt = conn.prepare(
                    "SELECT id, path, filename, fileSize, uti, bookmarkData, fileStatus FROM file_items WHERE itemId = ?1 ORDER BY ordinal"
                )?;
                let files: Vec<FileEntry> = stmt
                    .query_map([item_id], |row| {
                        let file_item_id: i64 = row.get(0)?;
                        let path: String = row.get(1)?;
                        let filename: String = row.get(2)?;
                        let file_size: i64 = row.get(3)?;
                        let uti: String = row.get(4)?;
                        let bookmark_data: Vec<u8> = row.get(5)?;
                        let file_status_str: String = row.get(6)?;
                        Ok(FileEntry {
                            file_item_id,
                            path,
                            filename,
                            file_size: file_size as u64,
                            uti,
                            bookmark_data,
                            file_status: FileStatus::from_database_str(&file_status_str),
                        })
                    })?
                    .collect::<Result<Vec<_>, _>>()?;
                item.content = ClipboardContent::File { display_name, files };
            }
            // Text, Color, Email, Phone — content_text from items is sufficient
            _ => {}
        }
        Ok(())
    }

    /// Convert a database row to lightweight ItemMetadata
    fn row_to_metadata(row: &rusqlite::Row) -> rusqlite::Result<ItemMetadata> {
        let id: i64 = row.get(0)?;
        let content: String = row.get(1)?;
        let content_type: Option<String> = row.get(2)?;
        let timestamp_str: String = row.get(3)?;
        let source_app: Option<String> = row.get(4)?;
        let source_app_bundle_id: Option<String> = row.get(5)?;
        let thumbnail: Option<Vec<u8>> = row.get(6)?;
        let color_rgba: Option<u32> = row.get(7)?;

        let timestamp = parse_db_timestamp(&timestamp_str);
        let db_type = content_type.as_deref().unwrap_or("text");

        let icon = ItemIcon::from_database(db_type, color_rgba, thumbnail);
        let snippet = generate_preview(&content, SNIPPET_CONTEXT_CHARS * 2);

        Ok(ItemMetadata {
            item_id: id,
            icon,
            snippet,
            source_app,
            source_app_bundle_id,
            timestamp_unix: timestamp.timestamp(),
        })
    }
}

// Database is now inherently thread-safe via r2d2 pool
unsafe impl Send for Database {}
unsafe impl Sync for Database {}
