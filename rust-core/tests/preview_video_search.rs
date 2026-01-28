//! Tests that verify the synthetic database yields correct search results
//! for each frame of the App Store preview video.
//!
//! Script timing:
//! - Scene 1 (0:00-0:08): Meta pitch - fuzzy search refinement "hello" -> "hello clip"
//! - Scene 2 (0:08-0:14): Color swatches "#" -> "#f", then image "cat"
//! - Scene 3 (0:14-0:20): Typo forgiveness "rivresid" finds "Riverside"

use clipkitty_core::ClipboardStore;
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

// ============================================================
// SCENE 1: Meta Pitch Tests (0:00 - 0:08)
// ============================================================

#[test]
fn scene1_empty_query_shows_sql_first() {
    let (store, _temp) = create_preview_video_store();

    // With empty query, fetch items by timestamp (newest first)
    let result = store.fetch_items(None, 6).unwrap();
    let items = result.items;

    assert!(items.len() >= 6, "Should have at least 6 items");

    // First item should be the SQL query
    assert!(
        items[0].text_content().contains("SELECT users.name"),
        "Top item should be SQL query, got: {}",
        items[0].text_content()
    );

    // Check other visible items in default state
    let contents: Vec<String> = items.iter().map(|i| i.text_content().to_string()).collect();
    assert!(
        contents.iter().any(|c| c.contains("sk-proj")),
        "API key should be visible"
    );
    assert!(
        contents.iter().any(|c| c.contains("Deploying to prod")),
        "Deploy script should be visible"
    );
    assert!(
        contents.iter().any(|c| c.contains("quick brown fox")),
        "Pangram should be visible"
    );
}

#[test]
fn scene1_search_h_shows_hello_content() {
    let (store, _temp) = create_preview_video_store();

    let result = store.search("h".to_string()).unwrap();

    // "h" should match Hello-containing items
    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_id).collect();
    let items = store.fetch_by_ids(ids.clone()).unwrap();
    let contents: Vec<String> = items.iter().map(|i| i.text_content().to_string()).collect();

    // Should find Hello onboarding doc
    assert!(
        contents.iter().any(|c| c.contains("Hello and welcome")),
        "Should find onboarding doc with 'h' search"
    );
}

#[test]
fn scene1_search_hello_shows_onboarding_first() {
    let (store, _temp) = create_preview_video_store();

    let result = store.search("hello".to_string()).unwrap();
    assert!(!result.matches.is_empty(), "Should find matches for 'hello'");

    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_id).collect();
    let items = store.fetch_by_ids(ids).unwrap();
    let contents: Vec<String> = items.iter().map(|i| i.text_content().to_string()).collect();

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

#[test]
fn scene1_search_hello_clip_shows_marketing_blurb() {
    let (store, _temp) = create_preview_video_store();

    let result = store.search("hello clip".to_string()).unwrap();
    assert!(
        !result.matches.is_empty(),
        "Should find matches for 'hello clip'"
    );

    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_id).collect();
    let items = store.fetch_by_ids(ids).unwrap();
    let contents: Vec<String> = items.iter().map(|i| i.text_content().to_string()).collect();

    // The marketing blurb "Hello ClipKitty!" should be a top result
    assert!(
        contents.iter().any(|c| c.contains("Hello ClipKitty")),
        "Marketing blurb should appear for 'hello clip' search. Got: {:?}",
        contents
    );
}

