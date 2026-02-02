//! ClipKitty FFI Interface Definition
//!
//! This file documents the public interface exposed to Swift via UniFFI.
//! It mirrors what a UDL file would define - types and method signatures only.
//!
//! NOTE: This is documentation only. The actual implementations use
//! UniFFI proc-macros in their respective modules.

// ═══════════════════════════════════════════════════════════════════════════════
// ENUMS
// ═══════════════════════════════════════════════════════════════════════════════

/// SF Symbol icon type for content categories
/// [uniffi::Enum]
pub enum IconType {
    Text,
    Link,
    Email,
    Phone,
    Address,
    DateType,
    Transit,
    Image,
    Color,
}

/// Icon representation for list items
/// [uniffi::Enum]
pub enum ItemIcon {
    Symbol { icon_type: IconType },
    ColorSwatch { rgba: u32 },
    Thumbnail { bytes: Vec<u8> },
}

/// Link metadata fetch state
/// [uniffi::Enum]
pub enum LinkMetadataState {
    Pending,
    Loaded {
        title: Option<String>,
        image_data: Option<Vec<u8>>,
    },
    Failed,
}

/// Type-safe clipboard content representation
/// [uniffi::Enum]
pub enum ClipboardContent {
    Text { value: String },
    Color { value: String },
    Link { url: String, metadata_state: LinkMetadataState },
    Email { address: String },
    Phone { number: String },
    Address { value: String },
    Date { value: String },
    Transit { value: String },
    Image { data: Vec<u8>, description: String },
}

// ═══════════════════════════════════════════════════════════════════════════════
// RECORDS (Structs)
// ═══════════════════════════════════════════════════════════════════════════════

/// A highlight range (start, end) for search matches
/// [uniffi::Record]
pub struct HighlightRange {
    pub start: u64,
    pub end: u64,
}

/// Match context data for search results
/// [uniffi::Record]
pub struct MatchData {
    pub text: String,
    pub highlights: Vec<HighlightRange>,
    pub line_number: u64,
}

/// Lightweight item metadata for list display
/// [uniffi::Record]
pub struct ItemMetadata {
    pub item_id: i64,
    pub icon: ItemIcon,
    pub preview: String,
    pub source_app: Option<String>,
    pub source_app_bundle_id: Option<String>,
    pub timestamp_unix: i64,
}

/// Search match: metadata + match context
/// [uniffi::Record]
pub struct ItemMatch {
    pub item_metadata: ItemMetadata,
    pub match_data: MatchData,
}

/// Search result container
/// [uniffi::Record]
pub struct SearchResult {
    pub matches: Vec<ItemMatch>,
    pub total_count: u64,
}

/// Full clipboard item for preview pane
/// [uniffi::Record]
pub struct ClipboardItem {
    pub item_metadata: ItemMetadata,
    pub content: ClipboardContent,
    pub preview_highlights: Vec<HighlightRange>,
}

// ═══════════════════════════════════════════════════════════════════════════════
// ERROR TYPE
// ═══════════════════════════════════════════════════════════════════════════════

/// Error type for ClipKitty operations
/// [uniffi::Error]
pub enum ClipKittyError {
    DatabaseError(String),
    IndexError(String),
    NotInitialized,
    InvalidInput(String),
}

// ═══════════════════════════════════════════════════════════════════════════════
// OBJECT (ClipboardStore)
// ═══════════════════════════════════════════════════════════════════════════════

/// Thread-safe clipboard store with SQLite + Tantivy search
/// [uniffi::Object]
pub trait ClipboardStore {
    /// Create a new store with a database at the given path
    /// [uniffi::constructor]
    fn new(db_path: String) -> Result<Self, ClipKittyError>
    where
        Self: Sized;

    /// Get the database size in bytes
    fn database_size(&self) -> i64;

    /// Verify FTS integrity (always returns true with Tantivy)
    fn verify_fts_integrity(&self) -> bool;

    /// Save a text item to the database and index
    /// Returns the new item ID, or 0 if duplicate (timestamp updated)
    fn save_text(
        &self,
        text: String,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Result<i64, ClipKittyError>;

    /// Save an image item to the database
    /// Generates thumbnail automatically for preview
    fn save_image(
        &self,
        image_data: Vec<u8>,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Result<i64, ClipKittyError>;

    /// Update link metadata for an item
    fn update_link_metadata(
        &self,
        item_id: i64,
        title: Option<String>,
        image_data: Option<Vec<u8>>,
    ) -> Result<(), ClipKittyError>;

    /// Update image description and re-index
    fn update_image_description(
        &self,
        item_id: i64,
        description: String,
    ) -> Result<(), ClipKittyError>;

    /// Update item timestamp to now
    fn update_timestamp(&self, item_id: i64) -> Result<(), ClipKittyError>;

    /// Delete an item by ID from both database and index
    fn delete_item(&self, item_id: i64) -> Result<(), ClipKittyError>;

    /// Clear all items from database and index
    fn clear_all(&self) -> Result<(), ClipKittyError>;

    /// Prune old items to stay under max size
    fn prune_to_size(&self, max_bytes: i64, keep_ratio: f64) -> Result<u64, ClipKittyError>;

    /// Search for items - unified API for both browse and search modes
    /// Empty query returns recent items (browse mode)
    /// Non-empty query returns search results with highlights
    fn search(&self, query: String) -> Result<SearchResult, ClipKittyError>;

    /// Fetch full items by IDs for preview pane
    /// Includes highlights computed from optional search query
    fn fetch_by_ids(
        &self,
        ids: Vec<i64>,
        search_query: Option<String>,
    ) -> Result<Vec<ClipboardItem>, ClipKittyError>;
}

// ═══════════════════════════════════════════════════════════════════════════════
// FREE FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Check if text is a valid URL
/// [uniffi::export]
pub fn is_url(text: String) -> bool;
