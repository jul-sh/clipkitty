//! ClipKitty FFI Interface Definition
//!
//! This file defines the public interface exposed to Swift via UniFFI.
//! It acts as the source of truth for shared types.

use thiserror::Error;

// ═══════════════════════════════════════════════════════════════════════════════
// ENUMS
// ═══════════════════════════════════════════════════════════════════════════════

/// SF Symbol icon type for content categories
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum IconType {
    Text,
    Link,
    Email,
    Phone,
    Image,
    Color,
    File,
}

/// File tracking status for clipboard file items
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FileStatus {
    Available,
    Moved { new_path: String },
    Trashed,
    Missing,
}

impl FileStatus {
    /// Convert to database string representation
    pub fn to_database_str(&self) -> String {
        match self {
            FileStatus::Available => "available".to_string(),
            FileStatus::Moved { new_path } => format!("moved:{}", new_path),
            FileStatus::Trashed => "trashed".to_string(),
            FileStatus::Missing => "missing".to_string(),
        }
    }

    /// Reconstruct from database string
    pub fn from_database_str(s: &str) -> Self {
        if let Some(path) = s.strip_prefix("moved:") {
            FileStatus::Moved { new_path: path.to_string() }
        } else {
            match s {
                "trashed" => FileStatus::Trashed,
                "missing" => FileStatus::Missing,
                _ => FileStatus::Available,
            }
        }
    }
}

/// Content type filter for narrowing search results
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ContentTypeFilter {
    All,
    Text,   // matches "text", "email", "phone"
    Images, // matches "image"
    Links,  // matches "link"
    Colors, // matches "color"
    Files,  // matches "file"
}

impl ContentTypeFilter {
    /// Returns the database content type strings this filter matches, or None for All.
    pub fn database_types(&self) -> Option<&[&str]> {
        match self {
            ContentTypeFilter::All => None,
            ContentTypeFilter::Text => Some(&["text", "email", "phone"]),
            ContentTypeFilter::Images => Some(&["image"]),
            ContentTypeFilter::Links => Some(&["link"]),
            ContentTypeFilter::Colors => Some(&["color"]),
            ContentTypeFilter::Files => Some(&["file"]),
        }
    }

    /// Check if a database content type string matches this filter.
    pub fn matches_db_type(&self, db_type: &str) -> bool {
        match self.database_types() {
            None => true,
            Some(types) => types.contains(&db_type),
        }
    }
}

/// Icon representation for list items
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ItemIcon {
    Symbol { icon_type: IconType },
    ColorSwatch { rgba: u32 },
    Thumbnail { bytes: Vec<u8> },
}

impl Default for ItemIcon {
    fn default() -> Self {
        ItemIcon::Symbol { icon_type: IconType::Text }
    }
}

impl ItemIcon {
    /// Determine icon from database fields
    pub fn from_database(
        db_type: &str,
        color_rgba: Option<u32>,
        thumbnail: Option<Vec<u8>>,
        link_image_data: Option<Vec<u8>>,
    ) -> Self {
        match db_type {
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
            "file" => {
                if let Some(thumb) = thumbnail {
                    ItemIcon::Thumbnail { bytes: thumb }
                } else {
                    ItemIcon::Symbol { icon_type: IconType::File }
                }
            }
            "email" => ItemIcon::Symbol { icon_type: IconType::Email },
            "phone" => ItemIcon::Symbol { icon_type: IconType::Phone },
            _ => ItemIcon::Symbol { icon_type: IconType::Text },
        }
    }
}

/// Link metadata fetch state
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LinkMetadataState {
    Pending,
    Loaded {
        title: Option<String>,
        description: Option<String>,
        image_data: Option<Vec<u8>>,
    },
    Failed,
}

impl LinkMetadataState {
    /// Convert to database fields (title, description, image_data)
    /// NULL title = pending, empty title = failed, otherwise = loaded
    pub fn to_database_fields(&self) -> (Option<String>, Option<String>, Option<Vec<u8>>) {
        match self {
            LinkMetadataState::Pending => (None, None, None),
            LinkMetadataState::Failed => (Some(String::new()), None, None),
            LinkMetadataState::Loaded { title, description, image_data } => {
                (
                    Some(title.clone().unwrap_or_default()),
                    description.clone(),
                    image_data.clone(),
                )
            }
        }
    }

