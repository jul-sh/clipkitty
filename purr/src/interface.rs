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
            FileStatus::Moved {
                new_path: path.to_string(),
            }
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ContentTypeFilter {
    All,
    Text,   // matches "text"
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
            ContentTypeFilter::Text => Some(&["text"]),
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

/// Typed item tags stored in the database.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ItemTag {
    Bookmark,
}

impl ItemTag {
    pub fn database_str(&self) -> &'static str {
        match self {
            // Keep "pinned" for database backwards compatibility
            ItemTag::Bookmark => "pinned",
        }
    }

    pub fn from_database_str(value: &str) -> Result<Self, String> {
        match value {
            // Accept "pinned" from database for backwards compatibility
            "pinned" => Ok(ItemTag::Bookmark),
            other => Err(format!("unknown item tag `{other}`")),
        }
    }
}

/// Presentation profile for list surfaces.
///
/// Selects how Rust formats row excerpts for the calling UI.
/// Compact rows collapse all whitespace into a single line; cards preserve
/// meaningful line breaks for multiline display.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ListPresentationProfile {
    CompactRow,
    Card,
}

/// Mutually exclusive search filters for the browser.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ItemQueryFilter {
    All,
    ContentType { content_type: ContentTypeFilter },
    Tagged { tag: ItemTag },
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
        ItemIcon::Symbol {
            icon_type: IconType::Text,
        }
    }
}

impl ItemIcon {
    /// Determine icon from database fields.
    /// `thumbnail` is the unified thumbnail column — covers images, files, AND link preview images.
    pub fn from_database(
        db_type: &str,
        color_rgba: Option<u32>,
        thumbnail: Option<Vec<u8>>,
    ) -> Self {
        match db_type {
            "color" => {
                if let Some(rgba) = color_rgba {
                    ItemIcon::ColorSwatch { rgba }
                } else {
                    ItemIcon::Symbol {
                        icon_type: IconType::Color,
                    }
                }
            }
            "link" => ItemIcon::Symbol {
                icon_type: IconType::Link,
            },
            "image" | "file" => {
                if let Some(thumb) = thumbnail {
                    ItemIcon::Thumbnail { bytes: thumb }
                } else {
                    let icon_type = match db_type {
                        "image" => IconType::Image,
                        _ => IconType::File,
                    };
                    ItemIcon::Symbol { icon_type }
                }
            }
            _ => ItemIcon::Symbol {
                icon_type: IconType::Text,
            },
        }
    }
}

/// Legal payloads for a successful link metadata fetch.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LinkMetadataPayload {
    TitleOnly {
        title: String,
        description: Option<String>,
    },
    ImageOnly {
        image_data: Vec<u8>,
        description: Option<String>,
    },
    TitleAndImage {
        title: String,
        image_data: Vec<u8>,
        description: Option<String>,
    },
}

/// Link metadata fetch state
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LinkMetadataState {
    Pending,
    Loaded { payload: LinkMetadataPayload },
    Failed,
}

impl LinkMetadataPayload {
    fn normalized_description(description: Option<&str>) -> Option<String> {
        description
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(String::from)
    }
}

impl LinkMetadataState {
    /// Convert to database fields (title, description, image_data)
    /// NULL title = pending, empty title = failed, otherwise = loaded.
    pub fn to_database_fields(&self) -> (Option<String>, Option<String>, Option<Vec<u8>>) {
        match self {
            LinkMetadataState::Pending => (None, None, None),
            LinkMetadataState::Failed => (Some(String::new()), None, None),
            LinkMetadataState::Loaded { payload } => match payload {
                LinkMetadataPayload::TitleOnly { title, description } => {
                    (Some(title.clone()), description.clone(), None)
                }
                LinkMetadataPayload::ImageOnly {
                    image_data,
                    description,
                } => (None, description.clone(), Some(image_data.clone())),
                LinkMetadataPayload::TitleAndImage {
                    title,
                    image_data,
                    description,
                } => (
                    Some(title.clone()),
                    description.clone(),
                    Some(image_data.clone()),
                ),
            },
        }
    }

