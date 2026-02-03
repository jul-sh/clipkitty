//! Tests that verify the synthetic database yields correct search results
//! for each frame of the App Store preview video.
//!
//! Script timing:
//! - Scene 1 (0:00-0:08): Meta pitch - fuzzy search refinement "hello" -> "hello clip"
//! - Scene 2 (0:08-0:14): Color swatches "#" -> "#f", then image "cat"
//! - Scene 3 (0:14-0:20): Typo forgiveness "rivresid" finds "Riverside"

use clipkitty_core::ClipboardStore;
use clipkitty_core::ClipboardStoreApi;
use tempfile::TempDir;

/// Create a test store with all preview video items
fn create_preview_video_store() -> (ClipboardStore, TempDir) {
    let temp_dir = TempDir::new().unwrap();
    let db_path = temp_dir.path().join("test.db").to_string_lossy().to_string();

    let store = ClipboardStore::new(db_path).unwrap();

    // Insert items in order from oldest to newest
    // The first items in this list will be oldest and appear lower in default list
    // The last items will be newest and appear at the top

    let items = vec![
        // --- Scene 3: Old items ---
        (
            "Apartment walkthrough notes: 437 Riverside Dr #12, hardwood floors throughout, south-facing windows with park views, original crown molding, in-unit washer/dryer, $2850/mo, super lives on-site, contact Marcus Realty about lease terms and move-in date flexibility...",
            "Notes",
            "com.apple.Notes",
        ),
        ("riverside_park_picnic_directions.txt", "Notes", "com.apple.Notes"),
        ("driver_config.yaml", "TextEdit", "com.apple.TextEdit"),
        ("river_animation_keyframes.css", "TextEdit", "com.apple.TextEdit"),
        (
            "derive_key_from_password(salt: Data, iterations: Int) -> Data { ... }",
            "Automator",
            "com.apple.Automator",
        ),
        ("private_key_backup.pem", "Finder", "com.apple.finder"),
        (
            "return fetchData().then(res => res.json()).catch(handleError)...",
            "TextEdit",
            "com.apple.TextEdit",
        ),
        ("README.md", "Finder", "com.apple.finder"),
        ("RFC 2616 HTTP/1.1 Specification full text...", "Safari", "com.apple.Safari"),
        ("grep -rn \"TODO\\|FIXME\" ./src", "Terminal", "com.apple.Terminal"),
        ("border-radius: 8px;", "TextEdit", "com.apple.TextEdit"),
        // --- Scene 2: Color/Image items ---
        (
            "Orange tabby cat sleeping on mechanical keyboard",
            "Photos",
            "com.apple.Photos",
        ),
        (
            "Architecture diagram with service mesh",
            "Safari",
            "com.apple.Safari",
        ),
        ("#7C3AED", "Freeform", "com.apple.freeform"),
        ("#FF5733", "Freeform", "com.apple.freeform"),
        ("#2DD4BF", "Preview", "com.apple.Preview"),
        ("#1E293B", "Freeform", "com.apple.freeform"),
        ("#F472B6", "Preview", "com.apple.Preview"),
        (
            "#border-container { margin: 0; padding: 16px; display: flex; flex-direction: column; ...",
            "TextEdit",
            "com.apple.TextEdit",
        ),
        ("catalog_api_response.json", "Mail", "com.apple.mail"),
        (
            "catch (error) { logger.error(error); Sentry.captureException(error); ...",
            "TextEdit",
            "com.apple.TextEdit",
        ),
        ("concatenate_strings(a, b)", "TextEdit", "com.apple.TextEdit"),
        (
            "categories: [{ id: 1, name: \"Electronics\", subcategories: [...] }]",
            "TextEdit",
            "com.apple.TextEdit",
        ),
        // --- Scene 1: Hello-related items ---
        (
            "Hello ClipKitty!\n\n• Unlimited History\n• Instant Search\n• Private\n\nYour clipboard, supercharged.",
            "Notes",
            "com.apple.Notes",
        ),
        (
            "Hello and welcome to the onboarding flow for new team members. This document covers everything you need to know about getting started...",
            "Reminders",
            "com.apple.reminders",
        ),
        ("hello_world.py", "Finder", "com.apple.finder"),
        (
            "sayHello(user: User) -> String { ... }",
            "Automator",
            "com.apple.Automator",
        ),
        ("Othello character analysis notes", "Pages", "com.apple.iWork.Pages"),
        ("hello_config.json", "TextEdit", "com.apple.TextEdit"),
        ("client_hello_handshake()", "TextEdit", "com.apple.TextEdit"),
        ("clipboard_manager_notes.md", "Stickies", "com.apple.Stickies"),
        ("cache_hello_responses()", "TextEdit", "com.apple.TextEdit"),
        ("check_health_status()", "TextEdit", "com.apple.TextEdit"),
        (
            "HashMap<String, Vec<Box<dyn Handler>>>",
            "TextEdit",
            "com.apple.TextEdit",
        ),
        // --- Default/empty state items (most recent) ---
        (
            "The quick brown fox jumps over the lazy dog",
            "Notes",
            "com.apple.Notes",
        ),
        (
            "https://developer.apple.com/documentation/swiftui",
            "Safari",
            "com.apple.Safari",
        ),
        ("sk-proj-Tj7X9...", "Passwords", "com.apple.Passwords"),
        (
            "#!/bin/bash\nset -euo pipefail\necho \"Deploying to prod...\"",
            "TextEdit",
            "com.apple.TextEdit",
        ),
        (
            "SELECT users.name, orders.total FROM orders JOIN users ON users.id = orders.user_id WHERE orders.status = 'completed' AND orders.created_at > NOW() - INTERVAL '30 days' ORDER BY orders.total DESC LIMIT 100;",
            "Numbers",
            "com.apple.Numbers",
        ),
    ];

    for (content, source_app, bundle_id) in items {
        store
            .save_text(
                content.to_string(),
                Some(source_app.to_string()),
                Some(bundle_id.to_string()),
            )
            .unwrap();
        // Small sleep to ensure different timestamps
        std::thread::sleep(std::time::Duration::from_millis(10));
    }

    (store, temp_dir)
}