    /// Reconstruct from database fields
    pub fn from_database(title: Option<&str>, description: Option<&str>, image_data: Option<Vec<u8>>) -> Self {
        match (title, &image_data) {
            (None, None) => LinkMetadataState::Pending,
            (Some(""), None) => LinkMetadataState::Failed,
            (Some(t), img) => LinkMetadataState::Loaded {
                title: if t.is_empty() { None } else { Some(t.to_string()) },
                description: description.filter(|d| !d.is_empty()).map(String::from),
                image_data: img.clone(),
            },
            // Has image but no title - still loaded (some sites only have images)
            (None, Some(img)) => LinkMetadataState::Loaded {
                title: None,
                description: description.filter(|d| !d.is_empty()).map(String::from),
                image_data: Some(img.clone()),
            },
        }
    }
}

/// Type-safe clipboard content representation
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ClipboardContent {
    Text { value: String },
    Color { value: String },
    Link { url: String, metadata_state: LinkMetadataState },
    Email { address: String },
    Phone { number: String },
    Image { data: Vec<u8>, description: String },
    File {
        path: String,
        filename: String,
        file_size: u64,
        uti: String,
        bookmark_data: Vec<u8>,
        file_status: FileStatus,
        file_count: u32,
        additional_files_json: String,
    },
}

impl ClipboardContent {
    /// The searchable/displayable text content
    pub fn text_content(&self) -> &str {
        match self {
            ClipboardContent::Text { value } => value,
            ClipboardContent::Color { value } => value,
            ClipboardContent::Link { url, .. } => url,
            ClipboardContent::Email { address } => address,
            ClipboardContent::Phone { number } => number,
            ClipboardContent::Image { description, .. } => description,
            ClipboardContent::File { filename, .. } => filename,
        }
    }

    /// Get the IconType for this content
    pub fn icon_type(&self) -> IconType {
        match self {
            ClipboardContent::Text { .. } => IconType::Text,
            ClipboardContent::Color { .. } => IconType::Color,
            ClipboardContent::Link { .. } => IconType::Link,
            ClipboardContent::Email { .. } => IconType::Email,
            ClipboardContent::Phone { .. } => IconType::Phone,
            ClipboardContent::Image { .. } => IconType::Image,
            ClipboardContent::File { .. } => IconType::File,
        }
    }

    /// Database storage type string
    pub fn database_type(&self) -> &str {
        match self {
            ClipboardContent::Text { .. } => "text",
            ClipboardContent::Color { .. } => "color",
            ClipboardContent::Link { .. } => "link",
            ClipboardContent::Email { .. } => "email",
            ClipboardContent::Phone { .. } => "phone",
            ClipboardContent::Image { .. } => "image",
            ClipboardContent::File { .. } => "file",
        }
    }

    /// Extract database fields: (content, image_data, link_title, link_description, link_image_data, color_rgba)
    pub fn to_database_fields(&self) -> (String, Option<Vec<u8>>, Option<String>, Option<String>, Option<Vec<u8>>, Option<u32>) {
        match self {
            ClipboardContent::Text { value } => (value.clone(), None, None, None, None, None),
            ClipboardContent::Color { value } => {
                let rgba = crate::content_detection::parse_color_to_rgba(value);
                (value.clone(), None, None, None, None, rgba)
            }
            ClipboardContent::Link { url, metadata_state } => {
                let (title, description, image_data) = metadata_state.to_database_fields();
                (url.clone(), None, title, description, image_data, None)
            }
            ClipboardContent::Email { address } => (address.clone(), None, None, None, None, None),
            ClipboardContent::Phone { number } => (number.clone(), None, None, None, None, None),
            ClipboardContent::Image { data, description } => {
                (description.clone(), Some(data.clone()), None, None, None, None)
            }
            ClipboardContent::File { filename, .. } => {
                // File stores filename in content column; other fields stored in dedicated columns
                (filename.clone(), None, None, None, None, None)
            }
        }
    }