    /// Reconstruct from database fields, surfacing invalid combinations instead of
    /// silently coercing them into another state.
    pub fn from_database(
        title: Option<&str>,
        description: Option<&str>,
        image_data: Option<Vec<u8>>,
    ) -> Result<Self, String> {
        let normalized_title = title
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(String::from);
        let normalized_description = LinkMetadataPayload::normalized_description(description);

        match (title, normalized_title, normalized_description, image_data) {
            (None, None, None, None) => Ok(LinkMetadataState::Pending),
            (Some(""), None, None, None) => Ok(LinkMetadataState::Failed),
            (Some(raw_title), None, _, Some(_)) if raw_title.trim().is_empty() => {
                Err("failed link metadata row unexpectedly stored image data".to_string())
            }
            (Some(raw_title), None, Some(_), None) if raw_title.trim().is_empty() => {
                Err("failed link metadata row unexpectedly stored description".to_string())
            }
            (Some(_), Some(title), description, None) => Ok(LinkMetadataState::Loaded {
                payload: LinkMetadataPayload::TitleOnly { title, description },
            }),
            (None, None, description, Some(image_data)) => Ok(LinkMetadataState::Loaded {
                payload: LinkMetadataPayload::ImageOnly {
                    image_data,
                    description,
                },
            }),
            (Some(_), Some(title), description, Some(image_data)) => {
                Ok(LinkMetadataState::Loaded {
                    payload: LinkMetadataPayload::TitleAndImage {
                        title,
                        image_data,
                        description,
                    },
                })
            }
            (None, None, Some(_), None) => {
                Err("link metadata row stored a description without a title or image".to_string())
            }
            (None, Some(_), _, _) => Err(
                "link metadata row normalized to a title without an underlying title column"
                    .to_string(),
            ),
            (Some(raw_title), None, _, None) => Err(format!(
                "link metadata row stored an invalid title value `{raw_title}`"
            )),
            (Some(raw_title), None, _, Some(_)) => Err(format!(
                "link metadata row stored an invalid title value `{raw_title}`"
            )),
        }
    }
}

/// A single file entry within a file clipboard item.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FileEntry {
    pub path: String,
    pub filename: String,
    pub file_size: u64,
    pub uti: String,
    pub bookmark_data: Vec<u8>,
    pub file_status: FileStatus,
}

/// Type-safe clipboard content representation
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ClipboardContent {
    Text {
        value: String,
    },
    Color {
        value: String,
    },
    Link {
        url: String,
        metadata_state: LinkMetadataState,
    },
    Image {
        data: Vec<u8>,
        description: String,
        is_animated: bool,
    },
    File {
        display_name: String,
        files: Vec<FileEntry>,
    },
}

impl ClipboardContent {
    /// The searchable/displayable text content
    pub fn text_content(&self) -> &str {
        match self {
            ClipboardContent::Text { value } => value,
            ClipboardContent::Color { value } => value,
            ClipboardContent::Link { url, .. } => url,
            ClipboardContent::Image { description, .. } => description,
            ClipboardContent::File { display_name, .. } => display_name,
        }
    }

    /// Get the IconType for this content
    pub fn icon_type(&self) -> IconType {
        match self {
            ClipboardContent::Text { .. } => IconType::Text,
            ClipboardContent::Color { .. } => IconType::Color,
            ClipboardContent::Link { .. } => IconType::Link,
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
            ClipboardContent::Image { .. } => "image",
            ClipboardContent::File { .. } => "file",
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
    PrefixTail,
    SubwordPrefix,
    Substring,
    Fuzzy,
    Subsequence,
}

/// A UTF-16 highlight range for UI rendering.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Utf16HighlightRange {
    pub utf16_start: u64,
    pub utf16_end: u64,
    pub kind: HighlightKind,
}

/// Query-independent excerpt for list surfaces.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BaselineExcerpt {
    pub text: String,
}