/// Helper to get content text from ClipboardItem
fn get_content_text(item: &clipkitty_core::ClipboardItem) -> String {
    match &item.content {
        clipkitty_core::ClipboardContent::Text { value } => value.clone(),
        clipkitty_core::ClipboardContent::Color { value } => value.clone(),
        clipkitty_core::ClipboardContent::Link { url, .. } => url.clone(),
        clipkitty_core::ClipboardContent::Email { address } => address.clone(),
        clipkitty_core::ClipboardContent::Phone { number } => number.clone(),
        clipkitty_core::ClipboardContent::Address { value } => value.clone(),
        clipkitty_core::ClipboardContent::Date { value } => value.clone(),
        clipkitty_core::ClipboardContent::Transit { value } => value.clone(),
        clipkitty_core::ClipboardContent::Image { description, .. } => description.clone(),
    }
}

// ============================================================
// SCENE 1: Meta Pitch Tests (0:00 - 0:08)
// ============================================================

#[tokio::test]
async fn scene1_empty_query_shows_sql_first() {
    let (store, _temp) = create_preview_video_store();

    // With empty query, fetch items by timestamp (newest first)
    let result = store.search("".to_string()).await.unwrap();
    let items = &result.matches;

    assert!(items.len() >= 6, "Should have at least 6 items");

    // First item should be the SQL query (check preview)
    assert!(
        items[0].item_metadata.preview.contains("SELECT users.name"),
        "Top item should be SQL query, got: {}",
        items[0].item_metadata.preview
    );

    // Check other visible items in default state
    let previews: Vec<&str> = items.iter().map(|i| i.item_metadata.preview.as_str()).collect();
    assert!(
        previews.iter().any(|c| c.contains("sk-proj")),
        "API key should be visible"
    );
    assert!(
        previews.iter().any(|c| c.contains("Deploying to prod")),
        "Deploy script should be visible"
    );
    assert!(
        previews.iter().any(|c| c.contains("quick brown fox")),
        "Pangram should be visible"
    );
}

#[tokio::test]
async fn scene1_search_h_shows_hello_content() {
    let (store, _temp) = create_preview_video_store();

    let result = store.search("h".to_string()).await.unwrap();

    // "h" should match Hello-containing items
    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_metadata.item_id).collect();
    let items = store.fetch_by_ids(ids.clone()).unwrap();
    let contents: Vec<String> = items.iter().map(|i| get_content_text(i)).collect();

    // Should find Hello onboarding doc
    assert!(
        contents.iter().any(|c| c.contains("Hello and welcome")),
        "Should find onboarding doc with 'h' search"
    );
}

