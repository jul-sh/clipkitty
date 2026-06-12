//! End-to-end diacritic folding regression tests (filtering-intuition-review:
//! diacritic-blind matching). Queries typed without accents must find accented
//! content (and vice versa), classify as Exact, and highlight the original
//! text at the right offsets.

use purr::{
    ClipboardStore, ClipboardStoreApi, HighlightKind, ListPresentationProfile, MatchedExcerpt,
    RowPresentation,
};
use tempfile::TempDir;

const CORPUS: [&str; 5] = [
    "résumé draft v2",
    "über uns page copy",
    "café receipt",
    "Zürich trip notes",
    "cafe nights playlist",
];

fn store_with_items(items: &[&str]) -> (ClipboardStore, TempDir) {
    let dir = TempDir::new().unwrap();
    let db_path = dir.path().join("test.db").to_string_lossy().to_string();
    let store = ClipboardStore::new(db_path).unwrap();
    for content in items {
        store.save_text(content.to_string(), None, None).unwrap();
    }
    (store, dir)
}

/// Search and return (original content, ready excerpt) per match, in rank order.
async fn search_excerpts(store: &ClipboardStore, query: &str) -> Vec<(String, MatchedExcerpt)> {
    let result = store
        .search(query.to_string(), ListPresentationProfile::CompactRow)
        .await
        .unwrap();
    let ids: Vec<String> = result
        .matches
        .iter()
        .map(|m| m.item_metadata.item_id.clone())
        .collect();
    let items = store.fetch_by_ids(ids).unwrap();
    result
        .matches
        .iter()
        .zip(items.iter())
        .map(|(m, item)| {
            let excerpt = match &m.presentation {
                RowPresentation::Matched { excerpt } => excerpt.clone(),
                other => panic!("expected ready matched excerpt, got {other:?}"),
            };
            (item.content.text_content().to_string(), excerpt)
        })
        .collect()
}

fn excerpt_for<'a>(rows: &'a [(String, MatchedExcerpt)], content: &str) -> &'a MatchedExcerpt {
    rows.iter()
        .find(|(c, _)| c == content)
        .map(|(_, excerpt)| excerpt)
        .unwrap_or_else(|| {
            let found: Vec<&String> = rows.iter().map(|(c, _)| c).collect();
            panic!("expected {content:?} in results, got {found:?}")
        })
}

fn utf16_slice(text: &str, start: u64, end: u64) -> String {
    let code_units: Vec<u16> = text.encode_utf16().collect();
    String::from_utf16(&code_units[start as usize..end as usize]).unwrap()
}

#[tokio::test]
async fn resume_query_finds_accented_resume_item_as_exact() {
    let (store, _dir) = store_with_items(&CORPUS);
    let rows = search_excerpts(&store, "resume").await;
    let excerpt = excerpt_for(&rows, "résumé draft v2");
    assert_eq!(excerpt.highlights[0].kind, HighlightKind::Exact);
    assert_eq!(
        utf16_slice(
            &excerpt.text,
            excerpt.highlights[0].utf16_start,
            excerpt.highlights[0].utf16_end,
        ),
        "résumé"
    );
}

#[tokio::test]
async fn uber_query_finds_accented_uber_item() {
    let (store, _dir) = store_with_items(&CORPUS);
    let rows = search_excerpts(&store, "uber").await;
    let excerpt = excerpt_for(&rows, "über uns page copy");
    assert_eq!(excerpt.highlights[0].kind, HighlightKind::Exact);
}

#[tokio::test]
async fn zurich_query_upgrades_zurich_item_from_fuzzy_to_exact() {
    let (store, _dir) = store_with_items(&CORPUS);
    let rows = search_excerpts(&store, "zurich").await;
    let excerpt = excerpt_for(&rows, "Zürich trip notes");
    assert_eq!(
        excerpt.highlights[0].kind,
        HighlightKind::Exact,
        "folded match must classify as Exact, not burn the typo budget"
    );
    assert_eq!(
        utf16_slice(
            &excerpt.text,
            excerpt.highlights[0].utf16_start,
            excerpt.highlights[0].utf16_end,
        ),
        "Zürich"
    );
}

#[tokio::test]
async fn cafe_query_finds_accented_and_plain_items_both_exact() {
    let (store, _dir) = store_with_items(&CORPUS);
    let rows = search_excerpts(&store, "cafe").await;
    for content in ["café receipt", "cafe nights playlist"] {
        let excerpt = excerpt_for(&rows, content);
        assert_eq!(
            excerpt.highlights[0].kind,
            HighlightKind::Exact,
            "{content:?} should be an Exact match for 'cafe'"
        );
    }
}

#[tokio::test]
async fn accented_cafe_query_finds_both_cafe_items() {
    let (store, _dir) = store_with_items(&CORPUS);
    let rows = search_excerpts(&store, "café").await;
    excerpt_for(&rows, "café receipt");
    excerpt_for(&rows, "cafe nights playlist");
}

#[tokio::test]
async fn folded_highlight_utf16_offsets_correct() {
    // Accented chars BEFORE the match: guards the 1:1 char-count invariant
    // end-to-end through create_matched_excerpt.
    let content = "naïve note: see résumé draft";
    let (store, _dir) = store_with_items(&[content]);
    let rows = search_excerpts(&store, "resume").await;
    let excerpt = excerpt_for(&rows, content);

    assert_eq!(
        excerpt.text, content,
        "short content should not be windowed"
    );
    assert_eq!(excerpt.highlights.len(), 1);
    assert_eq!(excerpt.highlights[0].utf16_start, 16);
    assert_eq!(excerpt.highlights[0].utf16_end, 22);
    assert_eq!(
        utf16_slice(
            &excerpt.text,
            excerpt.highlights[0].utf16_start,
            excerpt.highlights[0].utf16_end,
        ),
        "résumé"
    );
}

#[tokio::test]
async fn short_query_contains_tier_folds() {
    let content = "résumé receipt";
    let (store, _dir) = store_with_items(&[content]);

    // 1-2 char queries take the streaming short-query path, not the index.
    for query in ["re", "ré"] {
        let rows = search_excerpts(&store, query).await;
        let excerpt = excerpt_for(&rows, content);
        assert_eq!(
            excerpt.highlights.len(),
            1,
            "short query {query:?} should produce one highlight"
        );
        assert_eq!(
            utf16_slice(
                &excerpt.text,
                excerpt.highlights[0].utf16_start,
                excerpt.highlights[0].utf16_end,
            ),
            "ré",
            "short query {query:?} should highlight the folded prefix"
        );
    }
}