/// Matched excerpt data for list surfaces (compact rows and cards).
///
/// # Display Contract: Two-layer truncation with ellipsis
///
/// Both Rust and Swift may truncate, each adding their own ellipsis.
///
/// ## What Rust does (first pass):
/// - **CompactRow**: Newlines/tabs/returns → single spaces; consecutive spaces collapsed (up to 400 chars)
/// - **Card**: Preserves meaningful line breaks; collapses pathological whitespace (up to 800 chars)
/// - **Truncation ellipsis**: Prefixes "…" if truncated from start, suffixes "…" if truncated from end
/// - **Highlight adjustment**: Indices account for normalization AND leading ellipsis prefix (+1 if present)
///
/// ## What Swift does (second pass):
/// - CompactRow: windows `text` to ~50 characters, centered on `highlights[0]`
/// - Card: clamps to N visible lines (e.g. 8 on iPhone)
/// - Adds "…" prefix if window start > 0, adds "…" suffix if window end < text length
/// - Adjusts highlight indices: subtracts window start, adds 1 if Swift added prefix ellipsis
#[derive(Debug, Clone, PartialEq, Default, uniffi::Record)]
pub struct MatchedExcerpt {
    /// Excerpt text. CompactRow: whitespace-normalized single line. Card: multiline-friendly.
    pub text: String,
    /// Highlight ranges into `text`, adjusted for normalization and leading ellipsis prefix.
    pub highlights: Vec<Utf16HighlightRange>,
    /// 1-indexed line number where the match occurs in the original content
    pub line_number: u64,
}

/// Request needed to resolve a deferred matched excerpt.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MatchedExcerptRequest {
    pub item_id: String,
    pub query: String,
    pub presentation_profile: ListPresentationProfile,
    /// Guards against resolving stale requests after the item content changed.
    pub content_hash: String,
}

/// Why a matched excerpt could not be produced.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ExcerptUnavailableReason {
    ItemMissing,
    ContentChanged,
    EmptyQuery,
}

/// Explicit placeholder to render while a matched excerpt is deferred.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ExcerptPlaceholder {
    Baseline {
        excerpt: BaselineExcerpt,
    },
    CompatibleCached {
        source_query: String,
        excerpt: MatchedExcerpt,
    },
    Provisional {
        excerpt: BaselineExcerpt,
    },
}

/// Complete row presentation state.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum RowPresentation {
    Baseline {
        excerpt: BaselineExcerpt,
    },
    Matched {
        excerpt: MatchedExcerpt,
    },
    Deferred {
        request: MatchedExcerptRequest,
        placeholder: ExcerptPlaceholder,
    },
    Unavailable {
        fallback: BaselineExcerpt,
        reason: ExcerptUnavailableReason,
    },
}

/// Result of resolving a deferred matched excerpt request.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum MatchedExcerptResolution {
    Ready {
        item_id: String,
        excerpt: MatchedExcerpt,
    },
    Unavailable {
        item_id: String,
        reason: ExcerptUnavailableReason,
    },
}

/// Preview-only highlight decoration for the full item content.
#[derive(Debug, Clone, PartialEq, Default, uniffi::Record)]
pub struct PreviewDecoration {
    pub highlights: Vec<Utf16HighlightRange>,
    /// Index into `highlights` used as the initial scroll target.
    pub initial_scroll_highlight_index: Option<u64>,
}

/// Atomic preview payload for rendering a selected item.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PreviewPayload {
    pub item: ClipboardItem,
    pub decoration: Option<PreviewDecoration>,
}

/// Lightweight item metadata for list display
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ItemMetadata {
    pub item_id: String,
    pub icon: ItemIcon,
    pub source_app: Option<String>,
    pub source_app_bundle_id: Option<String>,
    pub timestamp_unix: i64,
    pub tags: Vec<ItemTag>,
}

/// Search match: metadata + match context
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ItemMatch {
    pub item_metadata: ItemMetadata,
    pub presentation: RowPresentation,
}

/// Search result container
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SearchResult {
    pub matches: Vec<ItemMatch>,
    pub total_count: u64,
    /// The first item's preview payload (avoids separate preview loading for the initial selection)
    pub first_preview_payload: Option<PreviewPayload>,
}