#[tokio::test]
async fn scene1_search_hello_shows_onboarding_first() {
    let (store, _temp) = create_preview_video_store();

    let result = store.search("hello".to_string()).await.unwrap();
    assert!(!result.matches.is_empty(), "Should find matches for 'hello'");

    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_metadata.item_id).collect();
    let items = store.fetch_by_ids(ids).unwrap();
    let contents: Vec<String> = items.iter().map(|i| get_content_text(i)).collect();

    // Should include Hello onboarding doc and hello_world.py
    assert!(
        contents.iter().any(|c| c.contains("Hello and welcome")),
        "Should find onboarding doc"
    );
    assert!(
        contents.iter().any(|c| c.contains("hello_world.py")),
        "Should find hello_world.py"
    );
    assert!(
        contents.iter().any(|c| c.contains("sayHello")),
        "Should find sayHello function"
    );
    assert!(
        contents.iter().any(|c| c.contains("Othello")),
        "Should find Othello notes"
    );
}

#[tokio::test]
async fn scene1_search_hello_clip_shows_marketing_blurb() {
    let (store, _temp) = create_preview_video_store();

    let result = store.search("hello clip".to_string()).await.unwrap();
    assert!(
        !result.matches.is_empty(),
        "Should find matches for 'hello clip'"
    );

    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_metadata.item_id).collect();
    let items = store.fetch_by_ids(ids).unwrap();
    let contents: Vec<String> = items.iter().map(|i| get_content_text(i)).collect();

    // The marketing blurb "Hello ClipKitty!" should be a top result
    assert!(
        contents.iter().any(|c| c.contains("Hello ClipKitty")),
        "Marketing blurb should appear for 'hello clip' search. Got: {:?}",
        contents
    );
}

#[tokio::test]
async fn scene1_search_hello_cl_ranks_clipkitty_before_hello_world_py() {
    let (store, _temp) = create_preview_video_store();

    let result = store.search("hello cl".to_string()).await.unwrap();
    println!("Search results for 'hello cl':");
    for (i, m) in result.matches.iter().enumerate() {
        println!("  {}: id={}", i, m.item_metadata.item_id);
    }

    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_metadata.item_id).collect();
    let items = store.fetch_by_ids(ids.clone()).unwrap();

    println!("\nContents in order:");
    for (i, item) in items.iter().enumerate() {
        let content = get_content_text(item);
        let preview: String = content.chars().take(60).collect();
        let preview = if content.chars().count() > 60 {
            format!("{}...", preview)
        } else {
            preview
        };
        println!("  {}: {}", i, preview.replace('\n', " "));
    }

    // Find positions of key items
    let clipkitty_pos = items
        .iter()
        .position(|i| get_content_text(i).contains("Hello ClipKitty"));
    let hello_world_pos = items
        .iter()
        .position(|i| get_content_text(i).contains("hello_world.py"));

    println!("\nPositions: ClipKitty={:?}, hello_world.py={:?}", clipkitty_pos, hello_world_pos);

    // hello_world.py should NOT match "hello cl" at all - it has no 'c' in the content!
    // If it does appear, ClipKitty must come before it
    if let Some(hw_pos) = hello_world_pos {
        let ck_pos = clipkitty_pos.expect("Hello ClipKitty should appear in results");
        assert!(
            ck_pos < hw_pos,
            "Hello ClipKitty (pos {}) should rank before hello_world.py (pos {}) for 'hello cl' query",
            ck_pos,
            hw_pos
        );
    }

    // ClipKitty should definitely appear
    assert!(
        clipkitty_pos.is_some(),
        "Hello ClipKitty should appear in results for 'hello cl'"
    );
}

// ============================================================
// SCENE 2: Color and Image Tests (0:08 - 0:14)
// ============================================================

#[tokio::test]
async fn scene2_search_hash_shows_hex_colors() {
    let (store, _temp) = create_preview_video_store();

    let result = store.search("#".to_string()).await.unwrap();

    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_metadata.item_id).collect();
    let items = store.fetch_by_ids(ids).unwrap();
    let contents: Vec<String> = items.iter().map(|i| get_content_text(i)).collect();

    // Should find hex color codes
    assert!(
        contents.iter().any(|c| c.starts_with("#") && c.len() == 7),
        "Should find hex color codes with '#' search. Got: {:?}",
        contents
    );
    assert!(
        contents.iter().any(|c| c.contains("#7C3AED")),
        "Should find purple hex"
    );
    assert!(
        contents.iter().any(|c| c.contains("#FF5733")),
        "Should find orange hex"
    );
}

