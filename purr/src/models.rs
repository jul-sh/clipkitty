//! Core data models for ClipKitty
//!
//! Types with uniffi derives are automatically exported to Swift.
//! No need to duplicate definitions in the UDL file.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

use crate::interface::{
    ClipboardContent, FileEntry, FileStatus, ItemIcon, ItemMetadata, ClipboardItem,
};
#[cfg(test)]
use crate::interface::IconType;

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
    /// Thumbnail for images/files/links (small preview, stored in items.thumbnail)
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

    /// Create an image item with a pre-generated thumbnail
    /// Used when Swift generates the thumbnail (HEIC not supported by Rust image crate)
    pub fn new_image_with_thumbnail(
        image_data: Vec<u8>,
        thumbnail: Option<Vec<u8>>,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Self {
        let hash_input = format!("Image{}", image_data.len());
        let content_hash = Self::hash_string(&hash_input);
        Self {
            id: None,
            content: ClipboardContent::Image {
                data: image_data,
                description: "Image".to_string(),
            },
            content_hash,
            timestamp_unix: chrono::Utc::now().timestamp(),
            source_app,
            source_app_bundle_id,
            thumbnail,
            color_rgba: None,
        }
    }

    /// Create a file item with optional QuickLook thumbnail
    pub fn new_file(
        path: String,
        filename: String,
        file_size: u64,
        uti: String,
        bookmark_data: Vec<u8>,
        thumbnail: Option<Vec<u8>>,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Self {
        Self::new_files(
            vec![path],
            vec![filename],
            vec![file_size],
            vec![uti],
            vec![bookmark_data],
            thumbnail,
            source_app,
            source_app_bundle_id,
        )
    }

    /// Create a (possibly grouped) file item from multiple files
    pub fn new_files(
        paths: Vec<String>,
        filenames: Vec<String>,
        file_sizes: Vec<u64>,
        utis: Vec<String>,
        bookmark_data_list: Vec<Vec<u8>>,
        thumbnail: Option<Vec<u8>>,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Self {
        assert!(!paths.is_empty(), "new_files requires at least one file");

        // Content hash: sort all paths, hash joined
        let mut sorted_paths = paths.clone();
        sorted_paths.sort();
        let hash_input = sorted_paths.iter()
            .map(|p| format!("file://{}", p))
            .collect::<Vec<_>>()
            .join("\n");
        let content_hash = Self::hash_string(&hash_input);

        let file_count = paths.len();

        let all_folders = utis.iter().all(|u| u.starts_with("public.folder"));
        let (singular, plural) = if all_folders {
            ("Folder", "Folders")
        } else {
            ("File", "Files")
        };

        let display_name = match file_count {
            1 => format!("{}: {}", singular, filenames[0]),
            2 => format!("{} {}: {}, {}", file_count, plural, filenames[0], filenames[1]),
            n => format!("{} {}: {} and {} more", n, plural, filenames[0], n - 1),
        };

        // Build FileEntry vec (file_item_id=0 since not yet inserted)
        let files: Vec<FileEntry> = (0..file_count)
            .map(|i| FileEntry {
                file_item_id: 0,
                path: paths[i].clone(),
                filename: filenames[i].clone(),
                file_size: file_sizes[i],
                uti: utis[i].clone(),
                bookmark_data: bookmark_data_list[i].clone(),
                file_status: FileStatus::Available,
            })
            .collect();

        Self {
            id: None,
            content: ClipboardContent::File {
                display_name,
                files,
            },
            content_hash,
            timestamp_unix: chrono::Utc::now().timestamp(),
            source_app,
            source_app_bundle_id,
            thumbnail,
            color_rgba: None,
        }
    }

    /// Get the index text for file items (all filenames and paths are searchable)
    pub fn file_index_text(&self) -> Option<String> {
        if let ClipboardContent::File { display_name, files } = &self.content {
            let mut text = display_name.clone();
            for file in files {
                text.push('\n');
                text.push_str(&file.filename);
                text.push('\n');
                text.push_str(&file.path);
            }
            Some(text)
        } else {
            None
        }
    }

    /// Get the raw text content for searching and display
    pub fn text_content(&self) -> &str {
        self.content.text_content()
    }

    /// Get the icon type for the content
    #[cfg(test)]
    pub fn icon_type(&self) -> IconType {
        self.content.icon_type()
    }

    /// Get the ItemIcon for display
    pub fn item_icon(&self) -> ItemIcon {
        ItemIcon::from_database(
            self.content.database_type(),
            self.color_rgba,
            self.thumbnail.clone(),
        )
    }

    /// Display text (truncated, normalized whitespace) for preview
    pub fn display_text(&self, max_chars: usize) -> String {
        crate::search::generate_preview(&self.text_content(), max_chars)
    }

    /// Convert to ItemMetadata for list display
    /// Preview is generous (SNIPPET_CONTEXT_CHARS * 2) - Swift handles final truncation
    pub fn to_metadata(&self) -> ItemMetadata {
        use crate::search::SNIPPET_CONTEXT_CHARS;
        ItemMetadata {
            item_id: self.id.unwrap_or(0),
            icon: self.item_icon(),
            snippet: self.display_text(SNIPPET_CONTEXT_CHARS * 2),
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
    pub fn hash_string(s: &str) -> String {
        let mut hasher = DefaultHasher::new();
        s.hash(&mut hasher);
        hasher.finish().to_string()
    }
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
        // Rust truncates; Swift adds ellipsis
        assert!(display.chars().count() <= 200, "Should be at most 200 chars");
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

    #[test]
    fn test_stored_item_multi_file_snippet() {
        // 2 files: "a.txt, b.txt"
        let item = StoredItem::new_files(
            vec!["/tmp/a.txt".into(), "/tmp/b.txt".into()],
            vec!["a.txt".into(), "b.txt".into()],
            vec![100, 200],
            vec!["public.plain-text".into(), "public.plain-text".into()],
            vec![vec![1], vec![2]],
            None, None, None,
        );
        assert_eq!(item.text_content(), "2 Files: a.txt, b.txt");

        // 3 files: "3 Files: a.txt and 2 more"
        let item = StoredItem::new_files(
            vec!["/tmp/a.txt".into(), "/tmp/b.txt".into(), "/tmp/c.txt".into()],
            vec!["a.txt".into(), "b.txt".into(), "c.txt".into()],
            vec![100, 200, 300],
            vec!["public.plain-text".into(); 3],
            vec![vec![1], vec![2], vec![3]],
            None, None, None,
        );
        assert_eq!(item.text_content(), "3 Files: a.txt and 2 more");

        // 1 file: "File: filename"
        let item = StoredItem::new_files(
            vec!["/tmp/solo.txt".into()],
            vec!["solo.txt".into()],
            vec![42],
            vec!["public.plain-text".into()],
            vec![vec![1]],
            None, None, None,
        );
        assert_eq!(item.text_content(), "File: solo.txt");
    }

    #[test]
    fn test_stored_item_multi_file_content_hash_order_independent() {
        let item1 = StoredItem::new_files(
            vec!["/tmp/a.txt".into(), "/tmp/b.txt".into()],
            vec!["a.txt".into(), "b.txt".into()],
            vec![100, 200],
            vec!["public.plain-text".into(); 2],
            vec![vec![1], vec![2]],
            None, None, None,
        );

        let item2 = StoredItem::new_files(
            vec!["/tmp/b.txt".into(), "/tmp/a.txt".into()],
            vec!["b.txt".into(), "a.txt".into()],
            vec![200, 100],
            vec!["public.plain-text".into(); 2],
            vec![vec![2], vec![1]],
            None, None, None,
        );

        assert_eq!(item1.content_hash, item2.content_hash, "Same files in different order should produce same hash");
    }

    #[test]
    fn test_stored_item_multi_file_index_text() {
        let item = StoredItem::new_files(
            vec!["/tmp/a.txt".into(), "/tmp/b.txt".into()],
            vec!["a.txt".into(), "b.txt".into()],
            vec![100, 200],
            vec!["public.plain-text".into(); 2],
            vec![vec![1], vec![2]],
            None, None, None,
        );
        let index_text = item.file_index_text().unwrap();
        assert!(index_text.contains("a.txt"), "Index text should contain first filename");
        assert!(index_text.contains("b.txt"), "Index text should contain second filename");
        assert!(index_text.contains("/tmp/b.txt"), "Index text should contain second path");
    }
}