#[test]
fn scene1_search_hello_cl_ranks_clipkitty_before_hello_world_py() {
    let (store, _temp) = create_preview_video_store();

    let result = store.search("hello cl".to_string()).unwrap();
    println!("Search results for 'hello cl':");
    for (i, m) in result.matches.iter().enumerate() {
        println!("  {}: id={}", i, m.item_id);
    }

    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_id).collect();
    let items = store.fetch_by_ids(ids.clone()).unwrap();

    println!("\nContents in order:");
    for (i, item) in items.iter().enumerate() {
        let content = item.text_content();
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
        .position(|i| i.text_content().contains("Hello ClipKitty"));
    let hello_world_pos = items
        .iter()
        .position(|i| i.text_content().contains("hello_world.py"));

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

#[test]
fn scene2_search_hash_shows_hex_colors() {
    let (store, _temp) = create_preview_video_store();

    let result = store.search("#".to_string()).unwrap();

    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_id).collect();
    let items = store.fetch_by_ids(ids).unwrap();
    let contents: Vec<String> = items.iter().map(|i| i.text_content().to_string()).collect();

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

#[test]
fn scene2_search_hash_f_shows_orange_color() {
    let (store, _temp) = create_preview_video_store();

    let result = store.search("#f".to_string()).unwrap();

    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_id).collect();
    let items = store.fetch_by_ids(ids).unwrap();
    let contents: Vec<String> = items.iter().map(|i| i.text_content().to_string()).collect();

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

#[test]
fn scene2_search_cat_shows_cat_image() {
    let (store, _temp) = create_preview_video_store();

    let result = store.search("cat".to_string()).unwrap();
    assert!(!result.matches.is_empty(), "Should find matches for 'cat'");

    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_id).collect();
    let items = store.fetch_by_ids(ids).unwrap();
    let contents: Vec<String> = items.iter().map(|i| i.text_content().to_string()).collect();

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

#[test]
fn scene3_search_r_shows_return_and_riverside() {
    let (store, _temp) = create_preview_video_store();

    let result = store.search("r".to_string()).unwrap();

    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_id).collect();
    let items = store.fetch_by_ids(ids).unwrap();
    let contents: Vec<String> = items.iter().map(|i| i.text_content().to_string()).collect();

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

#[test]
fn scene3_search_riv_shows_riverside() {
    let (store, _temp) = create_preview_video_store();

    let result = store.search("riv".to_string()).unwrap();
    assert!(!result.matches.is_empty(), "Should find matches for 'riv'");

    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_id).collect();
    let items = store.fetch_by_ids(ids).unwrap();
    let contents: Vec<String> = items.iter().map(|i| i.text_content().to_string()).collect();

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

#[test]
fn scene3_search_rivresid_typo_finds_riverside() {
    let (store, _temp) = create_preview_video_store();

    // "rivresid" is a typo - missing space and 'e' from "Riverside"
    // Fuzzy matching should still find it
    let result = store.search("rivresid".to_string()).unwrap();

    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_id).collect();
    let items = store.fetch_by_ids(ids).unwrap();
    let contents: Vec<String> = items.iter().map(|i| i.text_content().to_string()).collect();

    // Fuzzy search should find the Riverside apartment notes
    // This demonstrates typo forgiveness
    assert!(
        contents.iter().any(|c| c.contains("Riverside")),
        "Fuzzy search should find 'Riverside' with typo 'rivresid'. Got: {:?}",
        contents
    );
}

// ============================================================
// Content Verification Tests
// ============================================================

#[test]
fn verify_all_expected_items_exist() {
    let (store, _temp) = create_preview_video_store();

    // Fetch all items
    let result = store.fetch_items(None, 100).unwrap();
    let contents: Vec<String> = result.items.iter().map(|i| i.text_content().to_string()).collect();

    // Verify key items from each scene exist

    // Scene 1: Meta Pitch
    assert!(
        contents.iter().any(|c| c.contains("Hello ClipKitty")),
        "Marketing blurb missing"
    );
    assert!(
        contents.iter().any(|c| c.contains("Hello and welcome")),
        "Onboarding doc missing"
    );
    assert!(
        contents.iter().any(|c| c.contains("hello_world.py")),
        "hello_world.py missing"
    );

    // Scene 2: Colors and Images
    assert!(
        contents.iter().any(|c| c == "#7C3AED"),
        "Purple hex color missing"
    );
    assert!(
        contents.iter().any(|c| c == "#FF5733"),
        "Orange hex color missing"
    );
    assert!(
        contents.iter().any(|c| c.contains("tabby cat")),
        "Cat image description missing"
    );

    // Scene 3: Typo Forgiveness
    assert!(
        contents.iter().any(|c| c.contains("Riverside Dr")),
        "Apartment notes missing"
    );
    assert!(
        contents.iter().any(|c| c.contains("driver_config")),
        "driver_config.yaml missing"
    );

    // Default state items
    assert!(
        contents.iter().any(|c| c.contains("SELECT users.name")),
        "SQL query missing"
    );
    assert!(
        contents.iter().any(|c| c.contains("sk-proj")),
        "API key missing"
    );
    assert!(
        contents.iter().any(|c| c.contains("quick brown fox")),
        "Pangram missing"
    );
}