    /// Reconstruct from database row
    pub fn from_database(
        db_type: &str,
        content: &str,
        image_data: Option<Vec<u8>>,
        link_title: Option<&str>,
        link_description: Option<&str>,
        link_image_data: Option<Vec<u8>>,
        _color_rgba: Option<u32>,
        file_path: Option<&str>,
        file_size: Option<u64>,
        file_uti: Option<&str>,
        bookmark_data: Option<Vec<u8>>,
        file_status_str: Option<&str>,
        file_count: Option<u32>,
        additional_files_json: Option<&str>,
    ) -> Self {
        match db_type {
            "color" => ClipboardContent::Color { value: content.to_string() },
            "link" => ClipboardContent::Link {
                url: content.to_string(),
                metadata_state: LinkMetadataState::from_database(link_title, link_description, link_image_data),
            },
            "image" => ClipboardContent::Image {
                data: image_data.unwrap_or_default(),
                description: content.to_string(),
            },
            "email" => ClipboardContent::Email {
                address: content.to_string(),
            },
            "phone" => ClipboardContent::Phone {
                number: content.to_string(),
            },
            "file" => ClipboardContent::File {
                path: file_path.unwrap_or("").to_string(),
                filename: content.to_string(),
                file_size: file_size.unwrap_or(0),
                uti: file_uti.unwrap_or("public.item").to_string(),
                bookmark_data: bookmark_data.unwrap_or_default(),
                file_status: FileStatus::from_database_str(file_status_str.unwrap_or("available")),
                file_count: file_count.unwrap_or(1),
                additional_files_json: additional_files_json.unwrap_or("").to_string(),
            },
            _ => ClipboardContent::Text { value: content.to_string() },
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// RECORDS (Structs)
// ═══════════════════════════════════════════════════════════════════════════════

/// The type of match that produced a highlight
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HighlightKind {
    Exact,
    Prefix,
    Fuzzy,
    Subsequence,
}

/// A highlight range (start, end) for search matches
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HighlightRange {
    pub start: u64,
    pub end: u64,
    pub kind: HighlightKind,
}

/// Match context data for search results
///
/// # Display Contract: Two-layer truncation with ellipsis
///
/// Both Rust and Swift may truncate, each adding their own ellipsis.
///
/// ## What Rust does (first pass - up to 400 chars):
/// - **Whitespace normalization**: Newlines, tabs, carriage returns → single spaces; consecutive spaces collapsed
/// - **Truncation ellipsis**: Prefixes "…" if truncated from start, suffixes "…" if truncated from end
/// - **Highlight adjustment**: Indices account for normalization AND leading ellipsis prefix (+1 if present)
///
/// ## What Swift does (second pass - ~50 visible chars):
/// - Windows `text` to ~50 characters, centered on `highlights[0]`
/// - Adds "…" prefix if window start > 0, adds "…" suffix if window end < text length
/// - Adjusts highlight indices: subtracts window start, adds 1 if Swift added prefix ellipsis
///
/// ## Example flow:
/// ```text
/// Original (500 chars):  "prefix...\n\n  code with    spaces and MATCH suffix..."
/// Rust output (70 chars): "…code with spaces and MATCH suffix…"  (normalized, truncated both ends)
/// Rust highlights: [25, 30] (adjusted for normalization +1 for leading ellipsis)
/// Swift windows (50 chars): "…paces and MATCH suffix…"  (further truncated, ellipsis on both ends)
/// Swift highlights: adjusted for window, +1 for Swift's prefix ellipsis
/// ```
#[derive(Debug, Clone, PartialEq, Default, uniffi::Record)]
pub struct MatchData {
    /// Snippet text with whitespace normalized, "…" prefix if Rust truncated from start, "…" suffix if Rust truncated from end
    pub text: String,
    /// Highlight ranges into `text`, adjusted for normalization and Rust's leading ellipsis prefix
    pub highlights: Vec<HighlightRange>,
    /// 1-indexed line number where the match occurs in the original content
    pub line_number: u64,
    /// Full-content highlights (not snippet-adjusted)
    /// Used for preview pane to ensure consistent highlighting
    pub full_content_highlights: Vec<HighlightRange>,
    /// Character offset (in full content) of the first highlight in the densest cluster.
    /// Used by Swift for preview pane auto-scrolling — same algorithm as snippet centering.
    pub densest_highlight_start: u64,
}

/// Lightweight item metadata for list display
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ItemMetadata {
    pub item_id: i64,
    pub icon: ItemIcon,
    pub snippet: String,
    pub source_app: Option<String>,
    pub source_app_bundle_id: Option<String>,
    pub timestamp_unix: i64,
}

/// Search match: metadata + match context
#[derive(Debug, Clone, uniffi::Record)]
pub struct ItemMatch {
    pub item_metadata: ItemMetadata,
    pub match_data: MatchData,
}

/// Search result container
#[derive(Debug, Clone, uniffi::Record)]
pub struct SearchResult {
    pub matches: Vec<ItemMatch>,
    pub total_count: u64,
    /// The first item's full content (avoids separate fetch for preview pane)
    pub first_item: Option<ClipboardItem>,
}

/// Full clipboard item for preview pane
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ClipboardItem {
    pub item_metadata: ItemMetadata,
    pub content: ClipboardContent,
}

/// Error type for ClipKitty operations
#[derive(Debug, Error, uniffi::Error)]
pub enum ClipKittyError {
    #[error("Database error: {0}")]
    DatabaseError(String),
    #[error("Index error: {0}")]
    IndexError(String),
    #[error("Store not initialized")]
    NotInitialized,
    #[error("Invalid input: {0}")]
    InvalidInput(String),
    #[error("Operation cancelled")]
    Cancelled,
}

// ═══════════════════════════════════════════════════════════════════════════════
// SERVICE INTERFACE
// ═══════════════════════════════════════════════════════════════════════════════

/// The primary interface for accessing the Clipboard ClipboardStore.
/// This matches the functionality exposed by the `ClipboardStore` object.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait ClipboardStoreApi: Send + Sync {
    // ─────────────────────────────────────────────────────────────────────────────
    // Read Operations
    // ─────────────────────────────────────────────────────────────────────────────

    /// Search for items. Empty query returns all recent items.
    async fn search(&self, query: String) -> Result<SearchResult, ClipKittyError>;

    /// Fetch full items by IDs for preview pane
    fn fetch_by_ids(&self, item_ids: Vec<i64>) -> Result<Vec<ClipboardItem>, ClipKittyError>;

    /// Get the database size in bytes
    fn database_size(&self) -> i64;

    // ─────────────────────────────────────────────────────────────────────────────
    // Write Operations
    // ─────────────────────────────────────────────────────────────────────────────

    /// Save a text item. Returns new item ID, or 0 if duplicate.
    fn save_text(&self, text: String, source_app: Option<String>, source_app_bundle_id: Option<String>) -> Result<i64, ClipKittyError>;

    /// Save an image item. Thumbnail should be generated by Swift (HEIC not supported by Rust).
    fn save_image(&self, image_data: Vec<u8>, thumbnail: Option<Vec<u8>>, source_app: Option<String>, source_app_bundle_id: Option<String>) -> Result<i64, ClipKittyError>;

    /// Save a file item. Returns new item ID, or 0 if duplicate.
    fn save_file(
        &self,
        path: String,
        filename: String,
        file_size: u64,
        uti: String,
        bookmark_data: Vec<u8>,
        thumbnail: Option<Vec<u8>>,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Result<i64, ClipKittyError>;

    /// Save multiple file items as a single grouped entry. Returns new item ID, or 0 if duplicate.
    fn save_files(
        &self,
        paths: Vec<String>,
        filenames: Vec<String>,
        file_sizes: Vec<u64>,
        utis: Vec<String>,
        bookmark_data_list: Vec<Vec<u8>>,
        thumbnail: Option<Vec<u8>>,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Result<i64, ClipKittyError>;

    /// Update file status (called from Swift when file move/delete detected)
    fn update_file_status(&self, item_id: i64, status: String, new_path: Option<String>) -> Result<(), ClipKittyError>;

    /// Update link metadata (called from Swift after LPMetadataProvider fetch)
    fn update_link_metadata(&self, item_id: i64, title: Option<String>, description: Option<String>, image_data: Option<Vec<u8>>) -> Result<(), ClipKittyError>;

    /// Update image description and re-index
    fn update_image_description(&self, item_id: i64, description: String) -> Result<(), ClipKittyError>;

    /// Update item timestamp to now
    fn update_timestamp(&self, item_id: i64) -> Result<(), ClipKittyError>;

    // ─────────────────────────────────────────────────────────────────────────────
    // Delete Operations
    // ─────────────────────────────────────────────────────────────────────────────

    /// Delete an item by ID from both database and index
    fn delete_item(&self, item_id: i64) -> Result<(), ClipKittyError>;

    /// Clear all items from database and index
    fn clear(&self) -> Result<(), ClipKittyError>;

    /// Prune old items to stay under max size. Returns count of deleted items.
    fn prune_to_size(&self, max_bytes: i64, keep_ratio: f64) -> Result<u64, ClipKittyError>;
}

impl From<crate::database::DatabaseError> for ClipKittyError {
    fn from(e: crate::database::DatabaseError) -> Self {
        ClipKittyError::DatabaseError(e.to_string())
    }
}

impl From<crate::indexer::IndexerError> for ClipKittyError {
    fn from(e: crate::indexer::IndexerError) -> Self {
        ClipKittyError::IndexError(e.to_string())
    }
}