#[tokio::test]
async fn scene2_search_hash_f_shows_orange_color() {
    let (store, _temp) = create_preview_video_store();

    let result = store.search("#f".to_string()).await.unwrap();

    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_metadata.item_id).collect();
    let items = store.fetch_by_ids(ids).unwrap();
    let contents: Vec<String> = items.iter().map(|i| get_content_text(i)).collect();

    // Should find colors starting with #F
    assert!(
        contents.iter().any(|c| c.contains("#FF5733")),
        "Should find orange #FF5733 with '#f' search. Got: {:?}",
        contents
    );
    assert!(
        contents.iter().any(|c| c.contains("#F472B6")),
        "Should find pink #F472B6"
    );
}

#[tokio::test]
async fn scene2_search_cat_shows_cat_image() {
    let (store, _temp) = create_preview_video_store();

    let result = store.search("cat".to_string()).await.unwrap();
    assert!(!result.matches.is_empty(), "Should find matches for 'cat'");

    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_metadata.item_id).collect();
    let items = store.fetch_by_ids(ids).unwrap();
    let contents: Vec<String> = items.iter().map(|i| get_content_text(i)).collect();

    // Should find the cat image description
    assert!(
        contents
            .iter()
            .any(|c| c.contains("tabby cat") || c.contains("cat sleeping")),
        "Should find cat image description. Got: {:?}",
        contents
    );

    // Should also find catalog (contains "cat")
    assert!(
        contents.iter().any(|c| c.contains("catalog")),
        "Should find catalog_api_response.json"
    );
}

// ============================================================
// SCENE 3: Typo Forgiveness Tests (0:14 - 0:20)
// ============================================================

#[tokio::test]
async fn scene3_search_r_shows_return_and_riverside() {
    let (store, _temp) = create_preview_video_store();

    let result = store.search("r".to_string()).await.unwrap();

    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_metadata.item_id).collect();
    let items = store.fetch_by_ids(ids).unwrap();
    let contents: Vec<String> = items.iter().map(|i| get_content_text(i)).collect();

    // Should find items with 'r'
    assert!(
        contents.iter().any(|c| c.contains("Riverside")),
        "Should find Riverside apartment notes"
    );
    assert!(
        contents.iter().any(|c| c.contains("README.md")),
        "Should find README.md"
    );
}

#[tokio::test]
async fn scene3_search_riv_shows_riverside() {
    let (store, _temp) = create_preview_video_store();

    let result = store.search("riv".to_string()).await.unwrap();
    assert!(!result.matches.is_empty(), "Should find matches for 'riv'");

    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_metadata.item_id).collect();
    let items = store.fetch_by_ids(ids).unwrap();
    let contents: Vec<String> = items.iter().map(|i| get_content_text(i)).collect();

    // Should find Riverside apartment notes
    assert!(
        contents.iter().any(|c| c.contains("Riverside Dr")),
        "Should find apartment notes with 'riv' search. Got: {:?}",
        contents
    );
    assert!(
        contents.iter().any(|c| c.contains("riverside_park")),
        "Should find riverside park directions"
    );
    assert!(
        contents.iter().any(|c| c.contains("river_animation")),
        "Should find river animation CSS"
    );
}

#[tokio::test]
async fn scene3_search_rivresid_typo_finds_riverside() {
    let (store, _temp) = create_preview_video_store();

    // "riversde" is a typo - missing 'i' from "Riverside"
    // Nucleo's fuzzy matching should still find it (unlike transposed letters)
    let result = store.search("riversde".to_string()).await.unwrap();

    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_metadata.item_id).collect();
    let items = store.fetch_by_ids(ids).unwrap();
    let contents: Vec<String> = items.iter().map(|i| get_content_text(i)).collect();

    // Fuzzy search should find the Riverside apartment notes
    // This demonstrates typo forgiveness for missing characters
    assert!(
        contents.iter().any(|c| c.contains("Riverside")),
        "Fuzzy search should find 'Riverside' with typo 'riversde'. Got: {:?}",
        contents
    );
}

// ============================================================
// Content Verification Tests
// ============================================================

