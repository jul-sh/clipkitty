//! SQLite database layer for clipboard storage
//!
//! Implements the database schema and operations for clipboard storage.

use crate::interface::{ClipboardContent, ItemMetadata, ItemIcon, IconType};
use crate::models::{StoredItem, normalize_preview};
use chrono::{DateTime, TimeZone, Utc};
use parking_lot::Mutex;
use rusqlite::{params, Connection};
use std::path::Path;
use std::sync::Arc;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum DatabaseError {
    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("Database not initialized")]
    NotInitialized,
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}

pub type DatabaseResult<T> = Result<T, DatabaseError>;

/// Parse timestamp string from database to DateTime<Utc>
fn parse_db_timestamp(timestamp_str: &str) -> DateTime<Utc> {
    chrono::NaiveDateTime::parse_from_str(timestamp_str, "%Y-%m-%d %H:%M:%S%.f")
        .or_else(|_| chrono::NaiveDateTime::parse_from_str(timestamp_str, "%Y-%m-%d %H:%M:%S"))
        .map(|dt| Utc.from_utc_datetime(&dt))
        .unwrap_or_else(|_| Utc::now())
}

/// Thread-safe database wrapper
pub struct Database {
    pub(crate) conn: Arc<Mutex<Connection>>,
}

impl Database {
    /// Open or create a database at the given path
    pub fn open<P: AsRef<Path>>(path: P) -> DatabaseResult<Self> {
        let conn = Connection::open(path)?;

        // Memory optimization: WAL mode + mmap for faster reads
        conn.execute_batch("
            PRAGMA journal_mode=WAL;
            PRAGMA mmap_size=67108864;
            PRAGMA cache_size=-32000;
        ")?;

        let db = Self {
            conn: Arc::new(Mutex::new(conn)),
        };
        db.setup_schema()?;
        Ok(db)
    }

    /// Open an in-memory database (for testing)
    pub fn open_in_memory() -> DatabaseResult<Self> {
        let conn = Connection::open_in_memory()?;
        let db = Self {
            conn: Arc::new(Mutex::new(conn)),
        };
        db.setup_schema()?;
        Ok(db)
    }

    /// Set up the database schema
    fn setup_schema(&self) -> DatabaseResult<()> {
        let conn = self.conn.lock();

        // Create items table
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
                sourceAppBundleID TEXT,
                thumbnail BLOB,
                colorRgba INTEGER
            )
            "#,
            [],
        )?;

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

    /// Get the database size in bytes
    pub fn database_size(&self) -> DatabaseResult<i64> {
        let conn = self.conn.lock();
        let page_count: i64 = conn.query_row("PRAGMA page_count", [], |row| row.get(0))?;
        let page_size: i64 = conn.query_row("PRAGMA page_size", [], |row| row.get(0))?;
        Ok(page_count * page_size)
    }

    /// Insert a new clipboard item, returns the row ID
    pub fn insert_item(&self, item: &StoredItem) -> DatabaseResult<i64> {
        let conn = self.conn.lock();
        let (content, image_data, link_title, link_image_data, color_rgba) = item.content.to_database_fields();
        let timestamp = Utc.timestamp_opt(item.timestamp_unix, 0).single().unwrap_or_else(Utc::now);
        let timestamp_str = timestamp.format("%Y-%m-%d %H:%M:%S%.f").to_string();

        conn.execute(
            r#"
            INSERT INTO items (content, contentHash, timestamp, sourceApp, contentType, imageData, linkTitle, linkImageData, sourceAppBundleID, thumbnail, colorRgba)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            "#,
            params![
                content,
                item.content_hash,
                timestamp_str,
                item.source_app,
                item.content.database_type(),
                image_data,
                link_title,
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
        let conn = self.conn.lock();
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
        let conn = self.conn.lock();
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
        image_data: Option<&[u8]>,
    ) -> DatabaseResult<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE items SET linkTitle = ?1, linkImageData = ?2 WHERE id = ?3",
            params![title.unwrap_or(""), image_data, id],
        )?;
        Ok(())
    }

    /// Update image description
    pub fn update_image_description(&self, id: i64, description: &str) -> DatabaseResult<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE items SET content = ?1 WHERE id = ?2 AND contentType = 'image'",
            params![description, id],
        )?;
        Ok(())
    }

    /// Delete an item by ID
    pub fn delete_item(&self, id: i64) -> DatabaseResult<()> {
        let conn = self.conn.lock();
        conn.execute("DELETE FROM items WHERE id = ?1", [id])?;
        Ok(())
    }

    /// Delete all items
    pub fn clear_all(&self) -> DatabaseResult<()> {
        let conn = self.conn.lock();
        conn.execute("DELETE FROM items", [])?;
        Ok(())
    }

    /// Fetch lightweight item metadata for list display
    pub fn fetch_item_metadata(
        &self,
        before_timestamp: Option<DateTime<Utc>>,
        limit: usize,
    ) -> DatabaseResult<(Vec<ItemMetadata>, u64)> {
        let conn = self.conn.lock();

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

    /// Fetch items by IDs, preserving the order of the input IDs
    pub fn fetch_items_by_ids(&self, ids: &[i64]) -> DatabaseResult<Vec<StoredItem>> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }

        let conn = self.conn.lock();
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

    /// Fetch all items (for index rebuilding)
    pub fn fetch_all_items(&self) -> DatabaseResult<Vec<StoredItem>> {
        let conn = self.conn.lock();
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

        let conn = self.conn.lock();

        let count: i64 = conn.query_row("SELECT COUNT(*) FROM items", [], |row| row.get(0))?;
        if count == 0 {
            return Ok(Vec::new());
        }

        let avg_item_size = current_size / count;
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
        let conn = self.conn.lock();
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

        let conn = self.conn.lock();

        let count: i64 = conn.query_row("SELECT COUNT(*) FROM items", [], |row| row.get(0))?;
        if count == 0 {
            return Ok(0);
        }

        let avg_item_size = current_size / count;
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
            "address" => ItemIcon::Symbol { icon_type: IconType::Address },
            "date" => ItemIcon::Symbol { icon_type: IconType::DateType },
            "transit" => ItemIcon::Symbol { icon_type: IconType::Transit },
            _ => ItemIcon::Symbol { icon_type: IconType::Text },
        };

        // Generate preview text (first 200 chars, normalized whitespace)
        let preview = normalize_preview(&content, 200);

        Ok(ItemMetadata {
            item_id: id,
            icon,
            preview,
            source_app,
            source_app_bundle_id,
            timestamp_unix: timestamp.timestamp(),
        })
    }
}

// Ensure Database is thread-safe
unsafe impl Send for Database {}
unsafe impl Sync for Database {}
