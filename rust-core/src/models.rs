//! Core data models for ClipKitty
//!
//! Types with uniffi derives are automatically exported to Swift.
//! No need to duplicate definitions in the UDL file.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

use crate::interface::{
    ClipboardContent, IconType, ItemIcon, ItemMetadata, ClipboardItem,
};

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
    pub fn to_clipboard_item(&self) -> ClipboardItem {
        ClipboardItem {
            item_metadata: self.to_metadata(),
            content: self.content.clone(),
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
    use crate::interface::LinkMetadataState;

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
        let (title, desc, img) = pending.to_database_fields();
        assert_eq!(
            LinkMetadataState::from_database(title.as_deref(), desc.as_deref(), img),
            pending
        );

        // Failed
        let failed = LinkMetadataState::Failed;
        let (title, desc, img) = failed.to_database_fields();
        assert_eq!(
            LinkMetadataState::from_database(title.as_deref(), desc.as_deref(), img),
            failed
        );

        // Loaded
        let loaded = LinkMetadataState::Loaded {
            title: Some("Test Title".to_string()),
            description: Some("Test Description".to_string()),
            image_data: Some(vec![1, 2, 3]),
        };
        let (title, desc, img) = loaded.to_database_fields();
        assert_eq!(
            LinkMetadataState::from_database(title.as_deref(), desc.as_deref(), img),
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