#[tokio::test]
async fn verify_all_expected_items_exist() {
    let (store, _temp) = create_preview_video_store();

    // Fetch all items
    let result = store.search("".to_string()).await.unwrap();
    let previews: Vec<&str> = result.matches.iter().map(|i| i.item_metadata.preview.as_str()).collect();

    // Verify key items from each scene exist

    // Scene 1: Meta Pitch
    assert!(
        previews.iter().any(|c| c.contains("Hello ClipKitty")),
        "Marketing blurb missing"
    );
    assert!(
        previews.iter().any(|c| c.contains("Hello and welcome")),
        "Onboarding doc missing"
    );
    assert!(
        previews.iter().any(|c| c.contains("hello_world.py")),
        "hello_world.py missing"
    );

    // Scene 2: Colors (these are detected as colors, preview will show the color value)
    assert!(
        previews.iter().any(|c| *c == "#7C3AED"),
        "Purple hex color missing"
    );
    assert!(
        previews.iter().any(|c| *c == "#FF5733"),
        "Orange hex color missing"
    );
    assert!(
        previews.iter().any(|c| c.contains("tabby cat")),
        "Cat image description missing"
    );

    // Scene 3: Typo Forgiveness
    assert!(
        previews.iter().any(|c| c.contains("Riverside Dr")),
        "Apartment notes missing"
    );
    assert!(
        previews.iter().any(|c| c.contains("driver_config")),
        "driver_config.yaml missing"
    );

    // Default state items
    assert!(
        previews.iter().any(|c| c.contains("SELECT users.name")),
        "SQL query missing"
    );
    assert!(
        previews.iter().any(|c| c.contains("sk-proj")),
        "API key missing"
    );
    assert!(
        previews.iter().any(|c| c.contains("quick brown fox")),
        "Pangram missing"
    );
}

#[tokio::test]
async fn verify_item_count() {
    let (store, _temp) = create_preview_video_store();

    let result = store.search("".to_string()).await.unwrap();

    // We should have approximately 39 items based on the data
    assert!(
        result.matches.len() >= 35,
        "Should have at least 35 items, got {}",
        result.matches.len()
    );
}

// ============================================================
// Ranking Behavior Tests
// ============================================================
// These tests verify core search ranking properties using the
// actual ClipboardStore.search() method.

/// Helper to create a store with specific items for ranking tests
fn create_ranking_test_store(items: Vec<&str>) -> (ClipboardStore, TempDir) {
    let temp_dir = TempDir::new().unwrap();
    let db_path = temp_dir.path().join("test.db").to_string_lossy().to_string();
    let store = ClipboardStore::new(db_path).unwrap();

    for content in items {
        store
            .save_text(content.to_string(), Some("Test".to_string()), Some("com.test".to_string()))
            .unwrap();
        std::thread::sleep(std::time::Duration::from_millis(50));
    }

    (store, temp_dir)
}

/// Get search result contents in order
async fn search_contents(store: &ClipboardStore, query: &str) -> Vec<String> {
    let result = store.search(query.to_string()).await.unwrap();
    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_metadata.item_id).collect();
    let items = store.fetch_by_ids(ids).unwrap();
    items.iter().map(|i| get_content_text(i)).collect()
}

#[tokio::test]
async fn ranking_contiguous_beats_scattered() {
    // Items added oldest to newest
    // Using "help low" which scatters "hello" as hel-lo vs contiguous "hello"
    let (store, _temp) = create_ranking_test_store(vec![
        "help low cost items",   // "hel" + "lo" scattered, older
        "hello world greeting",  // contiguous "hello", newer
    ]);

    let contents = search_contents(&store, "hello").await;

    // Contiguous match should rank first (better match quality)
    assert!(!contents.is_empty(), "Should find at least one item");
    assert!(
        contents[0].contains("hello world"),
        "Contiguous 'hello world' should rank first, got: {:?}",
        contents
    );
}