#[test]
fn verify_item_count() {
    let (store, _temp) = create_preview_video_store();

    let result = store.fetch_items(None, 100).unwrap();

    // We should have approximately 39 items based on the data
    assert!(
        result.items.len() >= 35,
        "Should have at least 35 items, got {}",
        result.items.len()
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
        std::thread::sleep(std::time::Duration::from_millis(15));
    }

    (store, temp_dir)
}

/// Get search result contents in order
fn search_contents(store: &ClipboardStore, query: &str) -> Vec<String> {
    let result = store.search(query.to_string()).unwrap();
    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_id).collect();
    let items = store.fetch_by_ids(ids).unwrap();
    items.iter().map(|i| i.text_content().to_string()).collect()
}

#[test]
fn ranking_contiguous_beats_scattered() {
    // Items added oldest to newest
    // Using "help low" which scatters "hello" as hel-lo vs contiguous "hello"
    let (store, _temp) = create_ranking_test_store(vec![
        "help low cost items",   // "hel" + "lo" scattered, older
        "hello world greeting",  // contiguous "hello", newer
    ]);

    let contents = search_contents(&store, "hello");

    // Contiguous match should rank first (better match quality)
    assert!(!contents.is_empty(), "Should find at least one item");
    assert!(
        contents[0].contains("hello world"),
        "Contiguous 'hello world' should rank first, got: {:?}",
        contents
    );
}

#[test]
fn ranking_recency_breaks_ties_for_equal_matches() {
    // Items with identical match quality, different ages
    let (store, _temp) = create_ranking_test_store(vec![
        "hello world one",   // older
        "hello world two",   // middle
        "hello world three", // newest
    ]);

    let contents = search_contents(&store, "hello");

    // All are exact matches, so recency should order them (newest first)
    assert_eq!(contents.len(), 3, "Should find all 3 items");
    assert!(
        contents[0].contains("three"),
        "Newest should rank first, got: {:?}",
        contents
    );
    assert!(
        contents[1].contains("two"),
        "Middle should rank second, got: {:?}",
        contents
    );
    assert!(
        contents[2].contains("one"),
        "Oldest should rank third, got: {:?}",
        contents
    );
}

#[test]
fn ranking_word_start_beats_mid_word() {
    let (store, _temp) = create_ranking_test_store(vec![
        "the curl command line tool",  // url is mid-word in 'curl', older
        "urlParser.parse(input)",       // url is at word start, newer
    ]);

    let contents = search_contents(&store, "url");

    // Word-start match should rank higher (Nucleo prefers word boundaries)
    assert!(contents.len() >= 2, "Should find both items");
    assert!(
        contents[0].contains("urlParser"),
        "Word-start 'urlParser' should rank first, got: {:?}",
        contents
    );
}

#[test]
fn ranking_partial_match_excluded_when_atoms_missing() {
    // "hello cl" requires both "hello" and "cl" to match
    let (store, _temp) = create_ranking_test_store(vec![
        "hello_world.py",     // has "hello" but NO 'c' at all
        "Hello ClipKitty!",   // has both "hello" and "cl"
    ]);

    let contents = search_contents(&store, "hello cl");

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

#[test]
fn ranking_trailing_space_boosts_word_boundary() {
    // "hello " (with trailing space) should prefer content with "hello " (hello followed by space)
    let (store, _temp) = create_ranking_test_store(vec![
        "def hello(name: str)",        // "hello(" - no space after, older
        "Hello and welcome to...",     // "Hello " - has space after, newer
    ]);

    let contents = search_contents(&store, "hello ");

    // Content with "Hello " should rank higher due to trailing space boost
    assert!(contents.len() >= 2, "Should find both items");
    assert!(
        contents[0].contains("Hello and"),
        "Content with 'Hello ' should rank first, got: {:?}",
        contents
    );
}
