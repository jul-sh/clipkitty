//! Core data models for ClipKitty
//!
//! These models are designed for UniFFI export to Swift.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

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
    Link {
        url: String,
        metadata_state: LinkMetadataState,
    },
    Email {
        address: String,
    },
    Phone {
        number: String,
    },
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
            ClipboardContent::Link { url, .. } => url,
            ClipboardContent::Email { address } => address,
            ClipboardContent::Phone { number } => number,
            ClipboardContent::Address { value } => value,
            ClipboardContent::Date { value } => value,
            ClipboardContent::Transit { value } => value,
            ClipboardContent::Image { description, .. } => description,
        }
    }

    /// SF Symbol icon name for the content type
    pub fn icon(&self) -> &str {
        match self {
            ClipboardContent::Text { .. } => "doc.text",
            ClipboardContent::Link { .. } => "link",
            ClipboardContent::Email { .. } => "envelope",
            ClipboardContent::Phone { .. } => "phone",
            ClipboardContent::Address { .. } => "map",
            ClipboardContent::Date { .. } => "calendar",
            ClipboardContent::Transit { .. } => "tram",
            ClipboardContent::Image { .. } => "photo",
        }
    }

    /// Database storage type string
    pub fn database_type(&self) -> &str {
        match self {
            ClipboardContent::Text { .. } => "text",
            ClipboardContent::Link { .. } => "link",
            ClipboardContent::Email { .. } => "email",
            ClipboardContent::Phone { .. } => "phone",
            ClipboardContent::Address { .. } => "address",
            ClipboardContent::Date { .. } => "date",
            ClipboardContent::Transit { .. } => "transit",
            ClipboardContent::Image { .. } => "image",
        }
    }

    /// Extract database fields: (content, image_data, link_title, link_image_data)
    pub fn to_database_fields(&self) -> (String, Option<Vec<u8>>, Option<String>, Option<Vec<u8>>) {
        match self {
            ClipboardContent::Text { value } => (value.clone(), None, None, None),
            ClipboardContent::Link { url, metadata_state } => {
                let (title, image_data) = metadata_state.to_database_fields();
                (url.clone(), None, title, image_data)
            }
            ClipboardContent::Email { address } => (address.clone(), None, None, None),
            ClipboardContent::Phone { number } => (number.clone(), None, None, None),
            ClipboardContent::Address { value } => (value.clone(), None, None, None),
            ClipboardContent::Date { value } => (value.clone(), None, None, None),
            ClipboardContent::Transit { value } => (value.clone(), None, None, None),
            ClipboardContent::Image { data, description } => {
                (description.clone(), Some(data.clone()), None, None)
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
    ) -> Self {
        match db_type {
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

/// A clipboard item with metadata (UniFFI-compatible)
#[derive(Debug, Clone, PartialEq)]
pub struct ClipboardItem {
    pub id: Option<i64>,
    pub content: ClipboardContent,
    pub content_hash: String,
    pub timestamp_unix: i64,
    pub source_app: Option<String>,
    pub source_app_bundle_id: Option<String>,
}

impl ClipboardItem {
    /// Create a new text item (auto-detects structured content)
    pub fn new_text(
        text: String,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Self {
        let content_hash = Self::hash_string(&text);
        let content = crate::content_detection::detect_content(&text);
        Self {
            id: None,
            content,
            content_hash,
            timestamp_unix: chrono::Utc::now().timestamp(),
            source_app,
            source_app_bundle_id,
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
        }
    }

    /// Create an image item
    pub fn new_image(
        image_data: Vec<u8>,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Self {
        let description = "Image".to_string();
        let hash_input = format!("{}{}", description, image_data.len());
        let content_hash = Self::hash_string(&hash_input);
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
        }
    }

    /// Get the raw text content for searching and display
    pub fn text_content(&self) -> &str {
        self.content.text_content()
    }

    /// Get the icon for the content type
    pub fn icon(&self) -> &str {
        self.content.icon()
    }

    /// Stable identifier for UI
    pub fn stable_id(&self) -> String {
        self.id
            .map(|id| id.to_string())
            .unwrap_or_else(|| self.content_hash.clone())
    }

    /// Display text (truncated, normalized whitespace)
    pub fn display_text(&self) -> String {
        let text = self.text_content();
        const MAX_CHARS: usize = 200;

        let mut result = String::with_capacity(MAX_CHARS + 1);
        let mut chars = text.chars().peekable();

        // Skip leading whitespace
        while chars.peek().map(|c| c.is_whitespace()).unwrap_or(false) {
            chars.next();
        }

        let mut last_was_space = false;
        let mut count = 0;

        for ch in chars {
            if count >= MAX_CHARS {
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

    /// Hash a string using Rust's default hasher
    fn hash_string(s: &str) -> String {
        let mut hasher = DefaultHasher::new();
        s.hash(&mut hasher);
        hasher.finish().to_string()
    }
}

/// A highlight range (start, end) in the text
#[derive(Debug, Clone, PartialEq)]
pub struct HighlightRange {
    pub start: u32,
    pub end: u32,
}

/// A search match with item ID and highlight ranges
#[derive(Debug, Clone)]
pub struct SearchMatch {
    pub item_id: i64,
    pub highlights: Vec<HighlightRange>,
}

/// Search result with matches (IDs + highlights)
#[derive(Debug, Clone)]
pub struct SearchResult {
    pub matches: Vec<SearchMatch>,
    pub total_count: u64,
}

/// Fetch result with pagination info for UniFFI
#[derive(Debug, Clone)]
pub struct FetchResult {
    pub items: Vec<ClipboardItem>,
    pub has_more: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_clipboard_item_text() {
        let item = ClipboardItem::new_text(
            "Hello World".to_string(),
            Some("Test App".to_string()),
            None,
        );
        assert_eq!(item.text_content(), "Hello World");
        assert_eq!(item.icon(), "doc.text");
    }

    #[test]
    fn test_display_text_truncation() {
        let long_text = "a".repeat(300);
        let item = ClipboardItem::new_text(long_text, None, None);
        let display = item.display_text();
        assert!(display.chars().count() == 201); // 200 chars + ellipsis (1 char)
        assert!(display.ends_with('…'));
    }

    #[test]
    fn test_display_text_whitespace_normalization() {
        let item = ClipboardItem::new_text("  hello\n\nworld  ".to_string(), None, None);
        assert_eq!(item.display_text(), "hello world");
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
}