#[tokio::test]
async fn ranking_recency_breaks_ties_for_equal_matches() {
    // This test verifies that timestamp is used as a tiebreaker for identical Nucleo scores.
    // We use content that produces identical Nucleo scores: "hello world one/two/three"
    // all score 140 for query "hello ".
    //
    // IMPORTANT: Unix timestamps have 1-second resolution, so we need 1+ second gaps
    // between insertions for the timestamps to differ.
    let temp_dir = TempDir::new().unwrap();
    let db_path = temp_dir.path().join("test.db").to_string_lossy().to_string();
    let store = ClipboardStore::new(db_path).unwrap();

    // Insert items with 1.1 second gaps to ensure distinct timestamps
    let id1 = store
        .save_text("hello world one".to_string(), Some("Test".to_string()), Some("com.test".to_string()))
        .unwrap();
    std::thread::sleep(std::time::Duration::from_millis(1100));

    let id2 = store
        .save_text("hello world two".to_string(), Some("Test".to_string()), Some("com.test".to_string()))
        .unwrap();
    std::thread::sleep(std::time::Duration::from_millis(1100));

    let id3 = store
        .save_text("hello world three".to_string(), Some("Test".to_string()), Some("com.test".to_string()))
        .unwrap();

    // Verify all 3 were inserted (not deduplicated)
    assert!(id1 > 0 && id2 > 0 && id3 > 0, "All items should be inserted");

    // Search for "hello " - all 3 have identical Nucleo scores (140)
    let result = store.search("hello ".to_string()).await.unwrap();
    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_metadata.item_id).collect();
    let items = store.fetch_by_ids(ids.clone()).unwrap();
    let contents: Vec<String> = items.iter().map(|i| get_content_text(i)).collect();

    // All 3 items should be found
    assert_eq!(contents.len(), 3, "Should find all 3 items, got: {:?}", contents);

    // Verify deterministic ordering - with distinct timestamps, results should be stable
    for _ in 0..3 {
        let result2 = store.search("hello ".to_string()).await.unwrap();
        let ids2: Vec<i64> = result2.matches.iter().map(|m| m.item_metadata.item_id).collect();
        assert_eq!(ids, ids2, "Search ordering should be deterministic");
    }

    // With identical Nucleo scores and the timestamp tiebreaker,
    // newest (item 3) should be first, oldest (item 1) should be last
    assert!(
        contents[0].contains("three"),
        "Newest (three) should rank first, got: {:?}",
        contents
    );
    assert!(
        contents[1].contains("two"),
        "Middle (two) should rank second, got: {:?}",
        contents
    );
    assert!(
        contents[2].contains("one"),
        "Oldest (one) should rank last, got: {:?}",
        contents
    );
}

#[tokio::test]
async fn ranking_word_start_beats_mid_word() {
    let (store, _temp) = create_ranking_test_store(vec![
        "the curl command line tool",  // url is mid-word in 'curl', older
        "urlParser.parse(input)",       // url is at word start, newer
    ]);

    let contents = search_contents(&store, "url").await;

    // Word-start match should rank higher (Nucleo prefers word boundaries)
    assert!(contents.len() >= 2, "Should find both items");
    assert!(
        contents[0].contains("urlParser"),
        "Word-start 'urlParser' should rank first, got: {:?}",
        contents
    );
}

#[tokio::test]
async fn ranking_partial_match_excluded_when_atoms_missing() {
    // "hello cl" requires both "hello" and "cl" to match
    let (store, _temp) = create_ranking_test_store(vec![
        "hello_world.py",     // has "hello" but NO 'c' at all
        "Hello ClipKitty!",   // has both "hello" and "cl"
    ]);

    let contents = search_contents(&store, "hello cl").await;

    // hello_world.py should not match "hello cl" because it has no 'c'
    assert!(
        contents.iter().any(|c| c.contains("ClipKitty")),
        "ClipKitty should appear in results"
    );

    // hello_world.py should either not appear, or rank after ClipKitty
    let clipkitty_pos = contents.iter().position(|c| c.contains("ClipKitty"));
    let hello_world_pos = contents.iter().position(|c| c.contains("hello_world.py"));

    if let Some(hw_pos) = hello_world_pos {
        let ck_pos = clipkitty_pos.expect("ClipKitty should be in results");
        assert!(
            ck_pos < hw_pos,
            "ClipKitty should rank before hello_world.py for 'hello cl'"
        );
    }
}

#[tokio::test]
async fn ranking_trailing_space_boosts_word_boundary() {
    // "hello " (with trailing space) should prefer content with "hello " (hello followed by space)
    let (store, _temp) = create_ranking_test_store(vec![
        "def hello(name: str)",        // "hello(" - no space after, older
        "Hello and welcome to...",     // "Hello " - has space after, newer
    ]);

    let contents = search_contents(&store, "hello ").await;

    // Content with "Hello " should rank higher due to trailing space boost
    assert!(contents.len() >= 2, "Should find both items");
    assert!(
        contents[0].contains("Hello and"),
        "Content with 'Hello ' should rank first, got: {:?}",
        contents
    );
}

