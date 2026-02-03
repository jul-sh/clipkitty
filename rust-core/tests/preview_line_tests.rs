//! Tests for preview line behavior
//!
//! Rust provides normalized snippets; Swift handles final truncation and ellipsis.
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

use clipkitty_core::normalize_preview;
use clipkitty_core::search::SearchEngine;
use clipkitty_core::HighlightRange;

// ─────────────────────────────────────────────────────────────────────────────
// BROWSE MODE PREVIEW TESTS (normalize_preview)
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn browse_preview_short_text_no_ellipsis() {
    let text = "Hello World";
    let result = normalize_preview(text, 200);
    assert_eq!(result, "Hello World");
    assert!(!result.ends_with('…'), "Short text should not have ellipsis");
}

#[test]
fn browse_preview_exactly_200_chars_no_ellipsis() {
    let text = "a".repeat(200);
    let result = normalize_preview(&text, 200);
    assert_eq!(result.chars().count(), 200);
    assert!(!result.ends_with('…'), "Exactly 200 chars should not have ellipsis");
}

#[test]
fn browse_preview_201_chars_has_ellipsis() {
    let text = "a".repeat(201);
    let result = normalize_preview(&text, 200);
    assert_eq!(result.chars().count(), 201, "Should be 200 chars + ellipsis");
    assert!(result.ends_with('…'), "201 chars should be truncated with ellipsis");
}

#[test]
fn browse_preview_long_text_has_trailing_ellipsis() {
    let text = "a".repeat(500);
    let result = normalize_preview(&text, 200);
    assert!(result.ends_with('…'), "Long text should end with ellipsis");
    assert_eq!(result.chars().count(), 201, "Should be 200 chars + ellipsis");
}

#[test]
fn browse_preview_skips_leading_whitespace() {
    let text = "   Hello World";
    let result = normalize_preview(text, 200);
    assert_eq!(result, "Hello World");
    assert!(!result.starts_with(' '));
}

#[test]
fn browse_preview_collapses_consecutive_whitespace() {
    let text = "Hello    World";
    let result = normalize_preview(text, 200);
    assert_eq!(result, "Hello World");
}

#[test]
fn browse_preview_converts_newlines_to_spaces() {
    let text = "Hello\n\nWorld";
    let result = normalize_preview(text, 200);
    assert_eq!(result, "Hello World");
}

#[test]
fn browse_preview_converts_tabs_to_spaces() {
    let text = "Hello\t\tWorld";
    let result = normalize_preview(text, 200);
    assert_eq!(result, "Hello World");
}

#[test]
fn browse_preview_trims_trailing_spaces() {
    let text = "Hello World   ";
    let result = normalize_preview(text, 200);
    assert_eq!(result, "Hello World");
}

// ─────────────────────────────────────────────────────────────────────────────
// SEARCH MODE SNIPPET TESTS (generate_snippet)
// Rust returns generous snippets; Swift handles ellipsis
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn search_snippet_short_text_returns_full_content() {
    let content = "Hello World";
    let highlights = vec![HighlightRange { start: 0, end: 5 }];
    let (snippet, _, line_number) = SearchEngine::generate_snippet(content, &highlights, 400);
    assert_eq!(snippet, "Hello World");
    assert!(!snippet.starts_with('…'), "Rust should not add leading ellipsis");
    assert!(!snippet.ends_with('…'), "Rust should not add trailing ellipsis");
    assert_eq!(line_number, 1, "Match on first line should have line_number=1");
}

#[test]
fn search_snippet_no_ellipsis_from_rust() {
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
fn search_snippet_contains_match_with_context() {
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
fn search_snippet_normalizes_whitespace() {
    let content = "Hello\n\n\nWorld";
    let highlights = vec![HighlightRange { start: 0, end: 5 }];
    let (snippet, _, _) = SearchEngine::generate_snippet(content, &highlights, 400);

    assert!(!snippet.contains('\n'), "Snippet should not contain newlines");
    assert!(!snippet.contains("  "), "Snippet should not contain consecutive spaces");
    assert_eq!(snippet, "Hello World");
}

#[test]
fn search_snippet_line_number_calculated_correctly() {
    let content = "Line 1\nLine 2\nLine 3 with MATCH";
    let highlights = vec![HighlightRange { start: 21, end: 26 }]; // "MATCH"
    let (_, _, line_number) = SearchEngine::generate_snippet(content, &highlights, 400);

    assert_eq!(line_number, 3, "Match on third line should have line_number=3");
}

#[test]
fn search_snippet_line_number_first_line() {
    let content = "MATCH on first line\nSecond line";
    let highlights = vec![HighlightRange { start: 0, end: 5 }];
    let (_, _, line_number) = SearchEngine::generate_snippet(content, &highlights, 400);

    assert_eq!(line_number, 1, "Match on first line should have line_number=1");
}

#[test]
fn search_snippet_respects_max_length() {
    let content = "a".repeat(600);
    let highlights = vec![HighlightRange { start: 0, end: 5 }];
    let (snippet, _, _) = SearchEngine::generate_snippet(&content, &highlights, 400);

    let char_count = snippet.chars().count();
    assert!(char_count <= 400,
        "Snippet length {} exceeds max of 400", char_count);
}

#[test]
fn search_snippet_highlight_positions_correct_without_ellipsis() {
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
fn search_snippet_no_highlights_returns_normalized_content() {
    let content = "Hello   World\n\ntest";
    let highlights: Vec<HighlightRange> = vec![];
    let (snippet, adjusted_highlights, line_number) = SearchEngine::generate_snippet(content, &highlights, 400);

    assert_eq!(snippet, "Hello World test");
    assert!(adjusted_highlights.is_empty());
    assert_eq!(line_number, 0); // No highlight means no line number
}

// ─────────────────────────────────────────────────────────────────────────────
// BROWSE MODE vs SEARCH MODE COMPARISON
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn browse_adds_ellipsis_search_does_not() {
    // Browse mode (normalize_preview) adds ellipsis for truncated content
    let long_text = "a".repeat(500);
    let browse_preview = normalize_preview(&long_text, 200);
    assert!(browse_preview.ends_with('…'), "Browse mode adds trailing ellipsis");

    // Search mode (generate_snippet) does not add ellipsis - Swift handles that
    let highlights = vec![HighlightRange { start: 0, end: 5 }];
    let (search_snippet, _, _) = SearchEngine::generate_snippet(&long_text, &highlights, 400);
    assert!(!search_snippet.ends_with('…'), "Search mode should NOT add ellipsis");
}

#[test]
fn both_modes_normalize_whitespace_consistently() {
    let text_with_whitespace = "Hello\n\n\t  World   ";

    // Browse mode
    let browse_preview = normalize_preview(text_with_whitespace, 200);
    assert_eq!(browse_preview, "Hello World");

    // Search mode
    let highlights = vec![HighlightRange { start: 0, end: 5 }];
    let (search_snippet, _, _) = SearchEngine::generate_snippet(text_with_whitespace, &highlights, 400);
    assert_eq!(search_snippet, "Hello World");
}
