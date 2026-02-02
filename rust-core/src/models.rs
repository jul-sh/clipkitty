//! Core data models for ClipKitty
//!
//! These models are designed for UniFFI export to Swift.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

// ─────────────────────────────────────────────────────────────────────────────
// ICON TYPES
// ─────────────────────────────────────────────────────────────────────────────

/// SF Symbol icon type for content categories
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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

impl IconType {
    /// Get the SF Symbol name for this icon type
    pub fn sf_symbol(&self) -> &'static str {
        match self {
            IconType::Text => "doc.text",
            IconType::Link => "link",
            IconType::Email => "envelope",
            IconType::Phone => "phone",
            IconType::Address => "map",
            IconType::DateType => "calendar",
            IconType::Transit => "tram",
            IconType::Image => "photo",
            IconType::Color => "paintpalette",
        }
    }
}

/// Icon representation - can be an SF Symbol, a color swatch, or a thumbnail
#[derive(Debug, Clone, PartialEq)]
pub enum ItemIcon {
    /// SF Symbol icon
    Symbol { icon_type: IconType },
    /// Color swatch (RGBA as u32: 0xRRGGBBAA)
    ColorSwatch { rgba: u32 },
    /// Thumbnail image bytes (small preview for images)
    Thumbnail { bytes: Vec<u8> },
}