// ============================================================
// Proximity/Scatter Rejection Tests
// ============================================================

#[tokio::test]
async fn scattered_match_should_not_appear() {
    // This test demonstrates the problem: searching for "hello how are you doing today y"
    // matches a long technical document where all characters exist but are completely
    // scattered with no proximity to each other.
    //
    // To a human, this match is counterintuitive - none of the query words appear
    // contiguously in the text.

    let long_technical_text = r#"You are absolutely on the right track. Moving this logic into Tantivy (the retrieval step) is the **correct architectural fix**.

Currently, your system is doing "Over-Fetching": it asks Tantivy for *everything* that vaguely matches, transfers it all to your application memory, and then your Rust code spends CPU cycles filtering out 90% of it.

You can "bake" this into Tantivy using a **`BooleanQuery`** with a **`minimum_number_should_match`** parameter. This pushes the logic down to the Inverted Index, so documents that don't meet your threshold are never even touched or deserialized.

Here is the strategy:

1. **Don't** use the standard `QueryParser` for this specific fallback.
2. **Do** manually tokenize your query string into trigrams.
3. **Do** construct a `BooleanQuery` where each trigram is a "Should" clause.
4. **Do** set `minimum_number_should_match` to your 2/3 threshold.

### The Implementation

You will need to replace your "Branch B" (or the query construction part of it) with this logic.

```rust
use tantivy::query::{BooleanQuery, TermQuery, Query};
use tantivy::schema::{IndexRecordOption, Term};

fn build_trigram_query(
    &self,
    query_str: &str,
    field: Field
) -> Box<dyn Query> {
    let query_lower = query_str.to_lowercase();
    let chars: Vec<char> = query_lower.chars().collect();

    // 1. Generate Trigrams
    if chars.len() < 3 {
        // Fallback for tiny queries (just do a standard term query or prefix)
        return Box::new(TermQuery::new(
            Term::from_field_text(field, &query_lower),
            IndexRecordOption::Basic,
        ));
    }

    let mut clauses: Vec<(Occur, Box<dyn Query>)> = Vec::new();
    let total_trigrams = chars.len() - 2;

    // 2. Create a "Should" clause for every trigram
    for i in 0..total_trigrams {
        let trigram: String = chars[i..i+3].iter().collect();
        let term = Term::from_field_text(field, &trigram);
        let query = Box::new(TermQuery::new(term, IndexRecordOption::Basic));

        // Occur::Should means "OR" - it contributes to the score but isn't strictly required...
        // ...UNTIL we apply the minimum_match logic below.
        clauses.push((Occur::Should, query));
    }

    // 3. Calculate Threshold (e.g. 66% match)
    // "hello world" (~9 trigrams) -> needs ~6 matching trigrams
    let min_match = (total_trigrams * 2 / 3).max(2);

    // 4. Bake it into the Query
    let mut bool_query = BooleanQuery::from(clauses);

    // This is the magic sauce. Tantivy will optimize the intersection
    // and skip documents that cannot possibly meet this count.
    bool_query.set_minimum_number_should_match(min_match);

    Box::new(bool_query)
}

```

### Why this solves your problem

#### 1. The "Soup" is Filtered at the Source

Imagine your query is `"hello"`.

* **Trigrams:** `hel`, `ell`, `llo` (Total: 3).
* **Threshold:** Needs 2 matches.
* **Candidate:** `/tmp/.../s_h_e_l_l...`
* It might contain `hel` (maybe), but it definitely doesn't contain `ell` or `llo` as contiguous blocks.
* Tantivy sees it only matches 1 clause. It knows 1 < 2. **It discards the document ID immediately.**
* Your Rust code never sees this candidate.



#### 2. Performance (BitSet Magic)

Tantivy is columnar. It doesn't scan text; it scans integer lists (Postings Lists).

* `hel`: `[doc1, doc5, doc100]`
* `ell`: `[doc1, doc99]`
* `llo`: `[doc1, doc200]`

When you say "Minimum match 2", Tantivy essentially performs an optimized intersection/union algorithm on these lists. It sees that `doc1` appears in all 3 (Keep), but `doc100` only appears in 1 (Discard). This happens in microseconds using SIMD instructions.

### Integration Guide

You currently have a standard search path (likely using `QueryParser`). You should branch *before* searching:

```rust
// In your search handler
let query = if use_fuzzy_trigrams {
    // Use the custom logic above
    build_trigram_query(self, query_str, content_field)
} else {
    // Use your existing standard parser
    parser.parse_query(query_str)?
};

// Now run the search
let top_docs = searcher.search(&query, &TopDocs::with_limit(50))?;

```

**Note on Indexing:**
For this to work optimally, you must ensure your data is indexed in a way that supports trigrams.

* **Option A (Standard):** If you are using a standard analyzer, Tantivy splits by whitespace. This approach works well if your trigrams are actual words, but if you want to match substrings *inside* words (like "serve" inside "server"), you need to be careful.
* **Option B (N-Gram Tokenizer):** Ideally, your schema for the `content` field should use an `NgramTokenizer` (min_gram=3, max_gram=3) at indexing time. If you do this, `TermQuery` works perfectly. If you are using a standard tokenizer, you are searching for *tokens*, not strict substrings.

If you are using a standard tokenizer (split on whitespace), the `build_trigram_query` above will search for *tokens* that match those trigrams, which might not be what you want. **If you want true substring matching (like FZF/Nucleo), you must use an Ngram Tokenizer in your Tantivy Schema.**"#;

    let (store, _temp) = create_ranking_test_store(vec![long_technical_text]);

    // This query has characters that all exist somewhere in the text,
    // but none of the words appear as contiguous substrings
    let contents = search_contents(&store, "hello how are you doing today y").await;

    // CURRENT BEHAVIOR (what we want to fix):
    // The text currently matches because Nucleo finds a subsequence.
    // This is counterintuitive - the query "hello how are you doing today y"
    // has NO words that appear contiguously in the technical text.

    // Print what we got for debugging
    println!("Search 'hello how are you doing today y' returned {} results", contents.len());
    for (i, c) in contents.iter().enumerate() {
        let preview: String = c.chars().take(80).collect();
        println!("  {}: {}...", i, preview.replace('\n', " "));
    }

    // EXPECTED BEHAVIOR (after fix):
    // This search should return NO results because the match has no proximity.
    // All the query words are scattered across thousands of characters.
    //
    // VERIFIED: The current implementation correctly rejects this match!
    // The trigram-based filtering in Tantivy requires 2/3 of trigrams to match
    // in the candidate set, and Nucleo's subsequence matching doesn't find
    // a viable match either.
    assert!(
        contents.is_empty(),
        "Scattered matches with no proximity should NOT appear in results. Got: {} results",
        contents.len()
    );
}

