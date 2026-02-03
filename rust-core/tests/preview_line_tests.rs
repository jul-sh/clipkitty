//! Tests for preview line behavior
//!
//! Unified preview generation via `generate_preview()` and `generate_snippet()`:
//! - `generate_preview()` - For item list preview (no highlights, starts from beginning)
//! - `generate_snippet()` - For search result snippets with highlights
//!
//! Rust provides normalized text; Swift handles final truncation and ellipsis.
//!
//! Rust behavior:
//! - Returns generous snippets (up to ~400 chars) without ellipsis
//! - Normalizes whitespace (collapse spaces, convert newlines/tabs)
//! - Maps highlight positions to normalized snippet
//! - Calculates line number for Swift to use in prefix
//!
//! Swift behavior (tested in SnippetTruncationTests.swift):
//! - Truncates to 200 chars
//! - Adds leading ellipsis when snippet doesn't start at content beginning
//! - Adds "L{n}: " prefix for matches not on line 1
//! - Adds trailing ellipsis when content is truncated

use clipkitty_core::search::{generate_preview, SearchEngine};
use clipkitty_core::HighlightRange;

// ─────────────────────────────────────────────────────────────────────────────
// generate_preview TESTS (used for item list display with empty query)
// Rust provides normalized text; Swift handles ellipsis
// ─────────────────────────────────────────────────────────────────────────────

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
    // Rust truncates; Swift adds ellipsis
    assert!(result.chars().count() <= 200, "Should be at most 200 chars");
}

#[test]
fn preview_skips_leading_whitespace() {
    let text = "   Hello World";
    let result = generate_preview(text, 200);
    assert_eq!(result, "Hello World");
    assert!(!result.starts_with(' '));
}

#[test]
fn preview_collapses_consecutive_whitespace() {
    let text = "Hello    World";
    let result = generate_preview(text, 200);
    assert_eq!(result, "Hello World");
}

#[test]
fn preview_converts_newlines_to_spaces() {
    let text = "Hello\n\nWorld";
    let result = generate_preview(text, 200);
    assert_eq!(result, "Hello World");
}

#[test]
fn preview_converts_tabs_to_spaces() {
    let text = "Hello\t\tWorld";
    let result = generate_preview(text, 200);
    assert_eq!(result, "Hello World");
}

#[test]
fn preview_trims_trailing_spaces() {
    let text = "Hello World   ";
    let result = generate_preview(text, 200);
    assert_eq!(result, "Hello World");
}

// ─────────────────────────────────────────────────────────────────────────────
// generate_snippet TESTS (used for search result display with non-empty query)
// Rust returns generous snippets; Swift handles ellipsis
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn snippet_short_text_returns_full_content() {
    let content = "Hello World";
    let highlights = vec![HighlightRange { start: 0, end: 5 }];
    let (snippet, _, line_number) = SearchEngine::generate_snippet(content, &highlights, 400);
    assert_eq!(snippet, "Hello World");
    assert!(!snippet.starts_with('…'), "Rust should not add leading ellipsis");
    assert!(!snippet.ends_with('…'), "Rust should not add trailing ellipsis");
    assert_eq!(line_number, 1, "Match on first line should have line_number=1");
}

#[test]
fn snippet_no_ellipsis_from_rust() {
    // Even for matches in the middle, Rust should not add ellipsis
    let prefix = "x".repeat(100);
    let suffix = "y".repeat(100);
    let content = format!("{}MATCH{}", prefix, suffix);
    let highlights = vec![HighlightRange { start: 100, end: 105 }];
    let (snippet, _, _) = SearchEngine::generate_snippet(&content, &highlights, 400);

    assert!(!snippet.starts_with('…'),
        "Rust should not add leading ellipsis. Got: '{}'", snippet);
    assert!(!snippet.ends_with('…'),
        "Rust should not add trailing ellipsis. Got: '{}'", snippet);
}

