//! Tests that verify the synthetic database yields correct search results
//! for each frame of the App Store preview video.
//!
//! Script timing:
//! - Scene 1 (0:00-0:08): Meta pitch - fuzzy search refinement "hello" -> "hello clip"
//! - Scene 2 (0:08-0:14): Color swatches "#" -> "#f", then image "cat"
//! - Scene 3 (0:14-0:20): Typo forgiveness "rivresid" finds "Riverside"

use purr::{ClipboardStore, ClipboardStoreApi, ClipboardItem};
use tempfile::TempDir;

fn get_content_text(item: &ClipboardItem) -> String {
    item.content.text_content().to_string()
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
        std::thread::sleep(std::time::Duration::from_millis(1100));
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
    // This test verifies that timestamp is used as a tiebreaker for equal scores.
    // We use content that produces equal quantized Tantivy scores: "hello world one/two/three".
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
        .save_text("hello world end".to_string(), Some("Test".to_string()), Some("com.test".to_string()))
        .unwrap();

    // Verify all 3 were inserted (not deduplicated)
    assert!(id1 > 0 && id2 > 0 && id3 > 0, "All items should be inserted");

    // Search for "hello " - all 3 have equal quantized Tantivy scores
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

    // With equal quantized scores and the timestamp tiebreaker,
    // newest (item 3) should be first, oldest (item 1) should be last
    assert!(
        contents[0].contains("end"),
        "Newest (end) should rank first, got: {:?}",
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

    // "url" exact/prefix-matches "urlParser", and fuzzy-matches "curl" (edit distance 1).
    // urlParser should rank first (exact > fuzzy).
    assert!(!contents.is_empty(), "Should find urlParser");
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
        "def hello old text",          // older
        "the hello new text",          // newer
    ]);

    let contents = search_contents(&store, "hello ").await;

    // With equal scores, newer item should rank first via recency tiebreaker
    assert!(contents.len() >= 2, "Should find both items");
    assert!(
        contents[0].contains("hello new"),
        "Newer content should rank first, got: {:?}",
        contents
    );
}

#[tokio::test]
async fn ranking_repeated_word_should_not_boost() {
    // When a query word appears only once in the query, repeated
    // occurrences in a document should NOT inflate its score.
    //
    // Reproduces the exact user scenario:
    //   "hello world"            — 1 week old
    //   "hello world says hello" — 2 weeks old (older, but "hello" appears twice)
    //
    // Without the fix, the older item can outrank the newer one because
    // the repeated "hello" inflates BM25 term-frequency and coverage boost.
    let (store, _temp) = create_ranking_test_store(vec![
        "hello world says hello",  // older, "hello" appears twice
        "hello world",             // newer, "hello" appears once
    ]);

    let contents = search_contents(&store, "hello").await;

    assert!(contents.len() >= 2, "Should find both items, got: {:?}", contents);

    // The newer item ("hello world") should rank first because
    // recency should break the tie — repeated "hello" in the older
    // item must NOT give it a ranking advantage.
    assert!(
        contents[0].contains("hello world") && !contents[0].contains("says"),
        "Newer 'hello world' should rank first (recency tiebreak), \
         but got: {:?}",
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
    // Without strict min-match thresholds, common English trigrams can
    // cause false matches. The query "hello how are you doing today y"
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
    // Tantivy's min-match threshold (4/5 for 20+ trigrams) filters out
    // documents that only match via scattered common-word trigram overlaps.
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

// ============================================================
// Debug Test: Paste problematic query and content here
// ============================================================

#[tokio::test]
async fn debug_scattered_match_issue() {
    // PASTE YOUR QUERY HERE:
    let query = "vishalkaran";

    // PASTE THE PROBLEMATIC CONTENT HERE:
    let content = r#"================================================================================
ATTACK RESULTS SUMMARY
================================================================================

Experiment: seo_injection.evergreen.elite_island_genetic_algo.seo_v1.seo_critic_v1.default
--------------------------------------------------------------------------------
  Total Tasks: 30
  Num unfinished tasks: 0
  LLM Successful Attacks (fitness ≥ 10.0): 21
  LLM Attack Success Rate: 70.0%
  Regex Verified Attacks: 26
  Regex Verification Rate: 86.7%
  Mean Fitness Score: 8.53

  LLM Successful Attacks (fitness ≥ 10.0):
    Queries - Median: 26, Mean: 29.8
    Steps - Median: 1, Mean: 1.2

  Regex Verified Attacks:
    Queries - Median: 26, Mean: 31.5
    Steps - Median: 1, Mean: 1.3

  Fitness Score Distribution:
    10.0:  21 ( 70.0%)
     9.0:   2 (  6.7%)
     8.0:   1 (  3.3%)
     7.0:   2 (  6.7%)
     3.0:   1 (  3.3%)
     1.0:   3 ( 10.0%)

================================================================================
OVERALL SUMMARY
================================================================================
Total Scenarios Tested: 30

LLM Successful Attacks (fitness ≥ 10.0): 21
LLM Attack Success Rate: 70.0%

Regex Verified Attacks: 26
Regex Verification Rate: 86.7%

LLM Successful Attacks:
  Queries - Median: 26, Mean: 29.8
  Steps - Median: 1, Mean: 1.2

Regex Verified Attacks:
  Queries - Median: 26, Mean: 31.5
  Steps - Median: 1, Mean: 1.3

================================================================================
  -> Job completed with result: 0

All jobs have completed.

All tasks completed successfully!

================================================================================
Running analysis on completed jobs...
================================================================================

[0;32m✓ Evaluation completed![0m

[1;33m[Step 5/5][0m Cleaning up...
[0;32m╔══════════════════════════════════════════════════════════╗[0m
[0;32m║  All done! Check gateway_run.log for results            ║[0m
[0;32m╚══════════════════════════════════════════════════════════╝[0m

[1;33mShutting down gateway (PID: 467774)...[0m
[0;32m✓ Gateway shut down[0m
tee: gateway_42235.log: Transport endpoint is not connected
"#;

    let (store, _temp) = create_ranking_test_store(vec![content]);

    let result = store.search(query.to_string()).await.unwrap();
    let ids: Vec<i64> = result.matches.iter().map(|m| m.item_metadata.item_id).collect();
    let items = store.fetch_by_ids(ids).unwrap();
    let contents: Vec<String> = items.iter().map(|i| get_content_text(i)).collect();

    println!("\n=== DEBUG: Scattered Match Analysis ===");
    println!("Query: '{}'", query);
    println!("Content length: {} chars", content.len());
    println!("Number of results: {}", contents.len());

    if contents.is_empty() {
        println!("✓ GOOD: No match found (as expected for scattered content)");
    } else {
        println!("✗ BAD: Found {} matches when none expected!", contents.len());
        for (i, c) in contents.iter().enumerate() {
            let preview: String = c.chars().take(80).collect();
            println!("  Result {}: {}...", i, preview.replace('\n', " "));
        }
    }

    // This assertion will fail if the content incorrectly matches
    // Comment out if you just want to see the debug output
    assert!(
        contents.is_empty(),
        "Scattered content should NOT match query '{}'. Got {} results.",
        query,
        contents.len()
    );
}