/// Terminal outcome for an explicit search operation.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum SearchOutcome {
    Success { result: SearchResult },
    Cancelled,
}

/// Explicit bootstrap plan for opening the store.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum StoreBootstrapPlan {
    Ready,
    RebuildIndex,
}

/// Full clipboard item for preview pane
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ClipboardItem {
    pub item_metadata: ItemMetadata,
    pub content: ClipboardContent,
}

// ═══════════════════════════════════════════════════════════════════════════════
// SYNC TYPES (exposed to Swift for SyncEngine)
// ═══════════════════════════════════════════════════════════════════════════════

/// A serialized sync event ready for CloudKit transport.
#[cfg(feature = "sync")]
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SyncEventRecord {
    pub event_id: String,
    pub item_id: String,
    pub origin_device_id: String,
    pub schema_version: u32,
    pub recorded_at: i64,
    pub payload_type: String,
    pub payload_data: String,
}

/// A serialized sync snapshot ready for CloudKit transport.
#[cfg(feature = "sync")]
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SyncSnapshotRecord {
    pub item_id: String,
    pub snapshot_revision: u64,
    pub schema_version: u32,
    pub covers_through_event: Option<String>,
    pub aggregate_data: String,
}

/// Result of applying a remote event.
#[cfg(feature = "sync")]
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum SyncApplyOutcome {
    Applied,
    Ignored,
    Deferred,
    Forked { forked_snapshot_data: String },
}

/// Result of applying a batch of remote events.
#[cfg(feature = "sync")]
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SyncBatchResult {
    pub events_applied: u64,
    pub events_ignored: u64,
    pub events_deferred: u64,
    pub events_forked: u64,
    pub snapshots_applied: u64,
    pub needs_full_resync: bool,
}

/// Device sync state.
#[cfg(feature = "sync")]
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SyncDeviceState {
    pub device_id: String,
    pub zone_change_token: Option<Vec<u8>>,
    pub needs_full_resync: bool,
    pub index_dirty: bool,
}

/// Outcome of a compaction run.
#[cfg(feature = "sync")]
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CompactionResult {
    pub items_compacted: u64,
    pub events_purged: u64,
    pub tombstones_purged: u64,
}

/// Outcome of applying a downloaded batch of remote changes.
/// Determines whether the CloudKit zone change token should be advanced.
#[cfg(feature = "sync")]
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum SyncDownloadBatchOutcome {
    Applied {
        events_applied: u64,
        snapshots_applied: u64,
    },
    PartialFailure {
        applied_count: u64,
        failed_count: u64,
        should_retry: bool,
    },
    FullResyncRequired,
}

/// Whether a checkpoint has been replicated to CloudKit.
#[cfg(feature = "sync")]
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum SyncCheckpointState {
    Absent,
    LocalOnly {
        covers_through_event: String,
    },
    Uploaded {
        covers_through_event: String,
        uploaded_at: i64,
    },
}

/// Result of a full resync operation (checkpoints + tail events).
#[cfg(feature = "sync")]
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SyncFullResyncResult {
    pub checkpoints_applied: u64,
    pub tail_events_applied: u64,
    pub tail_events_ignored: u64,
    pub tail_events_deferred: u64,
    pub tail_events_forked: u64,
}

/// Error type for ClipKitty operations
#[derive(Debug, Clone, Error, PartialEq, uniffi::Error)]
pub enum ClipKittyError {
    #[error("Database error: {0}")]
    DatabaseError(String),
    #[error("Database inconsistency: {0}")]
    DataInconsistency(String),
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
    async fn search(
        &self,
        query: String,
        presentation: ListPresentationProfile,
    ) -> Result<SearchResult, ClipKittyError>;

    /// Search with a typed filter scope.
    async fn search_filtered(
        &self,
        query: String,
        filter: ItemQueryFilter,
        presentation: ListPresentationProfile,
    ) -> Result<SearchResult, ClipKittyError>;

    /// Resolve deferred matched excerpts for visible rows.
    fn resolve_matched_excerpts(
        &self,
        requests: Vec<MatchedExcerptRequest>,
    ) -> Result<Vec<MatchedExcerptResolution>, ClipKittyError>;

