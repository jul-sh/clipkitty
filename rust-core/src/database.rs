//! SQLite database layer for clipboard storage
//!
//! Implements the database schema and operations for clipboard storage.
//! Uses r2d2 connection pooling to allow concurrent reads without mutex blocking.

use crate::interface::{ClipboardContent, ItemMetadata, ItemIcon, IconType};
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
                // WAL mode + synchronous=NORMAL for concurrent reads without blocking
                conn.execute_batch("
                    PRAGMA journal_mode=WAL;
                    PRAGMA synchronous=NORMAL;
                    PRAGMA mmap_size=67108864;
                    PRAGMA cache_size=-32000;
                ")?;
                Ok(())
            });

        let pool = Pool::builder()
            .max_size(8) // Allow multiple concurrent readers
            .build(manager)?;

        let db = Self { pool };
        db.setup_schema()?;
        Ok(db)
    }

    /// Open an in-memory database (for testing)
    pub fn open_in_memory() -> DatabaseResult<Self> {
        // For in-memory databases, we need shared cache to allow pool connections
        // to see the same database
        let manager = SqliteConnectionManager::memory()
            .with_init(|conn| {
                conn.execute_batch("
                    PRAGMA journal_mode=WAL;
                    PRAGMA synchronous=NORMAL;
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

    /// Set up the database schema
    fn setup_schema(&self) -> DatabaseResult<()> {
        let conn = self.get_conn()?;

        // Create items table (base schema from main branch)
        conn.execute(
            r#"
            CREATE TABLE IF NOT EXISTS items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content TEXT NOT NULL,
                contentHash TEXT NOT NULL,
                timestamp DATETIME NOT NULL,
                sourceApp TEXT,
                contentType TEXT DEFAULT 'text',
                imageData BLOB,
                linkTitle TEXT,
                linkImageData BLOB,
                sourceAppBundleID TEXT
            )
            "#,
            [],
        )?;

        // Migrate: add columns that may not exist in older databases
        // These are safe no-ops if columns already exist
        Self::add_column_if_missing(&conn, "linkDescription", "TEXT")?;
        Self::add_column_if_missing(&conn, "thumbnail", "BLOB")?;
        Self::add_column_if_missing(&conn, "colorRgba", "INTEGER")?;

        // Create indexes
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_items_hash ON items(contentHash)",
            [],
        )?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_items_timestamp ON items(timestamp)",
            [],
        )?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_items_content_prefix ON items(content COLLATE NOCASE)",
            [],
        )?;

        Ok(())
    }

    /// Add a column to the items table if it doesn't exist
    /// SQLite doesn't have IF NOT EXISTS for ALTER TABLE, so we catch the error
    fn add_column_if_missing(conn: &rusqlite::Connection, column: &str, col_type: &str) -> DatabaseResult<()> {
        let sql = format!("ALTER TABLE items ADD COLUMN {} {}", column, col_type);
        match conn.execute(&sql, []) {
            Ok(_) => Ok(()),
            Err(rusqlite::Error::SqliteFailure(err, _))
                if err.code == rusqlite::ErrorCode::Unknown && err.extended_code == 1 => {
                // Error code 1 = "duplicate column name" - column already exists, ignore
                Ok(())
            }
            Err(e) => Err(e.into()),
        }
    }

    /// Get the database size in bytes
    pub fn database_size(&self) -> DatabaseResult<i64> {
        let conn = self.get_conn()?;
        let page_count: i64 = conn.query_row("PRAGMA page_count", [], |row| row.get(0))?;
        let page_size: i64 = conn.query_row("PRAGMA page_size", [], |row| row.get(0))?;
        Ok(page_count * page_size)
    }

    /// Insert a new clipboard item, returns the row ID
    pub fn insert_item(&self, item: &StoredItem) -> DatabaseResult<i64> {
        let conn = self.get_conn()?;
        let (content, image_data, link_title, link_description, link_image_data, color_rgba) = item.content.to_database_fields();
        let timestamp = Utc.timestamp_opt(item.timestamp_unix, 0).single().unwrap_or_else(Utc::now);
        let timestamp_str = timestamp.format("%Y-%m-%d %H:%M:%S%.f").to_string();

        conn.execute(
            r#"
            INSERT INTO items (content, contentHash, timestamp, sourceApp, contentType, imageData, linkTitle, linkDescription, linkImageData, sourceAppBundleID, thumbnail, colorRgba)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            "#,
            params![
                content,
                item.content_hash,
                timestamp_str,
                item.source_app,
                item.content.database_type(),
                image_data,
                link_title,
                link_description,
                link_image_data,
                item.source_app_bundle_id,
                item.thumbnail,
                color_rgba,
            ],
        )?;

        Ok(conn.last_insert_rowid())
    }

    /// Find an existing item by content hash
    pub fn find_by_hash(&self, hash: &str) -> DatabaseResult<Option<StoredItem>> {
        let conn = self.get_conn()?;
        let mut stmt = conn.prepare(
            "SELECT * FROM items WHERE contentHash = ?1 LIMIT 1"
        )?;

        let result = stmt.query_row([hash], |row| Self::row_to_stored_item(row));

        match result {
            Ok(item) => Ok(Some(item)),
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

    /// Update link metadata for an item
    pub fn update_link_metadata(
        &self,
        id: i64,
        title: Option<&str>,
        description: Option<&str>,
        image_data: Option<&[u8]>,
    ) -> DatabaseResult<()> {
        let conn = self.get_conn()?;
        conn.execute(
            "UPDATE items SET linkTitle = ?1, linkDescription = ?2, linkImageData = ?3 WHERE id = ?4",
            params![title.unwrap_or(""), description, image_data, id],
        )?;
        Ok(())
    }

    /// Update image description
    pub fn update_image_description(&self, id: i64, description: &str) -> DatabaseResult<()> {
        let conn = self.get_conn()?;
        conn.execute(
            "UPDATE items SET content = ?1 WHERE id = ?2 AND contentType = 'image'",
            params![description, id],
        )?;
        Ok(())
    }

    /// Delete an item by ID
    pub fn delete_item(&self, id: i64) -> DatabaseResult<()> {
        let conn = self.get_conn()?;
        conn.execute("DELETE FROM items WHERE id = ?1", [id])?;
        Ok(())
    }

    /// Delete all items
    pub fn clear_all(&self) -> DatabaseResult<()> {
        let conn = self.get_conn()?;
        conn.execute("DELETE FROM items", [])?;
        Ok(())
    }

    /// Fetch lightweight item metadata for list display
    pub fn fetch_item_metadata(
        &self,
        before_timestamp: Option<DateTime<Utc>>,
        limit: usize,
    ) -> DatabaseResult<(Vec<ItemMetadata>, u64)> {
        let conn = self.get_conn()?;

        // Get total count
        let total_count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM items",
            [],
            |row| row.get(0),
        )?;
        let total_count = total_count as u64;

        let sql = if before_timestamp.is_some() {
            r#"SELECT id, content, contentType, timestamp, sourceApp, sourceAppBundleID, thumbnail, colorRgba, linkImageData
               FROM items WHERE timestamp < ?1 ORDER BY timestamp DESC LIMIT ?2"#
        } else {
            r#"SELECT id, content, contentType, timestamp, sourceApp, sourceAppBundleID, thumbnail, colorRgba, linkImageData
               FROM items ORDER BY timestamp DESC LIMIT ?1"#
        };

        let mut stmt = conn.prepare(sql)?;
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

    /// Fetch lightweight item metadata by IDs, preserving the order of the input IDs
    pub fn fetch_metadata_by_ids(&self, ids: &[i64]) -> DatabaseResult<Vec<ItemMetadata>> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }

        let conn = self.get_conn()?;
        let placeholders = ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
        let sql = format!(
            "SELECT id, content, contentType, timestamp, sourceApp, sourceAppBundleID, thumbnail, colorRgba, linkImageData \
             FROM items WHERE id IN ({})",
            placeholders
        );

        let mut stmt = conn.prepare(&sql)?;
        let params: Vec<rusqlite::types::Value> = ids.iter().map(|&id| id.into()).collect();
        let items: Vec<ItemMetadata> = stmt
            .query_map(rusqlite::params_from_iter(params), Self::row_to_metadata)?
            .collect::<Result<Vec<_>, _>>()?;

        // Re-sort to match input ID order
        let id_to_item: std::collections::HashMap<i64, ItemMetadata> = items
            .into_iter()
            .map(|item| (item.item_id, item))
            .collect();

        Ok(ids.iter().filter_map(|id| id_to_item.get(id).cloned()).collect())
    }

    /// Fetch items by IDs, preserving the order of the input IDs
    pub fn fetch_items_by_ids(&self, ids: &[i64]) -> DatabaseResult<Vec<StoredItem>> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }

        let conn = self.get_conn()?;
        let placeholders = ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
        let sql = format!("SELECT * FROM items WHERE id IN ({})", placeholders);

        let mut stmt = conn.prepare(&sql)?;
        let params: Vec<rusqlite::types::Value> = ids.iter().map(|&id| id.into()).collect();
        let items: Vec<StoredItem> = stmt
            .query_map(rusqlite::params_from_iter(params), Self::row_to_stored_item)?
            .collect::<Result<Vec<_>, _>>()?;

        // Re-sort to match input ID order
        let id_to_item: std::collections::HashMap<i64, StoredItem> = items
            .into_iter()
            .filter_map(|item| item.id.map(|id| (id, item)))
            .collect();

        Ok(ids.iter().filter_map(|id| id_to_item.get(id).cloned()).collect())
    }

    /// Fetch items by IDs with SQLite C-level interrupt support.
    ///
    /// When the cancellation token is triggered, this interrupts the SQLite query
    /// at the C level, allowing immediate abort of long-running disk reads.
    ///
    /// CRITICAL: The watcher task is wrapped in AbortOnDropHandle to prevent pool
    /// poisoning - if the watcher outlived this scope, it could interrupt a different
    /// query on a reused connection from the r2d2 pool.
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

        // Extract the SQLite interrupt handle - this is safe to call from another thread
        let interrupt_handle = conn.get_interrupt_handle();

        // Spawn a watcher task that interrupts SQLite when cancellation is requested.
        // CRITICAL: Wrap in AbortOnDropHandle for pool poisoning prevention.
        // When this scope exits (success or error via ?), the handle drops and aborts the watcher,
        // preventing it from interrupting a reused connection.
        let token_clone = token.clone();
        let watcher = runtime.spawn(async move {
            token_clone.cancelled().await;
            interrupt_handle.interrupt();
        });
        let _abort_guard = AbortOnDropHandle::new(watcher);

        // Now run the query - if cancelled, SQLite returns SQLITE_INTERRUPT
        let placeholders = ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
        let sql = format!("SELECT * FROM items WHERE id IN ({})", placeholders);

        let mut stmt = conn.prepare(&sql)?;
        let params: Vec<rusqlite::types::Value> = ids.iter().map(|&id| id.into()).collect();

        // Map SQLITE_INTERRUPT to our error - this happens if token was cancelled
        let items: Vec<StoredItem> = match stmt.query_map(rusqlite::params_from_iter(params), Self::row_to_stored_item) {
            Ok(rows) => rows.collect::<Result<Vec<_>, _>>()?,
            Err(rusqlite::Error::SqliteFailure(err, _)) if err.code == rusqlite::ffi::ErrorCode::OperationInterrupted => {
                // Query was interrupted via token - return empty, caller checks token
                return Ok(Vec::new());
            }
            Err(e) => return Err(e.into()),
        };

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
        let mut stmt = conn.prepare("SELECT * FROM items ORDER BY timestamp DESC")?;
        let items = stmt
            .query_map([], Self::row_to_stored_item)?
            .collect::<Result<Vec<_>, _>>()?;
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
            return Ok(Vec::new()); // Edge case: prevent division by zero
        }
        let target_size = (max_bytes as f64 * keep_ratio) as i64;
        let items_to_delete = std::cmp::max(100, ((current_size - target_size) / avg_item_size) as usize);

        let mut stmt = conn.prepare("SELECT id FROM items ORDER BY timestamp ASC LIMIT ?1")?;
        let ids: Vec<i64> = stmt
            .query_map([items_to_delete as i64], |row| row.get(0))?
            .collect::<Result<Vec<_>, _>>()?;

        Ok(ids)
    }

    /// Search for short queries (<3 chars) using prefix matching + LIKE on recent items
    /// Returns (id, content, timestamp_unix) tuples
    /// Two-part search:
    /// 1. Prefix match (fast, recency-ordered)
    /// 2. LIKE match on last N items (catches non-prefix matches in recent items)
    pub fn search_short_query(
        &self,
        query: &str,
        limit: usize,
    ) -> DatabaseResult<Vec<(i64, String, i64)>> {
        let conn = self.get_conn()?;
        let query_lower = query.to_lowercase();

        // Part 1: Prefix match - content starts with query (case insensitive)
        let prefix_pattern = format!("{}%", query_lower.replace('%', "\\%").replace('_', "\\_"));
        let mut stmt_prefix = conn.prepare(
            r#"SELECT id, content, CAST(strftime('%s', timestamp) AS INTEGER)
               FROM items
               WHERE LOWER(content) LIKE ?1 ESCAPE '\'
               ORDER BY timestamp DESC
               LIMIT ?2"#
        )?;
        let prefix_results: Vec<(i64, String, i64)> = stmt_prefix
            .query_map(params![prefix_pattern, limit as i64], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;

        // Part 2: LIKE match on last 20k items (catches substring matches in recent items)
        let like_pattern = format!("%{}%", query_lower.replace('%', "\\%").replace('_', "\\_"));
        let mut stmt_like = conn.prepare(
            r#"SELECT id, content, CAST(strftime('%s', timestamp) AS INTEGER)
               FROM (SELECT * FROM items ORDER BY timestamp DESC LIMIT 20000)
               WHERE LOWER(content) LIKE ?1 ESCAPE '\'
               ORDER BY timestamp DESC
               LIMIT ?2"#
        )?;
        let like_results: Vec<(i64, String, i64)> = stmt_like
            .query_map(params![like_pattern, limit as i64], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;

        // Merge results, preferring prefix matches, deduplicating by ID
        let mut seen_ids = std::collections::HashSet::new();
        let mut results = Vec::with_capacity(limit);

        // Add prefix results first (they get priority)
        for item in prefix_results {
            if seen_ids.insert(item.0) {
                results.push(item);
            }
        }

        // Add LIKE results (non-prefix substring matches)
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

    /// Prune old items to stay under max size
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
            return Ok(0); // Edge case: prevent division by zero
        }
        let target_size = (max_bytes as f64 * keep_ratio) as i64;
        let items_to_delete = std::cmp::max(100, ((current_size - target_size) / avg_item_size) as usize);

        conn.execute(
            r#"
            DELETE FROM items WHERE id IN (
                SELECT id FROM items ORDER BY timestamp ASC LIMIT ?1
            )
            "#,
            [items_to_delete as i64],
        )?;

        Ok(items_to_delete)
    }

    /// Convert a database row to a StoredItem
    fn row_to_stored_item(row: &rusqlite::Row) -> rusqlite::Result<StoredItem> {
        let id: i64 = row.get("id")?;
        let content: String = row.get("content")?;
        let content_hash: String = row.get("contentHash")?;
        let timestamp_str: String = row.get("timestamp")?;
        let source_app: Option<String> = row.get("sourceApp")?;
        let content_type: Option<String> = row.get("contentType")?;
        let image_data: Option<Vec<u8>> = row.get("imageData")?;
        let link_title: Option<String> = row.get("linkTitle")?;
        let link_description: Option<String> = row.get("linkDescription").ok().flatten();
        let link_image_data: Option<Vec<u8>> = row.get("linkImageData")?;
        let source_app_bundle_id: Option<String> = row.get("sourceAppBundleID")?;
        let thumbnail: Option<Vec<u8>> = row.get("thumbnail").ok().flatten();
        let color_rgba: Option<u32> = row.get("colorRgba").ok().flatten();

        let timestamp = parse_db_timestamp(&timestamp_str);

        let db_type = content_type.as_deref().unwrap_or("text");
        let clipboard_content = ClipboardContent::from_database(
            db_type,
            &content,
            image_data,
            link_title.as_deref(),
            link_description.as_deref(),
            link_image_data,
            color_rgba,
        );

        Ok(StoredItem {
            id: Some(id),
            content: clipboard_content,
            content_hash,
            timestamp_unix: timestamp.timestamp(),
            source_app,
            source_app_bundle_id,
            thumbnail,
            color_rgba,
        })
    }

    /// Convert a database row to lightweight ItemMetadata
    fn row_to_metadata(row: &rusqlite::Row) -> rusqlite::Result<ItemMetadata> {
        let id: i64 = row.get(0)?;
        let content: String = row.get(1)?;
        let content_type: Option<String> = row.get(2)?;
        let timestamp_str: String = row.get(3)?;
        let source_app: Option<String> = row.get(4)?;
        let source_app_bundle_id: Option<String> = row.get(5)?;
        let thumbnail: Option<Vec<u8>> = row.get(6).ok().flatten();
        let color_rgba: Option<u32> = row.get(7).ok().flatten();
        let link_image_data: Option<Vec<u8>> = row.get(8).ok().flatten();

        let timestamp = parse_db_timestamp(&timestamp_str);

        let db_type = content_type.as_deref().unwrap_or("text");

        // Determine icon based on content type
        let icon = match db_type {
            "color" => {
                if let Some(rgba) = color_rgba {
                    ItemIcon::ColorSwatch { rgba }
                } else {
                    ItemIcon::Symbol { icon_type: IconType::Color }
                }
            }
            "image" => {
                if let Some(thumb) = thumbnail {
                    ItemIcon::Thumbnail { bytes: thumb }
                } else {
                    ItemIcon::Symbol { icon_type: IconType::Image }
                }
            }
            "link" => {
                // Use link preview image as thumbnail if available
                if let Some(img) = link_image_data {
                    ItemIcon::Thumbnail { bytes: img }
                } else {
                    ItemIcon::Symbol { icon_type: IconType::Link }
                }
            }
            "email" => ItemIcon::Symbol { icon_type: IconType::Email },
            "phone" => ItemIcon::Symbol { icon_type: IconType::Phone },
            _ => ItemIcon::Symbol { icon_type: IconType::Text },
        };

        // Generate snippet text (generous snippet for Swift to truncate)
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