impl Default for ItemIcon {
    fn default() -> Self {
        ItemIcon::Symbol { icon_type: IconType::Text }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// CONTENT TYPES
// ─────────────────────────────────────────────────────────────────────────────

/// Link metadata fetch state
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkMetadataState {
    /// Metadata not yet fetched
    Pending,
    /// Metadata successfully fetched
    Loaded {
        title: Option<String>,
        image_data: Option<Vec<u8>>,
    },
    /// Metadata fetch failed
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

/// Type-safe content representation
#[derive(Debug, Clone, PartialEq)]
pub enum ClipboardContent {
    Text { value: String },
    Color { value: String },
    Link {
        url: String,
        metadata_state: LinkMetadataState,
    },
    Email { address: String },
    Phone { number: String },
    Address { value: String },
    Date { value: String },
    Transit { value: String },
    Image {
        data: Vec<u8>,
        description: String,
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

// ─────────────────────────────────────────────────────────────────────────────
// ITEM METADATA & MATCHES
// ─────────────────────────────────────────────────────────────────────────────

/// A highlight range (start, end) in the text
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HighlightRange {
    pub start: u64,
    pub end: u64,
}

/// Match context data - the text snippet, highlights, and line info
#[derive(Debug, Clone, PartialEq)]
pub struct MatchData {
    pub text: String,
    pub highlights: Vec<HighlightRange>,
    pub line_number: u64,
}

impl Default for MatchData {
    fn default() -> Self {
        MatchData {
            text: String::new(),
            highlights: Vec::new(),
            line_number: 0,
        }
    }
}

/// Lightweight item metadata for list display
#[derive(Debug, Clone, PartialEq)]
pub struct ItemMetadata {
    pub item_id: i64,
    pub icon: ItemIcon,
    pub preview: String,
    pub source_app: Option<String>,
    pub source_app_bundle_id: Option<String>,
    pub timestamp_unix: i64,
}

/// Search match: metadata + match context
#[derive(Debug, Clone)]
pub struct ItemMatch {
    pub item_metadata: ItemMetadata,
    pub match_data: MatchData,
}

// ─────────────────────────────────────────────────────────────────────────────
// RESULT TYPES
// ─────────────────────────────────────────────────────────────────────────────

/// Initial fetch result (no search query) - just metadata for display
#[derive(Debug, Clone)]
pub struct FetchResults {
    pub items: Vec<ItemMetadata>,
    pub total_count: u64,
    pub has_more: bool,
}

/// Search result with matches (metadata + match highlights)
#[derive(Debug, Clone)]
pub struct SearchResult {
    pub matches: Vec<ItemMatch>,
    pub total_count: u64,
}

/// Full clipboard item for preview pane
#[derive(Debug, Clone, PartialEq)]
pub struct ClipboardItem {
    pub item_metadata: ItemMetadata,
    pub content: ClipboardContent,
    pub preview_highlights: Vec<HighlightRange>,
}

// ─────────────────────────────────────────────────────────────────────────────
// INTERNAL ITEM (not exposed via FFI, used for storage)
// ─────────────────────────────────────────────────────────────────────────────

/// Internal clipboard item representation for database storage
#[derive(Debug, Clone, PartialEq)]
pub struct StoredItem {
    pub id: Option<i64>,
    pub content: ClipboardContent,
    pub content_hash: String,
    pub timestamp_unix: i64,
    pub source_app: Option<String>,
    pub source_app_bundle_id: Option<String>,
    /// Thumbnail for images (small preview, stored separately from full image)
    pub thumbnail: Option<Vec<u8>>,
    /// Parsed color RGBA for color content (stored for quick display)
    pub color_rgba: Option<u32>,
}

impl StoredItem {
    /// Create a new text item (auto-detects structured content)
    pub fn new_text(
        text: String,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Self {
        let content_hash = Self::hash_string(&text);
        let content = crate::content_detection::detect_content(&text);
        let color_rgba = if let ClipboardContent::Color { ref value } = content {
            crate::content_detection::parse_color_to_rgba(value)
        } else {
            None
        };
        Self {
            id: None,
            content,
            content_hash,
            timestamp_unix: chrono::Utc::now().timestamp(),
            source_app,
            source_app_bundle_id,
            thumbnail: None,
            color_rgba,
        }
    }

    /// Create an explicit link item
    pub fn new_link(
        url: String,
        metadata_state: LinkMetadataState,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Self {
        let content_hash = Self::hash_string(&url);
        Self {
            id: None,
            content: ClipboardContent::Link { url, metadata_state },
            content_hash,
            timestamp_unix: chrono::Utc::now().timestamp(),
            source_app,
            source_app_bundle_id,
            thumbnail: None,
            color_rgba: None,
        }
    }

    /// Create an image item
    pub fn new_image(
        image_data: Vec<u8>,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Self {
        Self::new_image_with_description(image_data, "Image".to_string(), source_app, source_app_bundle_id)
    }

    /// Create an image item with a custom description (for searchability)
    pub fn new_image_with_description(
        image_data: Vec<u8>,
        description: String,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Self {
        let hash_input = format!("{}{}", description, image_data.len());
        let content_hash = Self::hash_string(&hash_input);
        // Generate thumbnail (max 64x64, JPEG quality 60)
        let thumbnail = generate_thumbnail(&image_data, 64);
        Self {
            id: None,
            content: ClipboardContent::Image {
                data: image_data,
                description,
            },
            content_hash,
            timestamp_unix: chrono::Utc::now().timestamp(),
            source_app,
            source_app_bundle_id,
            thumbnail,
            color_rgba: None,
        }
    }

    /// Get the raw text content for searching and display
    pub fn text_content(&self) -> &str {
        self.content.text_content()
    }

    /// Get the icon type for the content
    pub fn icon_type(&self) -> IconType {
        self.content.icon_type()
    }

    /// Get the ItemIcon for display
    pub fn item_icon(&self) -> ItemIcon {
        match &self.content {
            ClipboardContent::Color { value } => {
                let rgba = self.color_rgba
                    .or_else(|| crate::content_detection::parse_color_to_rgba(value))
                    .unwrap_or(0xFF000000);
                ItemIcon::ColorSwatch { rgba }
            }
            ClipboardContent::Image { .. } => {
                if let Some(ref thumb) = self.thumbnail {
                    ItemIcon::Thumbnail { bytes: thumb.clone() }
                } else {
                    ItemIcon::Symbol { icon_type: IconType::Image }
                }
            }
            _ => ItemIcon::Symbol { icon_type: self.icon_type() },
        }
    }

    /// Stable identifier for UI
    pub fn stable_id(&self) -> String {
        self.id
            .map(|id| id.to_string())
            .unwrap_or_else(|| self.content_hash.clone())
    }

    /// Display text (truncated, normalized whitespace) for preview
    pub fn display_text(&self, max_chars: usize) -> String {
        normalize_preview(&self.text_content(), max_chars)
    }

    /// Convert to ItemMetadata for list display
    pub fn to_metadata(&self) -> ItemMetadata {
        ItemMetadata {
            item_id: self.id.unwrap_or(0),
            icon: self.item_icon(),
            preview: self.display_text(200),
            source_app: self.source_app.clone(),
            source_app_bundle_id: self.source_app_bundle_id.clone(),
            timestamp_unix: self.timestamp_unix,
        }
    }

    /// Convert to full ClipboardItem for preview pane
    pub fn to_clipboard_item(&self, highlights: Vec<HighlightRange>) -> ClipboardItem {
        ClipboardItem {
            item_metadata: self.to_metadata(),
            content: self.content.clone(),
            preview_highlights: highlights,
        }
    }

    /// Hash a string using Rust's default hasher
    fn hash_string(s: &str) -> String {
        let mut hasher = DefaultHasher::new();
        s.hash(&mut hasher);
        hasher.finish().to_string()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// TEXT NORMALIZATION
// ─────────────────────────────────────────────────────────────────────────────

/// Normalize text for preview display (truncate, normalize whitespace)
/// - Skips leading whitespace
/// - Collapses consecutive whitespace to single space
/// - Converts newlines/tabs to spaces
/// - Truncates at max_chars with ellipsis
/// - Trims trailing spaces
pub fn normalize_preview(text: &str, max_chars: usize) -> String {
    let mut result = String::with_capacity(max_chars + 1);
    let mut chars = text.chars().peekable();

    // Skip leading whitespace
    while chars.peek().map(|c| c.is_whitespace()).unwrap_or(false) {
        chars.next();
    }

    let mut last_was_space = false;
    let mut count = 0;

    for ch in chars {
        if count >= max_chars {
            result.push('…');
            return result;
        }

        let ch = match ch {
            '\n' | '\t' | '\r' => ' ',
            c => c,
        };

        if ch == ' ' {
            if last_was_space {
                continue;
            }
            last_was_space = true;
        } else {
            last_was_space = false;
        }

        result.push(ch);
        count += 1;
    }

    // Trim trailing spaces
    while result.ends_with(' ') {
        result.pop();
    }

    result
}

// ─────────────────────────────────────────────────────────────────────────────
// THUMBNAIL GENERATION
// ─────────────────────────────────────────────────────────────────────────────

/// Generate a WebP thumbnail from image data
/// Returns None if the image cannot be decoded
fn generate_thumbnail(image_data: &[u8], max_size: u32) -> Option<Vec<u8>> {
    use image::GenericImageView;

    let img = image::load_from_memory(image_data).ok()?;
    let (width, height) = img.dimensions();

    // Only create thumbnail if image is larger than max_size
    if width <= max_size && height <= max_size {
        // Image is small enough, just re-encode it as WebP
        let mut buf = Vec::new();
        let mut cursor = std::io::Cursor::new(&mut buf);
        img.write_to(&mut cursor, image::ImageFormat::WebP).ok()?;
        return Some(buf);
    }

    // Calculate new dimensions maintaining aspect ratio
    let scale = max_size as f32 / width.max(height) as f32;
    let new_width = (width as f32 * scale) as u32;
    let new_height = (height as f32 * scale) as u32;

    let thumbnail = img.thumbnail(new_width, new_height);

    let mut buf = Vec::new();
    let mut cursor = std::io::Cursor::new(&mut buf);
    thumbnail.write_to(&mut cursor, image::ImageFormat::WebP).ok()?;

    Some(buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_stored_item_text() {
        let item = StoredItem::new_text(
            "Hello World".to_string(),
            Some("Test App".to_string()),
            None,
        );
        assert_eq!(item.text_content(), "Hello World");
        assert_eq!(item.icon_type(), IconType::Text);
    }

    #[test]
    fn test_display_text_truncation() {
        let long_text = "a".repeat(300);
        let item = StoredItem::new_text(long_text, None, None);
        let display = item.display_text(200);
        assert!(display.chars().count() == 201); // 200 chars + ellipsis (1 char)
        assert!(display.ends_with('…'));
    }

    #[test]
    fn test_display_text_whitespace_normalization() {
        let item = StoredItem::new_text("  hello\n\nworld  ".to_string(), None, None);
        assert_eq!(item.display_text(200), "hello world");
    }

    #[test]
    fn test_link_metadata_state_database_roundtrip() {
        // Pending
        let pending = LinkMetadataState::Pending;
        let (title, img) = pending.to_database_fields();
        assert_eq!(
            LinkMetadataState::from_database(title.as_deref(), img),
            pending
        );

        // Failed
        let failed = LinkMetadataState::Failed;
        let (title, img) = failed.to_database_fields();
        assert_eq!(
            LinkMetadataState::from_database(title.as_deref(), img),
            failed
        );

        // Loaded
        let loaded = LinkMetadataState::Loaded {
            title: Some("Test Title".to_string()),
            image_data: Some(vec![1, 2, 3]),
        };
        let (title, img) = loaded.to_database_fields();
        assert_eq!(
            LinkMetadataState::from_database(title.as_deref(), img),
            loaded
        );
    }

    #[test]
    fn test_color_content() {
        let item = StoredItem::new_text("#FF5733".to_string(), None, None);
        assert!(matches!(item.content, ClipboardContent::Color { .. }));
        assert_eq!(item.icon_type(), IconType::Color);
    }

    #[test]
    fn test_item_icon_for_color() {
        let item = StoredItem::new_text("#FF5733".to_string(), None, None);
        if let ItemIcon::ColorSwatch { rgba } = item.item_icon() {
            // #FF5733 with full alpha
            assert_eq!(rgba, 0xFF5733FF);
        } else {
            panic!("Expected ColorSwatch icon");
        }
    }
}