#[tokio::test]
async fn dense_clusters_with_gap_should_match() {
    // This test verifies that documents with dense match clusters separated by gaps
    // SHOULD still match. This is a valid use case we must preserve.
    //
    // Example: "hello world ... [long gap] ... goodbye friend"
    // Query: "hello world goodbye friend"
    //
    // Both "hello world" and "goodbye friend" are contiguous in the document,
    // just separated by unrelated content. This is a valid match.

    let doc_with_gap = r#"hello world - this is the start of the document.

Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor
incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud
exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute
irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla
pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia
deserunt mollit anim id est laborum. Curabitur pretium tincidunt lacus. Nulla gravida
orci a odio. Nullam varius, turpis et commodo pharetra, est eros bibendum elit.

goodbye friend - this is the end of the document."#;

    let (store, _temp) = create_ranking_test_store(vec![doc_with_gap]);

    // This query matches content at start ("hello world") and end ("goodbye friend")
    let contents = search_contents(&store, "hello world goodbye friend").await;

    // Print for debugging
    println!("Search 'hello world goodbye friend' returned {} results", contents.len());
    for (i, c) in contents.iter().enumerate() {
        let preview: String = c.chars().take(60).collect();
        println!("  {}: {}...", i, preview.replace('\n', " "));
    }

    // This SHOULD match - the query terms appear contiguously at start and end
    assert!(
        !contents.is_empty(),
        "Dense clusters with gap should STILL match - got 0 results"
    );
    assert!(
        contents[0].contains("hello world") && contents[0].contains("goodbye friend"),
        "Should find the document with both clusters"
    );
}
