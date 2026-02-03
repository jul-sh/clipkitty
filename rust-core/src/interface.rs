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
    Address,
    DateType,
    Transit,
    Image,
    Color,
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

/// Link metadata fetch state
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LinkMetadataState {
    Pending,
    Loaded {
        title: Option<String>,
        image_data: Option<Vec<u8>>,
    },
    Failed,
}

impl LinkMetadataState {
    /// Convert to database fields (title, image_data)
    /// NULL title = pending, empty title = failed, otherwise = loaded
    pub fn to_database_fields(&self) -> (Option<String>, Option<Vec<u8>>) {
        match self {
            LinkMetadataState::Pending => (None, None),
            LinkMetadataState::Failed => (Some(String::new()), None),
            LinkMetadataState::Loaded { title, image_data } => {
                (
                    Some(title.clone().unwrap_or_default()),
                    image_data.clone(),
                )
            }
        }
    }

    /// Reconstruct from database fields
    pub fn from_database(title: Option<&str>, image_data: Option<Vec<u8>>) -> Self {
        match (title, &image_data) {
            (None, None) => LinkMetadataState::Pending,
            (Some(""), None) => LinkMetadataState::Failed,
            (Some(t), img) => LinkMetadataState::Loaded {
                title: if t.is_empty() { None } else { Some(t.to_string()) },
                image_data: img.clone(),
            },
            (None, Some(_)) => LinkMetadataState::Pending,
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
    Address { value: String },
    Date { value: String },
    Transit { value: String },
    Image { data: Vec<u8>, description: String },
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
            ClipboardContent::Address { value } => value,
            ClipboardContent::Date { value } => value,
            ClipboardContent::Transit { value } => value,
            ClipboardContent::Image { description, .. } => description,
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
            ClipboardContent::Address { .. } => IconType::Address,
            ClipboardContent::Date { .. } => IconType::DateType,
            ClipboardContent::Transit { .. } => IconType::Transit,
            ClipboardContent::Image { .. } => IconType::Image,
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
            ClipboardContent::Address { .. } => "address",
            ClipboardContent::Date { .. } => "date",
            ClipboardContent::Transit { .. } => "transit",
            ClipboardContent::Image { .. } => "image",
        }
    }

    /// Extract database fields: (content, image_data, link_title, link_image_data, color_rgba)
    pub fn to_database_fields(&self) -> (String, Option<Vec<u8>>, Option<String>, Option<Vec<u8>>, Option<u32>) {
        match self {
            ClipboardContent::Text { value } => (value.clone(), None, None, None, None),
            ClipboardContent::Color { value } => {
                let rgba = crate::content_detection::parse_color_to_rgba(value);
                (value.clone(), None, None, None, rgba)
            }
            ClipboardContent::Link { url, metadata_state } => {
                let (title, image_data) = metadata_state.to_database_fields();
                (url.clone(), None, title, image_data, None)
            }
            ClipboardContent::Email { address } => (address.clone(), None, None, None, None),
            ClipboardContent::Phone { number } => (number.clone(), None, None, None, None),
            ClipboardContent::Address { value } => (value.clone(), None, None, None, None),
            ClipboardContent::Date { value } => (value.clone(), None, None, None, None),
            ClipboardContent::Transit { value } => (value.clone(), None, None, None, None),
            ClipboardContent::Image { data, description } => {
                (description.clone(), Some(data.clone()), None, None, None)
            }
        }
    }

    /// Reconstruct from database row
    pub fn from_database(
        db_type: &str,
        content: &str,
        image_data: Option<Vec<u8>>,
        link_title: Option<&str>,
        link_image_data: Option<Vec<u8>>,
        _color_rgba: Option<u32>,
    ) -> Self {
        match db_type {
            "color" => ClipboardContent::Color { value: content.to_string() },
            "link" => ClipboardContent::Link {
                url: content.to_string(),
                metadata_state: LinkMetadataState::from_database(link_title, link_image_data),
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
            "address" => ClipboardContent::Address { value: content.to_string() },
            "date" => ClipboardContent::Date { value: content.to_string() },
            "transit" => ClipboardContent::Transit { value: content.to_string() },
            _ => ClipboardContent::Text { value: content.to_string() },
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// RECORDS (Structs)
// ═══════════════════════════════════════════════════════════════════════════════

/// A highlight range (start, end) for search matches
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HighlightRange {
    pub start: u64,
    pub end: u64,
}

/// Match context data for search results
#[derive(Debug, Clone, PartialEq, Default, uniffi::Record)]
pub struct MatchData {
    pub text: String,
    pub highlights: Vec<HighlightRange>,
    pub line_number: u64,
    /// Full-content highlights from Nucleo (not snippet-adjusted)
    /// Used for preview pane to ensure consistent highlighting
    pub full_content_highlights: Vec<HighlightRange>,
}

/// Lightweight item metadata for list display
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ItemMetadata {
    pub item_id: i64,
    pub icon: ItemIcon,
    pub preview: String,
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
    pub preview_highlights: Vec<HighlightRange>,
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
    fn save_text(&self, text: String, source_app: Option<String>, source_app_bundle_id: Option<String>) -> Result<i64, ClipKittyError>;
    async fn search(&self, query: String) -> Result<SearchResult, ClipKittyError>;
    fn fetch_by_ids(&self, item_ids: Vec<i64>, search_query: Option<String>) -> Result<Vec<ClipboardItem>, ClipKittyError>;
    fn delete_item(&self, item_id: i64) -> Result<(), ClipKittyError>;
    fn clear(&self) -> Result<(), ClipKittyError>;
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


