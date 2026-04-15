//! SQLite database layer for clipboard storage
//!
//! Normalized schema: base `items` table + type-specific child tables.
//! Uses r2d2 connection pooling to allow concurrent reads without mutex blocking.

use crate::interface::{
    ClipboardContent, ContentTypeFilter, FileEntry, FileStatus, ItemIcon, ItemMetadata, ItemTag,
    LinkMetadataState, ListPresentationProfile,
};
use crate::models::StoredItem;
use crate::search::{generate_preview_for_profile, SNIPPET_CONTEXT_CHARS};
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
    #[error("Operation interrupted")]
    Interrupted,
    #[error("Database inconsistency: {0}")]
    InconsistentData(String),
}

pub type DatabaseResult<T> = Result<T, DatabaseError>;

#[cfg(feature = "sync")]
impl From<purr_sync::SyncError> for DatabaseError {
    fn from(e: purr_sync::SyncError) -> Self {
        match e {
            purr_sync::SyncError::Sqlite(e) => DatabaseError::Sqlite(e),
            purr_sync::SyncError::Pool(e) => DatabaseError::Pool(e),
            purr_sync::SyncError::InconsistentData(msg) => DatabaseError::InconsistentData(msg),
        }
    }
}

const SEARCH_METADATA_PREFIX_CHARS: usize = SNIPPET_CONTEXT_CHARS * 4;
const BROWSE_METADATA_PREFIX_CHARS: usize = SNIPPET_CONTEXT_CHARS * 8;
const GENERATED_ITEM_ID_SQL: &str = r#"lower(
    hex(randomblob(4)) || '-' ||
    hex(randomblob(2)) || '-4' ||
    substr(hex(randomblob(2)),2) || '-' ||
    substr('89ab', abs(random()) % 4 + 1, 1) ||
    substr(hex(randomblob(2)),2) || '-' ||
    hex(randomblob(6))
)"#;

/// Intermediate row with raw content prefix — snippet formatting deferred to caller.
struct RawBrowseMetadata {
    item_metadata: ItemMetadata,
    content_prefix: String,
}

/// Intermediate row for search metadata — snippet formatting deferred to caller.
struct RawSearchItemMetadata {
    row_id: i64,
    content_hash: String,
    db_type: String,
    item_metadata: ItemMetadata,
    content_prefix: String,
}

#[derive(Debug, Clone)]
pub(crate) struct SearchItemMetadata {
    pub(crate) row_id: i64,
    pub(crate) content_hash: String,
    pub(crate) db_type: String,
    pub(crate) item_metadata: ItemMetadata,
}

/// Parse timestamp string from database to DateTime<Utc>
fn parse_db_timestamp(timestamp_str: &str) -> DateTime<Utc> {
    chrono::NaiveDateTime::parse_from_str(timestamp_str, "%Y-%m-%d %H:%M:%S%.f")
        .or_else(|_| chrono::NaiveDateTime::parse_from_str(timestamp_str, "%Y-%m-%d %H:%M:%S"))
        .map(|dt| Utc.from_utc_datetime(&dt))
        .unwrap_or_else(|_| Utc::now())
}

fn table_column_not_null(
    conn: &rusqlite::Connection,
    table: &str,
    column: &str,
) -> DatabaseResult<bool> {
    let pragma = format!("PRAGMA table_info({table})");
    let mut stmt = conn.prepare(&pragma)?;
    let mut rows = stmt.query([])?;
    while let Some(row) = rows.next()? {
        let name: String = row.get(1)?;
        if name == column {
            let not_null: i64 = row.get(3)?;
            return Ok(not_null != 0);
        }
    }
    Ok(false)
}

fn repair_item_ids(conn: &rusqlite::Connection) -> DatabaseResult<()> {
    let sql = format!(
        r#"
        WITH duplicate_rows AS (
            SELECT id
            FROM (
                SELECT
                    id,
                    item_id,
                    ROW_NUMBER() OVER (PARTITION BY item_id ORDER BY id) AS ordinal
                FROM items
                WHERE item_id IS NOT NULL AND item_id != ''
            )
            WHERE ordinal > 1
        )
        UPDATE items
        SET item_id = {GENERATED_ITEM_ID_SQL}
        WHERE item_id IS NULL
           OR item_id = ''
           OR id IN (SELECT id FROM duplicate_rows);
        "#
    );
    conn.execute_batch(&sql)?;
    Ok(())
}

