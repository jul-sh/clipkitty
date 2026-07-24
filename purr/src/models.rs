//! Core data models for ClipKitty
//!
//! Types with uniffi derives are automatically exported to Swift.
//! No need to duplicate definitions in the UDL file.

use std::borrow::Cow;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

use crate::interface::{
    ClipboardContent, ClipboardItem, FileEntry, FileStatus, ItemIcon, ItemMetadata, NewFileInput,
};
#[cfg(test)]
use crate::interface::{FilePreviewSnapshot, IconType, LinkMetadataPayload, LinkMetadataState};
use sha2::{Digest, Sha256};

// ─────────────────────────────────────────────────────────────────────────────
// INTERNAL ITEM (not exposed via FFI, used for storage)
// ─────────────────────────────────────────────────────────────────────────────

/// Internal clipboard item representation for database storage
#[derive(Debug, Clone, PartialEq)]
pub struct StoredItem {
    pub id: Option<i64>,
    pub item_id: String,
    pub content: ClipboardContent,
    pub content_hash: String,
    pub timestamp_unix: i64,
    pub source_app: Option<String>,
    pub source_app_bundle_id: Option<String>,
    /// Thumbnail for images and links (small preview, stored in items.thumbnail)
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
            item_id: uuid::Uuid::new_v4().to_string(),
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
        is_animated: bool,
    ) -> Self {
        let content_hash = Self::hash_bytes(&image_data);
        Self {
            id: None,
            item_id: uuid::Uuid::new_v4().to_string(),
            content: ClipboardContent::Image {
                data: image_data,
                description: "Image".to_string(),
                is_animated,
            },
            content_hash,
            timestamp_unix: chrono::Utc::now().timestamp(),
            source_app,
            source_app_bundle_id,
            thumbnail,
            color_rgba: None,
        }
    }

    /// Create a (possibly grouped) file item from multiple files with explicit previews.
    pub fn new_files(
        inputs: Vec<NewFileInput>,
        source_app: Option<String>,
        source_app_bundle_id: Option<String>,
    ) -> Self {
        assert!(!inputs.is_empty(), "new_files requires at least one file");

        // Content hash: sort all paths, hash joined
        let mut sorted_paths = inputs
            .iter()
            .map(|input| input.path.as_str())
            .collect::<Vec<_>>();
        sorted_paths.sort_unstable();
        let hash_input = sorted_paths
            .iter()
            .map(|p| format!("file://{}", p))
            .collect::<Vec<_>>()
            .join("\n");
        let content_hash = Self::hash_string(&hash_input);

        let file_count = inputs.len();
        let folder_count = inputs
            .iter()
            .filter(|input| input.uti.starts_with("public.folder"))
            .count();
        let file_only_count = file_count - folder_count;

        let dir_count = folder_count;
        let type_prefix = match (dir_count, file_only_count) {
            (0, 1) => "File:".to_string(),
            (0, n) => format!("{} Files:", n),
            (1, 0) => "Directory:".to_string(),
            (n, 0) => format!("{} Directories:", n),
            (d, f) => format!(
                "{} {} and {} {}:",
                d,
                if d == 1 { "Directory" } else { "Directories" },
                f,
                if f == 1 { "File" } else { "Files" }
            ),
        };

        let items_summary = match file_count {
            1 => inputs[0].filename.clone(),
            2 => format!("{}, {}", inputs[0].filename, inputs[1].filename),
            n => format!("{} and {} more", inputs[0].filename, n - 1),
        };

        let display_name = format!("{} {}", type_prefix, items_summary);

        let files: Vec<FileEntry> = inputs
            .into_iter()
            .map(|input| FileEntry {
                path: input.path,
                filename: input.filename,
                file_size: input.file_size,
                uti: input.uti,
                bookmark_data: input.bookmark_data,
                file_status: FileStatus::Available,
                preview: input.preview,
            })
            .collect();

        Self {
            id: None,
            item_id: uuid::Uuid::new_v4().to_string(),
            content: ClipboardContent::File {
                display_name,
                files,
            },
            content_hash,
            timestamp_unix: chrono::Utc::now().timestamp(),
            source_app,
            source_app_bundle_id,
            thumbnail: None,
            color_rgba: None,
        }
    }

    /// Canonical searchable text. File items include every filename and path;
    /// other content can borrow its stored text without allocating.
    pub fn searchable_text(&self) -> Cow<'_, str> {
        if let ClipboardContent::File {
            display_name,
            files,
        } = &self.content
        {
            let mut text = display_name.clone();
            for file in files {
                text.push('\n');
                text.push_str(&file.filename);
                text.push('\n');
                text.push_str(&file.path);
            }
            Cow::Owned(text)
        } else {
            Cow::Borrowed(self.text_content())
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
        crate::search::generate_preview(self.text_content(), max_chars)
    }

    /// Convert to ItemMetadata for list display
    pub fn to_metadata(&self) -> ItemMetadata {
        ItemMetadata {
            item_id: self.item_id.clone(),
            icon: self.item_icon(),
            source_app: self.source_app.clone(),
            source_app_bundle_id: self.source_app_bundle_id.clone(),
            timestamp_unix: self.timestamp_unix,
            tags: Vec::new(),
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

    /// Hash raw bytes for content types where byte identity matters.
    pub fn hash_bytes(bytes: &[u8]) -> String {
        let mut hasher = Sha256::new();
        hasher.update(bytes);
        format!("{:x}", hasher.finalize())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file_input(
        path: &str,
        filename: &str,
        file_size: u64,
        uti: &str,
        bookmark_data: Vec<u8>,
        preview: FilePreviewSnapshot,
    ) -> NewFileInput {
        NewFileInput {
            path: path.to_string(),
            filename: filename.to_string(),
            file_size,
            uti: uti.to_string(),
            bookmark_data,
            preview,
        }
    }

    fn not_captured_file(
        path: &str,
        filename: &str,
        file_size: u64,
        uti: &str,
        bookmark_data: Vec<u8>,
    ) -> NewFileInput {
        file_input(
            path,
            filename,
            file_size,
            uti,
            bookmark_data,
            FilePreviewSnapshot::not_captured(),
        )
    }

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
        assert!(
            display.chars().count() <= 200,
            "Should be at most 200 chars"
        );
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
            LinkMetadataState::from_database(title.as_deref(), desc.as_deref(), img).unwrap(),
            pending
        );

        // Failed
        let failed = LinkMetadataState::Failed;
        let (title, desc, img) = failed.to_database_fields();
        assert_eq!(
            LinkMetadataState::from_database(title.as_deref(), desc.as_deref(), img).unwrap(),
            failed
        );

        // Loaded
        let loaded = LinkMetadataState::Loaded {
            payload: LinkMetadataPayload::TitleAndImage {
                title: "Test Title".to_string(),
                description: Some("Test Description".to_string()),
                image_data: vec![1, 2, 3],
            },
        };
        let (title, desc, img) = loaded.to_database_fields();
        assert_eq!(
            LinkMetadataState::from_database(title.as_deref(), desc.as_deref(), img).unwrap(),
            loaded
        );
    }

    #[test]
    fn test_link_metadata_state_image_only_roundtrip() {
        let loaded = LinkMetadataState::Loaded {
            payload: LinkMetadataPayload::ImageOnly {
                image_data: vec![4, 5, 6],
                description: Some("Image only".to_string()),
            },
        };
        let (title, desc, img) = loaded.to_database_fields();
        assert_eq!(
            LinkMetadataState::from_database(title.as_deref(), desc.as_deref(), img).unwrap(),
            loaded
        );
    }

    #[test]
    fn test_link_metadata_state_rejects_empty_loaded_payload() {
        let result = LinkMetadataState::from_database(Some(""), Some("dangling"), None);
        assert!(result.is_err());
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
    fn test_stored_item_multi_file_display_text() {
        // 2 files: "a.txt, b.txt"
        let item = StoredItem::new_files(
            vec![
                not_captured_file("/tmp/a.txt", "a.txt", 100, "public.plain-text", vec![1]),
                not_captured_file("/tmp/b.txt", "b.txt", 200, "public.plain-text", vec![2]),
            ],
            None,
            None,
        );
        assert_eq!(item.text_content(), "2 Files: a.txt, b.txt");

        // 3 files: "3 Files: a.txt and 2 more"
        let item = StoredItem::new_files(
            vec![
                not_captured_file("/tmp/a.txt", "a.txt", 100, "public.plain-text", vec![1]),
                not_captured_file("/tmp/b.txt", "b.txt", 200, "public.plain-text", vec![2]),
                not_captured_file("/tmp/c.txt", "c.txt", 300, "public.plain-text", vec![3]),
            ],
            None,
            None,
        );
        assert_eq!(item.text_content(), "3 Files: a.txt and 2 more");

        // 1 file: "File: filename"
        let item = StoredItem::new_files(
            vec![not_captured_file(
                "/tmp/solo.txt",
                "solo.txt",
                42,
                "public.plain-text",
                vec![1],
            )],
            None,
            None,
        );
        assert_eq!(item.text_content(), "File: solo.txt");
    }

    #[test]
    fn test_stored_item_multi_file_preserves_per_file_metadata_association() {
        let previews = vec![
            FilePreviewSnapshot::Text {
                text: crate::interface::FileTextPreviewSnapshot::Complete {
                    sample: "alpha preview".to_string(),
                },
            },
            FilePreviewSnapshot::Image {
                preview_data: vec![9, 8, 7],
            },
        ];
        let item = StoredItem::new_files(
            vec![
                file_input(
                    "/tmp/alpha.txt",
                    "alpha.txt",
                    11,
                    "public.plain-text",
                    vec![1, 2],
                    previews[0].clone(),
                ),
                file_input(
                    "/tmp/beta.png",
                    "beta.png",
                    22,
                    "public.png",
                    vec![3, 4],
                    previews[1].clone(),
                ),
            ],
            Some("Finder".into()),
            Some("com.apple.finder".into()),
        );

        let ClipboardContent::File { files, .. } = item.content else {
            panic!("expected file content");
        };
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].path, "/tmp/alpha.txt");
        assert_eq!(files[0].filename, "alpha.txt");
        assert_eq!(files[0].file_size, 11);
        assert_eq!(files[0].uti, "public.plain-text");
        assert_eq!(files[0].bookmark_data, vec![1, 2]);
        assert_eq!(files[0].preview, previews[0]);
        assert_eq!(files[1].path, "/tmp/beta.png");
        assert_eq!(files[1].filename, "beta.png");
        assert_eq!(files[1].file_size, 22);
        assert_eq!(files[1].uti, "public.png");
        assert_eq!(files[1].bookmark_data, vec![3, 4]);
        assert_eq!(files[1].preview, previews[1]);
        assert_eq!(item.source_app.as_deref(), Some("Finder"));
        assert_eq!(
            item.source_app_bundle_id.as_deref(),
            Some("com.apple.finder")
        );
    }

    #[test]
    fn test_stored_item_multi_file_content_hash_order_independent() {
        let item1 = StoredItem::new_files(
            vec![
                not_captured_file("/tmp/a.txt", "a.txt", 100, "public.plain-text", vec![1]),
                not_captured_file("/tmp/b.txt", "b.txt", 200, "public.plain-text", vec![2]),
            ],
            None,
            None,
        );

        let item2 = StoredItem::new_files(
            vec![
                not_captured_file("/tmp/b.txt", "b.txt", 200, "public.plain-text", vec![2]),
                not_captured_file("/tmp/a.txt", "a.txt", 100, "public.plain-text", vec![1]),
            ],
            None,
            None,
        );

        assert_eq!(
            item1.content_hash, item2.content_hash,
            "Same files in different order should produce same hash"
        );
    }

    #[test]
    fn test_stored_item_multi_file_searchable_text() {
        let item = StoredItem::new_files(
            vec![
                not_captured_file("/tmp/a.txt", "a.txt", 100, "public.plain-text", vec![1]),
                not_captured_file("/tmp/b.txt", "b.txt", 200, "public.plain-text", vec![2]),
            ],
            None,
            None,
        );
        let index_text = item.searchable_text();
        assert!(
            index_text.contains("a.txt"),
            "Index text should contain first filename"
        );
        assert!(
            index_text.contains("b.txt"),
            "Index text should contain second filename"
        );
        assert!(
            index_text.contains("/tmp/b.txt"),
            "Index text should contain second path"
        );
    }

    #[test]
    fn test_image_hash_uses_content_not_length() {
        let item1 = StoredItem::new_image_with_thumbnail(vec![1, 2, 3], None, None, None, false);
        let item2 = StoredItem::new_image_with_thumbnail(vec![4, 5, 6], None, None, None, false);
        let item3 = StoredItem::new_image_with_thumbnail(vec![1, 2, 3], None, None, None, false);

        assert_ne!(item1.content_hash, item2.content_hash);
        assert_eq!(item1.content_hash, item3.content_hash);
    }
}
