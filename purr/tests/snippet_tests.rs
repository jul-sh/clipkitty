//! Tests for preview text generation and matched excerpt output.

use purr::search::generate_preview;
use purr::{
    ClipboardStore, ClipboardStoreApi, HighlightKind, ListPresentationProfile, MatchedExcerpt,
    RowPresentation,
};
use tempfile::TempDir;

fn utf16_slice(text: &str, start: u64, end: u64) -> String {
    let code_units: Vec<u16> = text.encode_utf16().collect();
    String::from_utf16(&code_units[start as usize..end as usize]).unwrap()
}

async fn matched_excerpt_for(content: &str, query: &str) -> MatchedExcerpt {
    matched_excerpt_for_profile(content, query, ListPresentationProfile::CompactRow).await
}

async fn matched_excerpt_for_profile(
    content: &str,
    query: &str,
    profile: ListPresentationProfile,
) -> MatchedExcerpt {
    let dir = TempDir::new().unwrap();
    let db_path = dir.path().join("test.db");
    let store = ClipboardStore::new(db_path.to_str().unwrap().to_string()).unwrap();
    store.save_text(content.to_string(), None, None).unwrap();

    let result = store.search(query.to_string(), profile).await.unwrap();
    match &result.matches[0].presentation {
        RowPresentation::Matched { excerpt } => excerpt.clone(),
        other => panic!("expected ready matched excerpt, got {other:?}"),
    }
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
async fn matched_excerpt_short_text_returns_full_content() {
    let row = matched_excerpt_for("Hello World", "Hello").await;
    assert_eq!(row.text, "Hello World");
    assert_eq!(row.line_number, 1);
    assert_eq!(
        utf16_slice(
            &row.text,
            row.highlights[0].utf16_start,
            row.highlights[0].utf16_end
        ),
        "Hello"
    );
}

#[tokio::test]
async fn trigram_search_eagerly_decorates_initial_short_results() {
    let dir = TempDir::new().unwrap();
    let db_path = dir.path().join("test.db");
    let store = ClipboardStore::new(db_path.to_str().unwrap().to_string()).unwrap();

    for index in 0..3 {
        store
            .save_text(format!("needle result {index}"), None, None)
            .unwrap();
    }

    let result = store
        .search("needle".to_string(), ListPresentationProfile::CompactRow)
        .await
        .unwrap();

    assert_eq!(result.matches.len(), 3);
    assert!(
        result
            .matches
            .iter()
            .all(|item| matches!(
                item.presentation,
                RowPresentation::Matched { .. }
            )),
        "expected every short initial trigram match to have a ready matched excerpt"
    );
}

#[tokio::test]
async fn matched_excerpt_normalizes_whitespace() {
    let row = matched_excerpt_for("Hello\n\n\nWorld", "Hello").await;
    assert_eq!(row.text, "Hello World");
}

#[tokio::test]
async fn matched_excerpt_calculates_line_number() {
    let row = matched_excerpt_for("Line 1\nLine 2\nLine 3 with MATCH", "MATCH").await;
    assert_eq!(row.line_number, 3);
}

#[tokio::test]
async fn matched_excerpt_extracts_utf16_highlight_correctly() {
    let row = matched_excerpt_for("The quick brown fox jumps over the lazy dog", "fox").await;
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
async fn matched_excerpt_marks_truncation_with_ellipsis() {
    let content = format!("{} MATCH {}", "x".repeat(500), "y".repeat(500));
    let row = matched_excerpt_for(&content, "MATCH").await;
    assert!(row.text.contains("MATCH"));
    assert!(row.text.starts_with('…'));
    assert!(row.text.ends_with('…'));
}

#[tokio::test]
async fn matched_excerpt_preserves_prefix_vs_exact_highlight_kind() {
    let prefix = matched_excerpt_for("Alpha beta", "al").await;
    assert_eq!(prefix.highlights[0].kind, HighlightKind::Prefix);

    let exact = matched_excerpt_for("zz Alpha beta", "ph").await;
    assert_eq!(exact.highlights[0].kind, HighlightKind::Exact);
}

// ─────────────────────────────────────────────────────────────────────────────
// Card profile tests
// ─────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn card_matched_excerpt_preserves_meaningful_newlines() {
    let content = "Line one\nLine two\nLine three with MATCH\nLine four";
    let row = matched_excerpt_for_profile(content, "MATCH", ListPresentationProfile::Card).await;
    // Card mode should keep newlines in the output
    assert!(
        row.text.contains('\n'),
        "Card excerpt should preserve newlines, got: {:?}",
        row.text
    );
    assert!(row.text.contains("MATCH"));
    assert_eq!(row.line_number, 3);
}

#[tokio::test]
async fn card_matched_excerpt_collapses_pathological_whitespace() {
    let content = "Line one\n\n\n\n\n\n\n\nLine two with MATCH";
    let row = matched_excerpt_for_profile(content, "MATCH", ListPresentationProfile::Card).await;
    // Should collapse 8 newlines down to at most 2
    let newline_count = row.text.chars().filter(|&c| c == '\n').count();
    assert!(
        newline_count <= 2,
        "Expected at most 2 newlines, got {}",
        newline_count
    );
    assert!(row.text.contains("MATCH"));
}

#[tokio::test]
async fn card_matched_excerpt_has_larger_budget_than_compact() {
    let content = format!("MATCH {}", "word ".repeat(200));
    let compact =
        matched_excerpt_for_profile(&content, "MATCH", ListPresentationProfile::CompactRow).await;
    let card = matched_excerpt_for_profile(&content, "MATCH", ListPresentationProfile::Card).await;
    // Card should produce a longer excerpt
    assert!(
        card.text.len() > compact.text.len(),
        "Card ({}) should be longer than compact ({})",
        card.text.len(),
        compact.text.len()
    );
}

#[tokio::test]
async fn card_matched_excerpt_highlight_is_correct() {
    let content = "First line\nSecond line\nThird line with MATCH here";
    let row = matched_excerpt_for_profile(content, "MATCH", ListPresentationProfile::Card).await;
    assert!(!row.highlights.is_empty());
    let highlighted = utf16_slice(
        &row.text,
        row.highlights[0].utf16_start,
        row.highlights[0].utf16_end,
    );
    assert_eq!(highlighted, "MATCH");
}

#[tokio::test]
async fn compact_row_collapses_newlines() {
    let content = "Line one\nLine two\nLine three with MATCH";
    let row =
        matched_excerpt_for_profile(content, "MATCH", ListPresentationProfile::CompactRow).await;
    // CompactRow should NOT contain newlines
    assert!(
        !row.text.contains('\n'),
        "CompactRow should not contain newlines, got: {:?}",
        row.text
    );
}

#[tokio::test]
async fn format_excerpt_matches_profile() {
    let dir = TempDir::new().unwrap();
    let db_path = dir.path().join("test.db");
    let store = ClipboardStore::new(db_path.to_str().unwrap().to_string()).unwrap();

    let content = "Hello\nWorld\nFoo";
    let compact = store.format_excerpt(content.to_string(), ListPresentationProfile::CompactRow);
    let card = store.format_excerpt(content.to_string(), ListPresentationProfile::Card);

    assert!(
        !compact.contains('\n'),
        "CompactRow format_excerpt should collapse newlines"
    );
    assert!(
        card.contains('\n'),
        "Card format_excerpt should preserve newlines"
    );
}