fn enforce_non_null_item_ids(conn: &rusqlite::Connection) -> DatabaseResult<()> {
    if table_column_not_null(conn, "items", "item_id")? {
        return Ok(());
    }

    conn.execute_batch("PRAGMA foreign_keys=OFF;")?;

    let migration_result = (|| -> DatabaseResult<()> {
        let tx = conn.unchecked_transaction()?;
        let sql = format!(
            r#"
            CREATE TABLE items_new (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                item_id TEXT NOT NULL,
                contentType TEXT NOT NULL,
                contentHash TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp TEXT NOT NULL,
                sourceApp TEXT,
                sourceAppBundleId TEXT,
                thumbnail BLOB,
                colorRgba INTEGER
            );

            INSERT INTO items_new (
                id,
                item_id,
                contentType,
                contentHash,
                content,
                timestamp,
                sourceApp,
                sourceAppBundleId,
                thumbnail,
                colorRgba
            )
            SELECT
                id,
                COALESCE(NULLIF(item_id, ''), {GENERATED_ITEM_ID_SQL}),
                contentType,
                contentHash,
                content,
                timestamp,
                sourceApp,
                sourceAppBundleId,
                thumbnail,
                colorRgba
            FROM items;

            DROP TABLE items;
            ALTER TABLE items_new RENAME TO items;

            CREATE INDEX IF NOT EXISTS idx_items_hash ON items(contentHash);
            CREATE INDEX IF NOT EXISTS idx_items_timestamp ON items(timestamp);
            CREATE INDEX IF NOT EXISTS idx_items_content_prefix ON items(content COLLATE NOCASE);
            "#
        );
        tx.execute_batch(&sql)?;
        tx.commit()?;
        Ok(())
    })();

    let restore_result = conn.execute_batch("PRAGMA foreign_keys=ON;");
    restore_result?;
    migration_result?;

    let mut stmt = conn.prepare("PRAGMA foreign_key_check")?;
    let mut rows = stmt.query([])?;
    if let Some(row) = rows.next()? {
        let table: String = row.get(0)?;
        return Err(DatabaseError::InconsistentData(format!(
            "foreign key violation after items migration in table `{table}`"
        )));
    }

    Ok(())
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
        let manager = SqliteConnectionManager::file(path).with_init(|conn| {
            conn.execute_batch(
                "
                    PRAGMA journal_mode=WAL;
                    PRAGMA synchronous=NORMAL;
                    PRAGMA foreign_keys=ON;
                    PRAGMA mmap_size=67108864;
                    PRAGMA cache_size=-32000;
                ",
            )?;
            Ok(())
        });

        let pool = Pool::builder().max_size(8).build(manager)?;

        let db = Self { pool };
        db.setup_schema()?;
        Ok(db)
    }

    /// Open an in-memory database (for testing)
    pub fn open_in_memory() -> DatabaseResult<Self> {
        let manager = SqliteConnectionManager::memory().with_init(|conn| {
            conn.execute_batch(
                "
                    PRAGMA journal_mode=WAL;
                    PRAGMA synchronous=NORMAL;
                    PRAGMA foreign_keys=ON;
                ",
            )?;
            Ok(())
        });

        // In-memory needs single connection to maintain state
        let pool = Pool::builder().max_size(1).build(manager)?;

        let db = Self { pool };
        db.setup_schema()?;
        Ok(db)
    }

    /// Get a connection from the pool
    pub(crate) fn get_conn(&self) -> DatabaseResult<PooledConnection<SqliteConnectionManager>> {
        Ok(self.pool.get()?)
    }

    /// Expose the connection pool for subsystems that manage their own SQL.
    pub fn pool(&self) -> &Pool<SqliteConnectionManager> {
        &self.pool
    }

    /// Set up the database schema (normalized: items + child tables)
    fn setup_schema(&self) -> DatabaseResult<()> {
        let conn = self.get_conn()?;

        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                item_id TEXT NOT NULL,
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
                description TEXT NOT NULL DEFAULT 'Image',
                is_animated INTEGER NOT NULL DEFAULT 0
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

            CREATE TABLE IF NOT EXISTS item_tags (
                itemId INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                tag TEXT NOT NULL,
                PRIMARY KEY (itemId, tag)
            );
            CREATE INDEX IF NOT EXISTS idx_item_tags_tag ON item_tags(tag);
        "#,
        )?;

        // Migration: Add is_animated column to existing image_items tables
        // This is idempotent - if the column already exists, the ALTER TABLE will fail silently
        let _ = conn.execute(
            "ALTER TABLE image_items ADD COLUMN is_animated INTEGER NOT NULL DEFAULT 0",
            [],
        );

        // Migration: Add item_id column to existing items tables
        let _ = conn.execute("ALTER TABLE items ADD COLUMN item_id TEXT", []);

        // Repair missing / duplicate logical IDs before enforcing storage invariants.
        repair_item_ids(&conn)?;
        enforce_non_null_item_ids(&conn)?;

        // Unique index on item_id
        conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_items_item_id ON items(item_id)",
            [],
        )?;

        // ── Sync tables (delegated to purr-sync) ──────────────────────
        #[cfg(feature = "sync")]
        purr_sync::schema::setup_sync_schema(&conn)?;

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

    /// Look up the stable string item_id for a given numeric row ID.
    pub fn fetch_item_id_by_row_id(&self, row_id: i64) -> DatabaseResult<Option<String>> {
        let conn = self.get_conn()?;
        let result = conn.query_row("SELECT item_id FROM items WHERE id = ?1", [row_id], |row| {
            row.get(0)
        });
        match result {
            Ok(id) => Ok(Some(id)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// Insert a new clipboard item using a transaction.
    /// Inserts into `items` + the appropriate child table(s).
    /// Returns the item ID.
    pub fn insert_item(&self, item: &StoredItem) -> DatabaseResult<i64> {
        let conn = self.get_conn()?;
        let tx = conn.unchecked_transaction()?;

        let (timestamp_str, content_type, content_text) = Self::base_item_fields(item);

        tx.execute(
            r#"INSERT INTO items (item_id, contentType, contentHash, content, timestamp, sourceApp, sourceAppBundleId, thumbnail, colorRgba)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)"#,
            params![
                item.item_id,
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
        Self::write_child_rows(&tx, item_id, item)?;

        tx.commit()?;
        Ok(item_id)
    }

    /// Replace an existing clipboard item while preserving its local row ID.
    pub fn replace_item_preserving_id(
        &self,
        item_id: i64,
        item: &StoredItem,
    ) -> DatabaseResult<()> {
        let conn = self.get_conn()?;
        let tx = conn.unchecked_transaction()?;
        let (timestamp_str, content_type, content_text) = Self::base_item_fields(item);

        tx.execute(
            r#"UPDATE items
               SET contentType = ?1,
                   contentHash = ?2,
                   content = ?3,
                   timestamp = ?4,
                   sourceApp = ?5,
                   sourceAppBundleId = ?6,
                   thumbnail = ?7,
                   colorRgba = ?8
               WHERE id = ?9"#,
            params![
                content_type,
                item.content_hash,
                content_text,
                timestamp_str,
                item.source_app,
                item.source_app_bundle_id,
                item.thumbnail,
                item.color_rgba,
                item_id,
            ],
        )?;

        tx.execute("DELETE FROM text_items WHERE itemId = ?1", params![item_id])?;
        tx.execute(
            "DELETE FROM image_items WHERE itemId = ?1",
            params![item_id],
        )?;
        tx.execute("DELETE FROM link_items WHERE itemId = ?1", params![item_id])?;
        tx.execute("DELETE FROM file_items WHERE itemId = ?1", params![item_id])?;
        Self::write_child_rows(&tx, item_id, item)?;

        tx.commit()?;
        Ok(())
    }

    fn base_item_fields(item: &StoredItem) -> (String, String, String) {
        let timestamp = Utc
            .timestamp_opt(item.timestamp_unix, 0)
            .single()
            .unwrap_or_else(Utc::now);
        let timestamp_str = timestamp.format("%Y-%m-%d %H:%M:%S%.f").to_string();
        let content_type = item.content.database_type().to_string();
        let content_text = item.content.text_content().to_string();
        (timestamp_str, content_type, content_text)
    }

    fn write_child_rows(
        tx: &rusqlite::Transaction<'_>,
        item_id: i64,
        item: &StoredItem,
    ) -> DatabaseResult<()> {
        match &item.content {
            ClipboardContent::Text { value } | ClipboardContent::Color { value } => {
                tx.execute(
                    "INSERT INTO text_items (itemId, value) VALUES (?1, ?2)",
                    params![item_id, value],
                )?;
            }
            ClipboardContent::Image {
                data,
                description,
                is_animated,
            } => {
                tx.execute(
                    "INSERT INTO image_items (itemId, data, description, is_animated) VALUES (?1, ?2, ?3, ?4)",
                    params![item_id, data, description, *is_animated as i32],
                )?;
            }
            ClipboardContent::Link {
                url,
                metadata_state,
            } => {
                let (title, description, _) = metadata_state.to_database_fields();
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

        Ok(())
    }

    /// Find an existing item by content hash
    pub fn find_by_hash(&self, hash: &str) -> DatabaseResult<Option<StoredItem>> {
        let conn = self.get_conn()?;
        let result = conn.query_row(
            "SELECT id, contentType, contentHash, content, timestamp, sourceApp, sourceAppBundleId, thumbnail, colorRgba, item_id FROM items WHERE contentHash = ?1 LIMIT 1",
            [hash],
            Self::row_to_base_item,
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

    /// Update text item content in-place
    pub fn update_text_item(&self, id: i64, text: &str, content_hash: &str) -> DatabaseResult<()> {
        let conn = self.get_conn()?;
        // Update the denormalized content in items table and the hash
        conn.execute(
            "UPDATE items SET content = ?1, contentHash = ?2 WHERE id = ?3 AND contentType = 'text'",
            params![text, content_hash, id],
        )?;
        // Update the child table
        conn.execute(
            "UPDATE text_items SET value = ?1 WHERE itemId = ?2",
            params![text, id],
        )?;
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
        tag: Option<&ItemTag>,
        presentation: ListPresentationProfile,
    ) -> DatabaseResult<(Vec<ItemMetadata>, u64)> {
        let conn = self.get_conn()?;

        let type_filter_clause = Self::content_type_where_clause(filter, "");
        let type_filter_clause_and = Self::content_type_where_clause(filter, "AND");
        let tag_clause_where =
            Self::tag_where_clause(tag, type_filter_clause.is_empty(), "WHERE", "AND");
        let tag_clause_and = Self::tag_where_clause(tag, false, "WHERE", "AND");

        let count_sql = format!(
            "SELECT COUNT(*) FROM items {} {}",
            type_filter_clause, tag_clause_where
        );
        let total_count: i64 = if let Some(tag) = tag {
            conn.query_row(&count_sql, params![tag.database_str()], |row| row.get(0))?
        } else {
            conn.query_row(&count_sql, [], |row| row.get(0))?
        };
        let total_count = total_count as u64;

        let sql = if before_timestamp.is_some() {
            format!(
                r#"SELECT id, substr(ltrim(content, char(9) || char(10) || char(13) || ' '), 1, {}), contentType, timestamp, sourceApp, sourceAppBundleId, thumbnail, colorRgba, item_id
                   FROM items WHERE timestamp < ? {} {} ORDER BY timestamp DESC LIMIT ?"#,
                BROWSE_METADATA_PREFIX_CHARS, type_filter_clause_and, tag_clause_and
            )
        } else {
            format!(
                r#"SELECT id, substr(ltrim(content, char(9) || char(10) || char(13) || ' '), 1, {}), contentType, timestamp, sourceApp, sourceAppBundleId, thumbnail, colorRgba, item_id
                   FROM items {} {} ORDER BY timestamp DESC LIMIT ?"#,
                BROWSE_METADATA_PREFIX_CHARS, type_filter_clause, tag_clause_where
            )
        };

        let mut stmt = conn.prepare(&sql)?;
        let raw_items = if let Some(ts) = before_timestamp {
            let ts_str = ts.format("%Y-%m-%d %H:%M:%S%.f").to_string();
            let mut param_values: Vec<rusqlite::types::Value> = vec![ts_str.into()];
            if let Some(tag) = tag {
                param_values.push(tag.database_str().to_string().into());
            }
            param_values.push((limit as i64).into());
            stmt.query_map(
                rusqlite::params_from_iter(param_values),
                Self::row_to_raw_browse_metadata,
            )?
            .collect::<Result<Vec<_>, _>>()?
        } else {
            let mut param_values: Vec<rusqlite::types::Value> = Vec::new();
            if let Some(tag) = tag {
                param_values.push(tag.database_str().to_string().into());
            }
            param_values.push((limit as i64).into());
            stmt.query_map(
                rusqlite::params_from_iter(param_values),
                Self::row_to_raw_browse_metadata,
            )?
            .collect::<Result<Vec<_>, _>>()?
        };

        let items = raw_items
            .into_iter()
            .map(|raw| {
                let mut metadata = raw.item_metadata;
                metadata.snippet = generate_preview_for_profile(&raw.content_prefix, presentation);
                metadata
            })
            .collect();

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
            "SELECT id, contentType, contentHash, content, timestamp, sourceApp, sourceAppBundleId, thumbnail, colorRgba, item_id FROM items WHERE id IN ({})",
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

        Ok(ids
            .iter()
            .filter_map(|id| id_to_item.get(id).cloned())
            .collect())
    }

    /// Fetch lightweight search result metadata by string item_ids, preserving order.
    pub(crate) fn fetch_search_item_metadata_by_string_ids(
        &self,
        item_ids: &[&str],
        presentation: ListPresentationProfile,
    ) -> DatabaseResult<Vec<SearchItemMetadata>> {
        if item_ids.is_empty() {
            return Ok(Vec::new());
        }

        let conn = self.get_conn()?;
        let placeholders = item_ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
        let sql = format!(
            "SELECT id, contentHash, substr(content, 1, {}), contentType, timestamp, sourceApp, sourceAppBundleId, thumbnail, colorRgba, item_id FROM items WHERE item_id IN ({})",
            SEARCH_METADATA_PREFIX_CHARS,
            placeholders
        );
        let mut stmt = conn.prepare(&sql)?;
        let params: Vec<rusqlite::types::Value> = item_ids
            .iter()
            .map(|&id| rusqlite::types::Value::from(id.to_string()))
            .collect();
        let raw_items: Vec<RawSearchItemMetadata> = stmt
            .query_map(
                rusqlite::params_from_iter(params),
                Self::row_to_raw_search_item_metadata,
            )?
            .collect::<Result<Vec<_>, _>>()?;

        let items: Vec<SearchItemMetadata> = raw_items
            .into_iter()
            .map(|raw| {
                let mut metadata = raw.item_metadata;
                metadata.snippet = generate_preview_for_profile(&raw.content_prefix, presentation);
                SearchItemMetadata {
                    row_id: raw.row_id,
                    content_hash: raw.content_hash,
                    db_type: raw.db_type,
                    item_metadata: metadata,
                }
            })
            .collect();

        let id_to_item: std::collections::HashMap<String, SearchItemMetadata> = items
            .into_iter()
            .map(|item| (item.item_metadata.item_id.clone(), item))
            .collect();

        Ok(item_ids
            .iter()
            .filter_map(|id| id_to_item.get(*id).cloned())
            .collect())
    }

    /// Filter string item_ids by tag, returning those that have the tag.
    pub(crate) fn filter_string_ids_by_tag(
        &self,
        item_ids: &[&str],
        tag: ItemTag,
    ) -> DatabaseResult<Vec<String>> {
        if item_ids.is_empty() {
            return Ok(Vec::new());
        }

        let conn = self.get_conn()?;
        let placeholders = item_ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
        let sql = format!(
            "SELECT i.item_id FROM items i INNER JOIN item_tags t ON i.id = t.itemId WHERE t.tag = ? AND i.item_id IN ({})",
            placeholders
        );
        let mut params: Vec<rusqlite::types::Value> = vec![tag.database_str().to_string().into()];
        params.extend(
            item_ids
                .iter()
                .map(|&id| rusqlite::types::Value::from(id.to_string())),
        );
        let mut stmt = conn.prepare(&sql)?;
        let result: Vec<String> = stmt
            .query_map(rusqlite::params_from_iter(params), |row| row.get(0))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(result)
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
            "SELECT id, contentType, contentHash, content, timestamp, sourceApp, sourceAppBundleId, thumbnail, colorRgba, item_id FROM items WHERE id IN ({})",
            placeholders
        );

        let mut stmt = conn.prepare(&sql)?;
        let params: Vec<rusqlite::types::Value> = ids.iter().map(|&id| id.into()).collect();

        let mut items: Vec<StoredItem> =
            match stmt.query_map(rusqlite::params_from_iter(params), Self::row_to_base_item) {
                Ok(rows) => rows.collect::<Result<Vec<_>, _>>()?,
                Err(rusqlite::Error::SqliteFailure(err, _))
                    if err.code == rusqlite::ffi::ErrorCode::OperationInterrupted =>
                {
                    return Err(DatabaseError::Interrupted);
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

        if token.is_cancelled() {
            return Err(DatabaseError::Interrupted);
        }

        Ok(ids
            .iter()
            .filter_map(|id| id_to_item.get(id).cloned())
            .collect())
    }

    /// Fetch all items (for index rebuilding)
    pub fn fetch_all_items(&self) -> DatabaseResult<Vec<StoredItem>> {
        let conn = self.get_conn()?;
        let mut stmt = conn.prepare(
            "SELECT id, contentType, contentHash, content, timestamp, sourceApp, sourceAppBundleId, thumbnail, colorRgba, item_id FROM items ORDER BY timestamp DESC"
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

    /// Fetch all item IDs, ordered by recency.
    pub fn fetch_all_item_ids(&self) -> DatabaseResult<Vec<i64>> {
        let conn = self.get_conn()?;
        let mut stmt = conn.prepare("SELECT id FROM items ORDER BY timestamp DESC")?;
        let ids = stmt
            .query_map([], |row| row.get(0))?
            .collect::<Result<Vec<i64>, _>>()?;
        Ok(ids)
    }

    /// Get IDs that would be pruned (for index deletion before database prune).
    /// Returns (row_id, item_id) pairs so callers can delete from both DB and search index.
    pub fn get_prunable_ids(
        &self,
        max_bytes: i64,
        keep_ratio: f64,
    ) -> DatabaseResult<Vec<(i64, String)>> {
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
        let items_to_delete =
            std::cmp::max(100, ((current_size - target_size) / avg_item_size) as usize);

        let mut stmt =
            conn.prepare("SELECT id, item_id FROM items ORDER BY timestamp ASC LIMIT ?1")?;
        let ids: Vec<(i64, String)> = stmt
            .query_map([items_to_delete as i64], |row| {
                Ok((row.get(0)?, row.get(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;

        Ok(ids)
    }

    /// Search for short queries (<3 chars) using prefix matching + substring LIKE on recent items.
    /// Prefix-only search for very short queries (< 3 chars).
    /// Uses LIKE prefix matching which can leverage the index.
    /// Returns (id, content, timestamp) sorted by recency.
    pub fn search_prefix_query(
        &self,
        query: &str,
        limit: usize,
        filter: Option<&ContentTypeFilter>,
        tag: Option<&ItemTag>,
    ) -> DatabaseResult<Vec<(i64, String, i64)>> {
        let conn = self.get_conn()?;
        let query_lower = query.to_lowercase();
        let escaped = query_lower.replace('%', "\\%").replace('_', "\\_");
        let type_filter_and = Self::content_type_where_clause(filter, "AND");
        let tag_filter_and = Self::tag_where_clause(tag, false, "WHERE", "AND");

        let prefix_pattern = format!("{}%", escaped);
        let sql = format!(
            r#"SELECT id, content, CAST(strftime('%s', timestamp) AS INTEGER)
               FROM items
               WHERE content LIKE ? ESCAPE '\' COLLATE NOCASE {} {}
               ORDER BY timestamp DESC
               LIMIT ?"#,
            type_filter_and, tag_filter_and
        );
        let mut stmt = conn.prepare(&sql)?;
        let mut param_values: Vec<rusqlite::types::Value> = vec![prefix_pattern.into()];
        if let Some(tag) = tag {
            param_values.push(tag.database_str().to_string().into());
        }
        param_values.push((limit as i64).into());
        let results: Vec<(i64, String, i64)> = stmt
            .query_map(rusqlite::params_from_iter(param_values), |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;

        Ok(results)
    }

    /// Fetch recent items for short-query fallback scanning.
    /// Returns (id, content, timestamp) sorted by recency.
    pub fn fetch_recent_items_for_short_query(
        &self,
        limit: usize,
        filter: Option<&ContentTypeFilter>,
        tag: Option<&ItemTag>,
    ) -> DatabaseResult<Vec<(i64, String, i64)>> {
        let conn = self.get_conn()?;
        let type_filter_where = Self::content_type_where_clause(filter, "WHERE");
        let tag_filter_where = Self::tag_where_clause(tag, false, "WHERE", "AND");
        let sql = format!(
            r#"SELECT id, content, CAST(strftime('%s', timestamp) AS INTEGER)
               FROM items
               {} {}
               ORDER BY timestamp DESC
               LIMIT ?"#,
            type_filter_where, tag_filter_where
        );
        let mut stmt = conn.prepare(&sql)?;
        let mut param_values: Vec<rusqlite::types::Value> = Vec::new();
        if let Some(tag) = tag {
            param_values.push(tag.database_str().to_string().into());
        }
        param_values.push((limit as i64).into());
        let results: Vec<(i64, String, i64)> = stmt
            .query_map(rusqlite::params_from_iter(param_values), |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;

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
        let items_to_delete =
            std::cmp::max(100, ((current_size - target_size) / avg_item_size) as usize);

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

    fn tag_where_clause(
        tag: Option<&ItemTag>,
        no_prior_clause: bool,
        where_prefix: &str,
        and_prefix: &str,
    ) -> String {
        let Some(_) = tag else {
            return String::new();
        };
        let prefix = if no_prior_clause {
            where_prefix
        } else {
            and_prefix
        };
        format!("{prefix} id IN (SELECT itemId FROM item_tags WHERE tag = ?)")
    }

    pub fn add_tag(&self, item_id: i64, tag: ItemTag) -> DatabaseResult<()> {
        let conn = self.get_conn()?;
        conn.execute(
            "INSERT OR IGNORE INTO item_tags (itemId, tag) VALUES (?1, ?2)",
            params![item_id, tag.database_str()],
        )?;
        Ok(())
    }

    pub fn remove_tag(&self, item_id: i64, tag: ItemTag) -> DatabaseResult<()> {
        let conn = self.get_conn()?;
        conn.execute(
            "DELETE FROM item_tags WHERE itemId = ?1 AND tag = ?2",
            params![item_id, tag.database_str()],
        )?;
        Ok(())
    }

    pub fn get_tags_for_ids(
        &self,
        ids: &[i64],
    ) -> DatabaseResult<std::collections::HashMap<i64, Vec<ItemTag>>> {
        if ids.is_empty() {
            return Ok(std::collections::HashMap::new());
        }

        let conn = self.get_conn()?;
        let placeholders = ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
        let sql = format!(
            "SELECT itemId, tag FROM item_tags WHERE itemId IN ({}) ORDER BY tag",
            placeholders
        );
        let mut stmt = conn.prepare(&sql)?;
        let params: Vec<rusqlite::types::Value> = ids.iter().map(|&id| id.into()).collect();
        let rows = stmt.query_map(rusqlite::params_from_iter(params), |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
        })?;

        let mut map: std::collections::HashMap<i64, Vec<ItemTag>> =
            std::collections::HashMap::new();
        for row in rows {
            let (id, tag) = row?;
            let tag = ItemTag::from_database_str(&tag).map_err(DatabaseError::InconsistentData)?;
            map.entry(id).or_default().push(tag);
        }

        Ok(map)
    }

    /// Resolve a string item_id to its numeric row ID.
    pub fn fetch_row_id_by_item_id(&self, item_id: &str) -> DatabaseResult<Option<i64>> {
        let conn = self.get_conn()?;
        let result = conn.query_row(
            "SELECT id FROM items WHERE item_id = ?1",
            [item_id],
            |row| row.get(0),
        );
        match result {
            Ok(id) => Ok(Some(id)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// Fetch full items by string item_ids, preserving the order of the input IDs.
    pub fn fetch_items_by_item_ids(&self, item_ids: &[String]) -> DatabaseResult<Vec<StoredItem>> {
        if item_ids.is_empty() {
            return Ok(Vec::new());
        }

        let conn = self.get_conn()?;
        let placeholders = item_ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
        let sql = format!(
            "SELECT id, contentType, contentHash, content, timestamp, sourceApp, sourceAppBundleId, thumbnail, colorRgba, item_id FROM items WHERE item_id IN ({})",
            placeholders
        );

        let mut stmt = conn.prepare(&sql)?;
        let params: Vec<rusqlite::types::Value> =
            item_ids.iter().map(|id| id.clone().into()).collect();
        let mut items: Vec<StoredItem> = stmt
            .query_map(rusqlite::params_from_iter(params), Self::row_to_base_item)?
            .collect::<Result<Vec<_>, _>>()?;

        for item in &mut items {
            if let Some(id) = item.id {
                Self::populate_child_content(&conn, item, id)?;
            }
        }

        let id_to_item: std::collections::HashMap<String, StoredItem> = items
            .into_iter()
            .map(|item| (item.item_id.clone(), item))
            .collect();

        Ok(item_ids
            .iter()
            .filter_map(|id| id_to_item.get(id).cloned())
            .collect())
    }

    /// Get tags for items keyed by string item_id.
    pub fn get_tags_for_item_ids(
        &self,
        item_ids: &[String],
    ) -> DatabaseResult<std::collections::HashMap<String, Vec<ItemTag>>> {
        if item_ids.is_empty() {
            return Ok(std::collections::HashMap::new());
        }

        let conn = self.get_conn()?;
        let placeholders = item_ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
        let sql = format!(
            "SELECT i.item_id, t.tag FROM item_tags t JOIN items i ON i.id = t.itemId WHERE i.item_id IN ({}) ORDER BY t.tag",
            placeholders
        );
        let mut stmt = conn.prepare(&sql)?;
        let params: Vec<rusqlite::types::Value> =
            item_ids.iter().map(|id| id.clone().into()).collect();
        let rows = stmt.query_map(rusqlite::params_from_iter(params), |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;

        let mut map: std::collections::HashMap<String, Vec<ItemTag>> =
            std::collections::HashMap::new();
        for row in rows {
            let (id, tag) = row?;
            let tag = ItemTag::from_database_str(&tag).map_err(DatabaseError::InconsistentData)?;
            map.entry(id).or_default().push(tag);
        }

        Ok(map)
    }

    pub fn filter_ids_by_tag(&self, ids: &[i64], tag: ItemTag) -> DatabaseResult<Vec<i64>> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }

        let conn = self.get_conn()?;
        let placeholders = ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
        let sql = format!(
            "SELECT itemId FROM item_tags WHERE tag = ? AND itemId IN ({})",
            placeholders
        );
        let mut params: Vec<rusqlite::types::Value> = vec![tag.database_str().to_string().into()];
        params.extend(ids.iter().map(|&id| rusqlite::types::Value::from(id)));
        let mut stmt = conn.prepare(&sql)?;
        let result: Vec<i64> = stmt
            .query_map(rusqlite::params_from_iter(params), |row| row.get(0))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(result)
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
        let item_id: String = row.get(9)?;

        let timestamp = parse_db_timestamp(&timestamp_str);

        // Placeholder content — will be replaced by populate_child_content
        let content = match content_type.as_str() {
            "color" => ClipboardContent::Color {
                value: content_text,
            },
            "image" => ClipboardContent::Image {
                data: Vec::new(),
                description: content_text,
                is_animated: false,
            },
            "link" => ClipboardContent::Link {
                url: content_text,
                metadata_state: LinkMetadataState::Pending,
            },
            "file" => ClipboardContent::File {
                display_name: content_text,
                files: Vec::new(),
            },
            _ => ClipboardContent::Text {
                value: content_text,
            },
        };

        Ok(StoredItem {
            id: Some(id),
            item_id,
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
    fn populate_child_content(
        conn: &rusqlite::Connection,
        item: &mut StoredItem,
        item_id: i64,
    ) -> DatabaseResult<()> {
        match &item.content {
            ClipboardContent::Image { description, .. } => {
                let description = description.clone();
                let (data, is_animated): (Vec<u8>, bool) = conn
                    .query_row(
                        "SELECT data, is_animated FROM image_items WHERE itemId = ?1",
                        [item_id],
                        |row| {
                            let data: Vec<u8> = row.get(0)?;
                            let is_animated: i32 = row.get(1)?;
                            Ok((data, is_animated != 0))
                        },
                    )
                    .map_err(|error| match error {
                        rusqlite::Error::QueryReturnedNoRows => DatabaseError::InconsistentData(
                            format!("image item {item_id} is missing its image_items child row"),
                        ),
                        other => DatabaseError::Sqlite(other),
                    })?;
                item.content = ClipboardContent::Image {
                    data,
                    description,
                    is_animated,
                };
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
                    Ok((title, desc)) => LinkMetadataState::from_database(
                        title.as_deref(),
                        desc.as_deref(),
                        item.thumbnail.clone(),
                    )
                    .map_err(|message| {
                        DatabaseError::InconsistentData(format!(
                            "link item {item_id} has invalid metadata state: {message}"
                        ))
                    })?,
                    Err(rusqlite::Error::QueryReturnedNoRows) => {
                        return Err(DatabaseError::InconsistentData(format!(
                            "link item {item_id} is missing its link_items child row"
                        )));
                    }
                    Err(other) => return Err(DatabaseError::Sqlite(other)),
                };
                item.content = ClipboardContent::Link {
                    url,
                    metadata_state,
                };
            }
            ClipboardContent::File { display_name, .. } => {
                let display_name = display_name.clone();
                let mut stmt = conn.prepare(
                    "SELECT path, filename, fileSize, uti, bookmarkData, fileStatus FROM file_items WHERE itemId = ?1 ORDER BY ordinal"
                )?;
                let files: Vec<FileEntry> = stmt
                    .query_map([item_id], |row| {
                        let path: String = row.get(0)?;
                        let filename: String = row.get(1)?;
                        let file_size: i64 = row.get(2)?;
                        let uti: String = row.get(3)?;
                        let bookmark_data: Vec<u8> = row.get(4)?;
                        let file_status_str: String = row.get(5)?;
                        Ok(FileEntry {
                            path,
                            filename,
                            file_size: file_size as u64,
                            uti,
                            bookmark_data,
                            file_status: FileStatus::from_database_str(&file_status_str),
                        })
                    })?
                    .collect::<Result<Vec<_>, _>>()?;
                item.content = ClipboardContent::File {
                    display_name,
                    files,
                };
            }
            // Text, Color, Email, Phone — content_text from items is sufficient
            _ => {}
        }
        Ok(())
    }

    /// Convert a database row to raw browse metadata — snippet formatting deferred to caller.
    fn row_to_raw_browse_metadata(row: &rusqlite::Row) -> rusqlite::Result<RawBrowseMetadata> {
        let _id: i64 = row.get(0)?;
        let content: String = row.get(1)?;
        let content_type: Option<String> = row.get(2)?;
        let timestamp_str: String = row.get(3)?;
        let source_app: Option<String> = row.get(4)?;
        let source_app_bundle_id: Option<String> = row.get(5)?;
        let thumbnail: Option<Vec<u8>> = row.get(6)?;
        let color_rgba: Option<u32> = row.get(7)?;
        let item_id: String = row.get(8)?;

        let timestamp = parse_db_timestamp(&timestamp_str);
        let db_type = content_type.as_deref().unwrap_or("text");

        let icon = ItemIcon::from_database(db_type, color_rgba, thumbnail);

        Ok(RawBrowseMetadata {
            content_prefix: content,
            item_metadata: ItemMetadata {
                item_id,
                icon,
                snippet: String::new(),
                source_app,
                source_app_bundle_id,
                timestamp_unix: timestamp.timestamp(),
                tags: Vec::new(),
            },
        })
    }

    fn row_to_raw_search_item_metadata(
        row: &rusqlite::Row,
    ) -> rusqlite::Result<RawSearchItemMetadata> {
        let row_id: i64 = row.get(0)?;
        let content_hash: String = row.get(1)?;
        let content_prefix: String = row.get(2)?;
        let db_type = row
            .get::<_, Option<String>>(3)?
            .unwrap_or_else(|| "text".to_string());
        let timestamp_str: String = row.get(4)?;
        let source_app: Option<String> = row.get(5)?;
        let source_app_bundle_id: Option<String> = row.get(6)?;
        let thumbnail: Option<Vec<u8>> = row.get(7)?;
        let color_rgba: Option<u32> = row.get(8)?;
        let item_id: String = row.get(9)?;

        let timestamp = parse_db_timestamp(&timestamp_str);
        let icon = ItemIcon::from_database(&db_type, color_rgba, thumbnail);

        Ok(RawSearchItemMetadata {
            row_id,
            content_hash,
            db_type,
            content_prefix,
            item_metadata: ItemMetadata {
                item_id,
                icon,
                snippet: String::new(),
                source_app,
                source_app_bundle_id,
                timestamp_unix: timestamp.timestamp(),
                tags: Vec::new(),
            },
        })
    }
}

// Database is now inherently thread-safe via r2d2 pool
unsafe impl Send for Database {}
unsafe impl Sync for Database {}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::NamedTempFile;

    fn seed_base_item(
        db: &Database,
        content_type: &str,
        content: &str,
        thumbnail: Option<Vec<u8>>,
    ) -> i64 {
        let conn = db.get_conn().unwrap();
        let item_id = uuid::Uuid::new_v4().to_string();
        conn.execute(
            "INSERT INTO items (item_id, contentType, contentHash, content, timestamp, thumbnail) VALUES (?1, ?2, ?3, ?4, '2026-01-01 00:00:00', ?5)",
            params![item_id, content_type, format!("hash-{content_type}-{content}"), content, thumbnail],
        )
        .unwrap();
        conn.last_insert_rowid()
    }

    #[test]
    fn test_missing_image_child_row_is_inconsistency() {
        let db = Database::open_in_memory().unwrap();
        let item_id = seed_base_item(&db, "image", "Image", None);

        let result = db.fetch_items_by_ids(&[item_id]);
        assert!(matches!(
            result,
            Err(DatabaseError::InconsistentData(message))
            if message.contains("missing its image_items child row")
        ));
    }

    #[test]
    fn test_missing_link_child_row_is_inconsistency() {
        let db = Database::open_in_memory().unwrap();
        let item_id = seed_base_item(&db, "link", "https://example.com", None);

        let result = db.fetch_items_by_ids(&[item_id]);
        assert!(matches!(
            result,
            Err(DatabaseError::InconsistentData(message))
            if message.contains("missing its link_items child row")
        ));
    }

    #[test]
    fn test_invalid_link_metadata_shape_is_inconsistency() {
        let db = Database::open_in_memory().unwrap();
        let item_id = seed_base_item(&db, "link", "https://example.com", None);
        let conn = db.get_conn().unwrap();
        conn.execute(
            "INSERT INTO link_items (itemId, url, title, description) VALUES (?1, ?2, ?3, ?4)",
            params![item_id, "https://example.com", "", "dangling"],
        )
        .unwrap();
        drop(conn);

        let result = db.fetch_items_by_ids(&[item_id]);
        match result {
            Err(DatabaseError::InconsistentData(message)) => {
                assert!(message.contains("link item"));
            }
            other => panic!("expected inconsistency error, got {other:?}"),
        }
    }

    #[test]
    fn test_fetch_item_metadata_preview_handles_large_leading_whitespace() {
        let db = Database::open_in_memory().unwrap();
        let content = format!("{}Hello world", " \n\t".repeat(2_000));
        seed_base_item(&db, "text", &content, None);

        let (items, total_count) = db
            .fetch_item_metadata(None, 1, None, None, ListPresentationProfile::CompactRow)
            .unwrap();

        assert_eq!(total_count, 1);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0].snippet,
            generate_preview_for_profile(&content, ListPresentationProfile::CompactRow)
        );
    }

    #[test]
    fn test_new_schema_requires_non_null_item_id() {
        let db = Database::open_in_memory().unwrap();
        let conn = db.get_conn().unwrap();
        assert!(table_column_not_null(&conn, "items", "item_id").unwrap());
    }

    #[test]
    fn test_legacy_items_table_without_item_id_is_migrated() {
        let temp = NamedTempFile::new().unwrap();
        {
            let conn = rusqlite::Connection::open(temp.path()).unwrap();
            conn.execute_batch(
                r#"
                PRAGMA foreign_keys=ON;
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
                );
                CREATE TABLE text_items (
                    itemId INTEGER PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
                    value TEXT NOT NULL
                );
                INSERT INTO items (id, contentType, contentHash, content, timestamp)
                VALUES (1, 'text', 'hash-text-legacy', 'legacy text', '2026-01-01 00:00:00');
                INSERT INTO text_items (itemId, value) VALUES (1, 'legacy text');
                "#,
            )
            .unwrap();
        }

        let db = Database::open(temp.path()).unwrap();
        let conn = db.get_conn().unwrap();
        assert!(table_column_not_null(&conn, "items", "item_id").unwrap());

        let item_ids: Vec<String> = {
            let mut stmt = conn
                .prepare("SELECT item_id FROM items ORDER BY id")
                .unwrap();
            stmt.query_map([], |row| row.get(0))
                .unwrap()
                .collect::<Result<Vec<_>, _>>()
                .unwrap()
        };
        drop(conn);

        assert_eq!(item_ids.len(), 1);
        assert!(!item_ids[0].is_empty());
        let items = db.fetch_items_by_item_ids(&item_ids).unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].content.text_content(), "legacy text");
    }

    #[test]
    fn test_nullable_and_duplicate_item_ids_are_repaired() {
        let temp = NamedTempFile::new().unwrap();
        {
            let conn = rusqlite::Connection::open(temp.path()).unwrap();
            conn.execute_batch(
                r#"
                PRAGMA foreign_keys=ON;
                CREATE TABLE items (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    item_id TEXT,
                    contentType TEXT NOT NULL,
                    contentHash TEXT NOT NULL,
                    content TEXT NOT NULL,
                    timestamp TEXT NOT NULL,
                    sourceApp TEXT,
                    sourceAppBundleId TEXT,
                    thumbnail BLOB,
                    colorRgba INTEGER
                );
                CREATE TABLE text_items (
                    itemId INTEGER PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
                    value TEXT NOT NULL
                );
                INSERT INTO items (id, item_id, contentType, contentHash, content, timestamp)
                VALUES
                    (1, 'duplicate-id', 'text', 'hash-1', 'first', '2026-01-01 00:00:00'),
                    (2, 'duplicate-id', 'text', 'hash-2', 'second', '2026-01-01 00:00:01'),
                    (3, NULL, 'text', 'hash-3', 'third', '2026-01-01 00:00:02');
                INSERT INTO text_items (itemId, value)
                VALUES (1, 'first'), (2, 'second'), (3, 'third');
                "#,
            )
            .unwrap();
        }

        let db = Database::open(temp.path()).unwrap();
        let conn = db.get_conn().unwrap();
        assert!(table_column_not_null(&conn, "items", "item_id").unwrap());

        let item_ids: Vec<String> = {
            let mut stmt = conn
                .prepare("SELECT item_id FROM items ORDER BY id")
                .unwrap();
            stmt.query_map([], |row| row.get(0))
                .unwrap()
                .collect::<Result<Vec<_>, _>>()
                .unwrap()
        };
        drop(conn);

        assert_eq!(item_ids.len(), 3);
        assert_eq!(
            item_ids
                .iter()
                .cloned()
                .collect::<std::collections::HashSet<_>>()
                .len(),
            3
        );
        assert!(item_ids.iter().all(|item_id| !item_id.is_empty()));

        let items = db.fetch_items_by_item_ids(&item_ids).unwrap();
        assert_eq!(items.len(), 3);
    }
}