#[test]
fn snippet_contains_match_with_context() {
    let content = "The quick brown fox jumps over the lazy dog";
    let highlights = vec![HighlightRange { start: 16, end: 19 }]; // "fox"
    let (snippet, adjusted_highlights, _) = SearchEngine::generate_snippet(content, &highlights, 400);

    assert!(snippet.contains("fox"), "Snippet should contain the match");
    assert!(!adjusted_highlights.is_empty());

    // Verify highlight points to "fox" in snippet
    let h = &adjusted_highlights[0];
    let highlighted: String = snippet.chars()
        .skip(h.start as usize)
        .take((h.end - h.start) as usize)
        .collect();
    assert_eq!(highlighted, "fox");
}

#[test]
fn snippet_normalizes_whitespace() {
    let content = "Hello\n\n\nWorld";
    let highlights = vec![HighlightRange { start: 0, end: 5 }];
    let (snippet, _, _) = SearchEngine::generate_snippet(content, &highlights, 400);

    assert!(!snippet.contains('\n'), "Snippet should not contain newlines");
    assert!(!snippet.contains("  "), "Snippet should not contain consecutive spaces");
    assert_eq!(snippet, "Hello World");
}

#[test]
fn snippet_line_number_calculated_correctly() {
    let content = "Line 1\nLine 2\nLine 3 with MATCH";
    let highlights = vec![HighlightRange { start: 21, end: 26 }]; // "MATCH"
    let (_, _, line_number) = SearchEngine::generate_snippet(content, &highlights, 400);

    assert_eq!(line_number, 3, "Match on third line should have line_number=3");
}

#[test]
fn snippet_line_number_first_line() {
    let content = "MATCH on first line\nSecond line";
    let highlights = vec![HighlightRange { start: 0, end: 5 }];
    let (_, _, line_number) = SearchEngine::generate_snippet(content, &highlights, 400);

    assert_eq!(line_number, 1, "Match on first line should have line_number=1");
}

#[test]
fn snippet_respects_max_length() {
    let content = "a".repeat(600);
    let highlights = vec![HighlightRange { start: 0, end: 5 }];
    let (snippet, _, _) = SearchEngine::generate_snippet(&content, &highlights, 400);

    let char_count = snippet.chars().count();
    assert!(char_count <= 400,
        "Snippet length {} exceeds max of 400", char_count);
}

#[test]
fn snippet_highlight_positions_correct_without_ellipsis() {
    // Highlights should point to correct positions in the snippet
    let prefix = "x".repeat(100);
    let content = format!("{}MATCH", prefix);
    let highlights = vec![HighlightRange { start: 100, end: 105 }];
    let (snippet, adjusted_highlights, _) = SearchEngine::generate_snippet(&content, &highlights, 400);

    // The highlight should point to "MATCH" in the snippet
    assert!(!adjusted_highlights.is_empty(), "Should have adjusted highlights");
    let h = &adjusted_highlights[0];
    let highlighted: String = snippet.chars()
        .skip(h.start as usize)
        .take((h.end - h.start) as usize)
        .collect();
    assert_eq!(highlighted, "MATCH",
        "Highlight should correctly identify MATCH in snippet: '{}'", snippet);
}

#[test]
fn snippet_no_highlights_returns_normalized_content() {
    let content = "Hello   World\n\ntest";
    let highlights: Vec<HighlightRange> = vec![];
    let (snippet, adjusted_highlights, line_number) = SearchEngine::generate_snippet(content, &highlights, 400);

    assert_eq!(snippet, "Hello World test");
    assert!(adjusted_highlights.is_empty());
    assert_eq!(line_number, 0); // No highlight means no line number
}

// ─────────────────────────────────────────────────────────────────────────────
// generate_preview vs generate_snippet COMPARISON
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn both_functions_normalize_whitespace_consistently() {
    let text_with_whitespace = "Hello\n\n\t  World   ";

    let preview = generate_preview(text_with_whitespace, 200);
    assert_eq!(preview, "Hello World");

    let highlights = vec![HighlightRange { start: 0, end: 5 }];
    let (snippet, _, _) = SearchEngine::generate_snippet(text_with_whitespace, &highlights, 400);
    assert_eq!(snippet, "Hello World");
}
