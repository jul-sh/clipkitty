//! Tests for preview text generation and row-decoration snippet output.

use purr::search::generate_preview;
use purr::{ClipboardStore, ClipboardStoreApi, HighlightKind, RowDecoration};

fn utf16_slice(text: &str, start: u64, end: u64) -> String {
    let code_units: Vec<u16> = text.encode_utf16().collect();
    String::from_utf16(&code_units[start as usize..end as usize]).unwrap()
}

async fn row_decoration_for(content: &str, query: &str) -> RowDecoration {
    let store = ClipboardStore::new_in_memory().unwrap();
    store.save_text(content.to_string(), None, None).unwrap();

    let result = store.search(query.to_string()).await.unwrap();
    result.matches[0].row_decoration.clone().unwrap()
}

#[test]
fn preview_short_text() {
    let text = "Hello World";
    let result = generate_preview(text, 200);
    assert_eq!(result, "Hello World");
}

#[test]
fn preview_exactly_200_chars() {
    let text = "a".repeat(200);
    let result = generate_preview(&text, 200);
    assert_eq!(result.chars().count(), 200);
}

#[test]
fn preview_long_text_truncated() {
    let text = "a".repeat(500);
    let result = generate_preview(&text, 200);
    assert!(result.chars().count() <= 200);
}

#[test]
fn preview_normalizes_whitespace() {
    let text = "Hello\n\n\t  World   ";
    let result = generate_preview(text, 200);
    assert_eq!(result, "Hello World");
}

#[tokio::test]
async fn row_decoration_short_text_returns_full_content() {
    let row = row_decoration_for("Hello World", "Hello").await;
    assert_eq!(row.text, "Hello World");
    assert_eq!(row.line_number, 1);
    assert_eq!(utf16_slice(&row.text, row.highlights[0].utf16_start, row.highlights[0].utf16_end), "Hello");
}

#[tokio::test]
async fn row_decoration_normalizes_whitespace() {
    let row = row_decoration_for("Hello\n\n\nWorld", "Hello").await;
    assert_eq!(row.text, "Hello World");
}

#[tokio::test]
async fn row_decoration_calculates_line_number() {
    let row = row_decoration_for("Line 1\nLine 2\nLine 3 with MATCH", "MATCH").await;
    assert_eq!(row.line_number, 3);
}

#[tokio::test]
async fn row_decoration_extracts_utf16_highlight_correctly() {
    let row = row_decoration_for("The quick brown fox jumps over the lazy dog", "fox").await;
    assert!(row.text.contains("fox"));
    assert_eq!(
        utf16_slice(
            &row.text,
            row.highlights[0].utf16_start,
            row.highlights[0].utf16_end
        ),
        "fox"
    );
}

#[tokio::test]
async fn row_decoration_marks_truncation_with_ellipsis() {
    let content = format!("{} MATCH {}", "x".repeat(500), "y".repeat(500));
    let row = row_decoration_for(&content, "MATCH").await;
    assert!(row.text.contains("MATCH"));
    assert!(row.text.starts_with('…'));
    assert!(row.text.ends_with('…'));
}

#[tokio::test]
async fn row_decoration_preserves_prefix_vs_exact_highlight_kind() {
    let prefix = row_decoration_for("Alpha beta", "al").await;
    assert_eq!(prefix.highlights[0].kind, HighlightKind::Prefix);

    let exact = row_decoration_for("zz Alpha beta", "ph").await;
    assert_eq!(exact.highlights[0].kind, HighlightKind::Exact);
}