    /// Load the preview payload for a single item given the search query.
    fn load_preview_payload(
        &self,
        item_id: String,
        query: String,
    ) -> Result<Option<PreviewPayload>, ClipKittyError>;

    /// Fetch full items by IDs for preview pane
    fn fetch_by_ids(&self, item_ids: Vec<String>) -> Result<Vec<ClipboardItem>, ClipKittyError>;

    /// Get the database size in bytes
    fn database_size(&self) -> i64;

    // ─────────────────────────────────────────────────────────────────────────────
    // Write Operations
    // ─────────────────────────────────────────────────────────────────────────────

    /// Save a text item. Returns new item's stable ID, or empty string if duplicate.
    fn save_text(
        &self,
        text: String,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Result<String, ClipKittyError>;

    /// Save an image item. Thumbnail should be generated by Swift (HEIC not supported by Rust).
    fn save_image(
        &self,
        image_data: Vec<u8>,
        thumbnail: Option<Vec<u8>>,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
        is_animated: bool,
    ) -> Result<String, ClipKittyError>;

    /// Save a file item. Returns new item's stable ID, or empty string if duplicate.
    #[allow(clippy::too_many_arguments)]
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
    ) -> Result<String, ClipKittyError>;

    /// Save multiple file items as a single grouped entry. Returns new item's stable ID, or empty string if duplicate.
    #[allow(clippy::too_many_arguments)]
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
    ) -> Result<String, ClipKittyError>;

    /// Update link metadata (called from Swift after LPMetadataProvider fetch)
    fn update_link_metadata(
        &self,
        item_id: String,
        title: Option<String>,
        description: Option<String>,
        image_data: Option<Vec<u8>>,
    ) -> Result<(), ClipKittyError>;

    /// Update image description and re-index
    fn update_image_description(
        &self,
        item_id: String,
        description: String,
    ) -> Result<(), ClipKittyError>;

    /// Update text item content in-place and re-index
    fn update_text_item(&self, item_id: String, text: String) -> Result<(), ClipKittyError>;

    /// Update item timestamp to now
    fn update_timestamp(&self, item_id: String) -> Result<(), ClipKittyError>;

    /// Add a tag to an item. Idempotent.
    fn add_tag(&self, item_id: String, tag: ItemTag) -> Result<(), ClipKittyError>;

    /// Remove a tag from an item.
    fn remove_tag(&self, item_id: String, tag: ItemTag) -> Result<(), ClipKittyError>;

    // ─────────────────────────────────────────────────────────────────────────────
    // Delete Operations
    // ─────────────────────────────────────────────────────────────────────────────

    /// Delete an item by ID from both database and index
    fn delete_item(&self, item_id: String) -> Result<(), ClipKittyError>;

    /// Clear all items from database and index
    fn clear(&self) -> Result<(), ClipKittyError>;

    /// Prune old items to stay under max size. Returns count of deleted items.
    fn prune_to_size(&self, max_bytes: i64, keep_ratio: f64) -> Result<u64, ClipKittyError>;
}

impl From<crate::database::DatabaseError> for ClipKittyError {
    fn from(e: crate::database::DatabaseError) -> Self {
        match e {
            crate::database::DatabaseError::Interrupted => ClipKittyError::Cancelled,
            crate::database::DatabaseError::InconsistentData(message) => {
                ClipKittyError::DataInconsistency(message)
            }
            other => ClipKittyError::DatabaseError(other.to_string()),
        }
    }
}

impl From<crate::indexer::IndexerError> for ClipKittyError {
    fn from(e: crate::indexer::IndexerError) -> Self {
        ClipKittyError::IndexError(e.to_string())
    }
}

#[cfg(feature = "sync")]
impl From<purr_sync::SyncError> for ClipKittyError {
    fn from(e: purr_sync::SyncError) -> Self {
        match e {
            purr_sync::SyncError::InconsistentData(msg) => ClipKittyError::DataInconsistency(msg),
            other => ClipKittyError::DatabaseError(other.to_string()),
        }
    }
}
