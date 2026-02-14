# Search Performance Analysis

Deep investigation of the ClipKitty search pipeline, identifying bottlenecks and
optimization opportunities. All findings are against the 1M-item synthetic
benchmark database on an Apple Silicon Mac.

## Baseline Benchmarks

| Query Type | Query | Latency (ms) | Notes |
|------------|-------|-------------|-------|
| Short (2 char) | `"hi"` | **82 ms** | SQLite LIKE fallback, slowest |
| Medium word | `"hello"` | **22 ms** | Tantivy trigram path |
| Long word | `"riverside"` | **26 ms** | Tantivy trigram path |
| Multi-word | `"hello world"` | **24 ms** | Phrase boosts active |
| Fuzzy typo | `"riversde"` | **24 ms** | Edit distance matching |
| Trailing space | `"hello "` | **22 ms** | Disables prefix matching |
| Long query | `"error build failed due to dependency"` | **31 ms** | 6-word query, per-word trigrams |

**Key observation:** Short queries (< 3 chars) are 3-4x slower than trigram
queries because they bypass Tantivy and fall back to SQLite LIKE scans.

---

## Architecture Summary

```
Keystroke → store.rs search()
  ├─ Empty query → DB fetch_item_metadata (no search)
  ├─ Short query (< 3 chars) → SQLite LIKE → score_short_query_batch
  └─ Trigram query (≥ 3 chars):
       Phase 1: Tantivy trigram recall (BM25 + recency) → 2000 candidates
       Phase 2: Bucket re-ranking (compute_bucket_score × 2000) [SEQUENTIAL]
       Phase 3: Word-level highlighting (highlight_candidate × 2000) [PARALLEL]
       Phase 4: DB fetch by IDs (SELECT * with BLOBs) [SEQUENTIAL]
       Phase 5: Snippet generation (create_match_data × N) [PARALLEL]
```

---

## Bottleneck 1: Redundant Tokenization and Lowercasing (CRITICAL)

**Impact: ~30% of total search time. Estimated savings: 5-8 ms per query.**

Content is tokenized and lowercased **twice** per candidate — once during Phase 2
bucket scoring and again during Phase 3 highlighting:

### Phase 2 (ranking.rs:65-66)
```rust
let content_lower = content.to_lowercase();     // Allocation #1
let doc_words = tokenize_words(&content_lower);  // Allocation #2
```

### Phase 3 (search.rs:228, 235)
```rust
let content_lower = content.to_lowercase();     // Allocation #3 (DUPLICATE)
let doc_words = tokenize_words(&content_lower);  // Allocation #4 (DUPLICATE)
```

For 2000 candidates with average 300-byte content:
- **4000 unnecessary String allocations** (~1.2 MB)
- **4000 unnecessary tokenize_words calls** (~200 KB)
- **200,000 duplicate `does_word_match()` calls** (same Q×D comparisons)

### Fix

Compute tokenized/lowercased content once in Phase 2 and pass it through to
Phase 3. Options:
1. Return `(BucketScore, content_lower, doc_words)` from Phase 2
2. Create a `CandidateContext` struct shared between phases
3. At minimum, merge Phase 2 and Phase 3 into a single pass

---

## Bottleneck 2: Phase 2 Bucket Scoring Is Sequential (CRITICAL)

**Impact: ~15-25% of trigram query time. Estimated savings: 4-6x speedup on Phase 2.**

`indexer.rs:260-274` runs `compute_bucket_score` in a sequential `.map()`:

```rust
let mut scored: Vec<(BucketScore, usize)> = candidates
    .iter()                          // ← Sequential!
    .enumerate()
    .map(|(i, c)| {
        let bucket = compute_bucket_score(&c.content, ...);
        (bucket, i)
    })
    .collect();
```

`compute_bucket_score` is a pure function with no shared state — a perfect
candidate for `par_iter()`. Phase 3 highlighting already uses rayon parallelism,
so the infrastructure is in place.

### Fix

```rust
use rayon::prelude::*;
let mut scored: Vec<(BucketScore, usize)> = candidates
    .into_par_iter()                 // ← Parallel!
    .enumerate()
    .map(|(i, c)| { ... })
    .collect();
```

Expected Phase 2 speedup: 4-6x on 6+ core machines.

---

## Bottleneck 3: Content Fetched from Both Tantivy AND Database (HIGH)

**Impact: ~1 MB unnecessary I/O per search. Estimated savings: 2-4 ms.**

Content is stored and fetched from **two** sources redundantly:

1. **Tantivy stored fields** (indexer.rs:340): `searcher.doc(doc_address)` loads
   id + content + timestamp for all 2000 candidates
2. **SQLite database** (store.rs:150): `db.fetch_items_by_ids_interruptible()`
   does `SELECT *` on the same items, loading content again plus all BLOB columns

The content fetched from Tantivy is used for scoring and highlighting. The
database fetch is needed for metadata (source_app, icon, etc.) but loads
everything via `SELECT *` including `imageData`, `thumbnail`, and
`linkImageData` BLOBs.

### Triple storage of content per candidate

| Location | What's stored | When accessed |
|----------|--------------|---------------|
| Tantivy index (stored field) | Full content string | Phase 1 retrieval |
| `SearchCandidate.content` | Cloned from Tantivy | Phase 2 scoring |
| `FuzzyMatch.content` | Cloned again (search.rs:313) | Phase 5 snippet gen |
| SQLite `items.content` column | Full content + BLOBs | Phase 4 DB fetch |

### Fix

**Option A — Stop storing content in Tantivy:**
Remove `set_stored()` from the content field schema. Fetch content from the
database only once, before Phase 2. This eliminates ~1 MB of Tantivy stored
field I/O per search.

**Option B — Narrow the database SELECT:**
Replace `SELECT *` with `SELECT id, content, timestamp, sourceApp,
sourceAppBundleID, contentType, colorRgba` in `fetch_items_by_ids()` and
`fetch_items_by_ids_interruptible()`. This avoids loading BLOB columns (images,
thumbnails, link images) that search doesn't need.

**Option C (recommended) — Both A and B:**
Tantivy returns only IDs + scores. Database provides content (narrowed SELECT).
Content flows through scoring → highlighting → snippet generation without
redundant copies.

---

## Bottleneck 4: edit_distance_bounded Allocations (HIGH)

**Impact: 150,000 heap allocations per search. Estimated savings: 1-3 ms.**

`ranking.rs:377-379` allocates three `Vec<usize>` on every call:

```rust
let mut prev2 = vec![0usize; n + 1];
let mut prev: Vec<usize> = (0..=n).collect();
let mut curr = vec![0usize; n + 1];
```

Call frequency: `does_word_match()` is invoked ~200,000 times per search
(2000 candidates × 2 query words × 50 doc words). Of those, ~50,000 reach
`edit_distance_bounded`, creating **150,000 Vec allocations** (~4-13 MB of
temporary heap usage).

Additionally, both inputs are collected into `Vec<char>` (lines 367-368),
adding another **100,000 allocations**.

### Fix options

1. **Stack-based arrays:** Typical words are ≤16 chars. Use `[usize; 17]`
   arrays instead of Vec. Zero heap allocations for 95%+ of words.
2. **ASCII fast path:** For ASCII-only content (99% of clipboard data), operate
   on bytes directly (`a.as_bytes()`) instead of collecting `Vec<char>`.
3. **Thread-local reusable buffers:** Allocate once per rayon thread, reuse
   across all calls within a single search.

---

## Bottleneck 5: Short Query SQLite Fallback (HIGH)

**Impact: 82 ms for 2-char queries vs 22 ms for trigram queries.**

`database.rs:441-508` runs two separate SQL queries:

1. **Prefix scan** (full table): `WHERE content LIKE 'hi%'` — uses index
2. **Substring scan** (last 2000 items): `SELECT * FROM (SELECT * FROM items
   ORDER BY timestamp DESC LIMIT 2000) WHERE content LIKE '%hi%'`

Problems:
- Part 2 materializes 2000 rows with `SELECT *` including all BLOB columns
- The `%hi%` LIKE pattern cannot use any index (full scan of 2000 rows)
- Two separate round-trips to SQLite

### Fix options

1. **Narrow the SELECT:** Replace `SELECT *` with `SELECT id, content,
   CAST(strftime('%s', timestamp) AS INTEGER)` in the subquery
2. **Single query with UNION:** Combine prefix and substring into one query
3. **Consider a 2-char trigram index:** Tantivy uses 3-char ngrams. A separate
   bigram index or SQLite FTS5 could handle 1-2 char queries efficiently
4. **Increase cache_size:** Current `PRAGMA cache_size=-32000` (32 MB) may be
   undersized for materializing 2000 rows. Consider 64 MB.

---

## Bottleneck 6: Snippet Generation String Iteration (MEDIUM)

**Impact: ~2-4 ms for 2000 results.**

`generate_snippet()` (search.rs:374-461) iterates the content string 5+ times:

| Operation | Line | Iteration |
|-----------|------|-----------|
| `content.chars().count()` | 375 | Full string |
| `content.chars().take(match_start).filter()` | 388-392 | Up to match |
| `content.chars().skip(start).take(n)` | 406-410 | Partial |
| `search_range.chars().count()` | 413 | ~10 chars |
| `normalize_snippet_with_mapping()` | 425 | Full snippet |

For 2000 results × 5 iterations × 200 chars average = **2 million char decode
operations**.

Additionally, `find_densest_highlight` is called **twice** on the same data:
once inside `generate_snippet()` (line 383) and again in `create_match_data()`
(line 474).

### Fix

1. Precompute a char-boundary index once at function entry
2. Cache `find_densest_highlight` result — call once, pass through
3. Pass `content_char_len` as parameter (already computed in highlight_candidate)

---

## Bottleneck 7: `chars().count()` in does_word_match (MEDIUM)

**Impact: ~200,000 redundant UTF-8 scans per search.**

`ranking.rs:233`:
```rust
let max_typo = max_edit_distance(qw_lower.chars().count());
```

Called 200,000 times per search. Each `.chars().count()` scans the entire string
to count Unicode scalar values. For ASCII content (99% of clipboard data),
`str::len()` (byte length) gives the same result with zero iteration.

### Fix

```rust
let word_len = if qw_lower.is_ascii() { qw_lower.len() } else { qw_lower.chars().count() };
let max_typo = max_edit_distance(word_len);
```

Better yet, precompute `max_edit_distance` for each query word once at the start
of the search, not per-candidate.

---

## Bottleneck 8: Rayon Thread Pool Under-Utilization (LOW)

**Impact: ~15% of parallelism potential lost.**

`store.rs:44`:
```rust
let rayon_threads = num_threads.saturating_sub(2).max(1);
```

Reserves 2 cores for Tokio. But during search, Tokio threads are mostly idle
(waiting on `spawn_blocking`). On an 8-core machine, only 6 threads do parallel
scoring/highlighting work.

### Fix

Reserve 1 core instead of 2:
```rust
let rayon_threads = num_threads.saturating_sub(1).max(1);
```

---

## Bottleneck 9: Content Cloned into FuzzyMatch (MEDIUM)

**Impact: ~600 KB unnecessary allocations per search.**

`search.rs:313`:
```rust
FuzzyMatch {
    content: content.to_string(),  // Full content clone
    ...
}
```

Each of 2000 `FuzzyMatch` objects contains a full clone of the document content.
This content is only used later for snippet generation in `create_match_data()`.

### Fix

Use `Arc<str>` instead of `String` in `SearchCandidate` and `FuzzyMatch` to
share the same backing allocation without cloning. Alternative: generate
snippets during highlighting (Phase 3) instead of as a separate phase, avoiding
the need to carry content forward.

---

## Optimization Priority Matrix

| # | Bottleneck | Est. Savings | Effort | Risk |
|---|-----------|-------------|--------|------|
| 1 | Merge Phase 2 + 3 (eliminate redundant tokenization) | 5-8 ms | Medium | Low |
| 2 | Parallelize Phase 2 bucket scoring | 4-6x Phase 2 | **Trivial** | None |
| 3 | Narrow DB SELECT / stop storing content in Tantivy | 2-4 ms | Medium | Low |
| 4 | Stack-allocate edit distance arrays | 1-3 ms | Low | None |
| 5 | Narrow short-query SELECT * | 10-20 ms | **Trivial** | None |
| 6 | ASCII fast path for edit distance | 1-2 ms | Medium | None |
| 7 | Precompute chars().count() / max_edit_distance | 0.5-1 ms | **Trivial** | None |
| 8 | Cache find_densest_highlight result | 0.5 ms | **Trivial** | None |
| 9 | Use Arc\<str\> for content sharing | 0.3-0.5 ms | Low | None |
| 10 | Reduce rayon core reservation | ~15% Phase 2/3 | **Trivial** | None |

### Quick wins (< 30 min each, no API changes):
- **#2**: Add `.into_par_iter()` to Phase 2
- **#5**: Change `SELECT *` to named columns in short query subquery
- **#7**: Use `.len()` instead of `.chars().count()` for ASCII
- **#8**: Pass `find_densest_highlight` result instead of recomputing
- **#10**: Change `saturating_sub(2)` to `saturating_sub(1)`

### Medium effort (1-4 hours, internal refactor):
- **#1**: Restructure to share tokenized content between phases
- **#3**: Remove STORED from Tantivy content field, narrow DB SELECT
- **#4**: Replace Vec allocations with stack arrays in edit_distance_bounded
- **#6**: Add `is_ascii()` check and byte-level edit distance

### Architectural (multi-day, significant refactor):
- **#9**: Switch to Arc\<str\> for zero-copy content sharing
- Consider replacing short-query SQLite fallback with bigram index or FTS5

---

## Theoretical Speed Ceiling

If all optimizations were applied:

| Query Type | Current | Estimated | Improvement |
|------------|---------|-----------|-------------|
| Short 2-char | 82 ms | 40-50 ms | 1.6-2x |
| Medium word | 22 ms | 10-14 ms | 1.6-2.2x |
| Long word | 26 ms | 12-16 ms | 1.6-2.2x |
| Multi-word | 24 ms | 10-14 ms | 1.7-2.4x |
| Fuzzy typo | 24 ms | 11-15 ms | 1.6-2.2x |
| Long query | 31 ms | 14-18 ms | 1.7-2.2x |

The largest single gain comes from **merging Phases 2 and 3** (eliminating
redundant work) combined with **parallelizing Phase 2**. Together these could
cut 8-12 ms from trigram queries.

---

## Appendix A: Allocation Budget Per Search (2000 candidates)

| Phase | Allocations | Bytes | Dominant Source |
|-------|------------|-------|-----------------|
| Query construction | ~15 | 1.6 KB | Term objects |
| Tantivy retrieval | ~4,000 | 1.2-1.5 MB | Content string copies |
| Bucket scoring (×2000) | ~14,000 | 3.2-3.8 MB | to_lowercase + tokenize |
| Highlighting (×2000) | ~16,000 | 4.4-5.2 MB | to_lowercase + tokenize (dup) |
| Result assembly | ~3,000 | 1.5-2 MB | HashMap + snippet gen |
| **Total** | **~37,000** | **~10-13 MB** | |

With optimizations #1 and #4: **~20,000 allocations, ~6-8 MB** (40% reduction).

## Appendix B: Data Flow Diagram

```
                    Tantivy Index                    SQLite Database
                    ┌────────────┐                   ┌──────────────┐
                    │ id (STORED)│                   │ id           │
                    │ content    │◄── REDUNDANT ──►  │ content      │
                    │ (STORED)   │                   │ imageData    │
                    │ timestamp  │                   │ thumbnail    │
                    │ (STORED+   │                   │ linkImageData│
                    │  FAST)     │                   │ ...          │
                    └─────┬──────┘                   └──────┬───────┘
                          │                                 │
           Phase 1: trigram_recall()              Phase 4: fetch_items_by_ids()
           Fetches content from Tantivy           Fetches content AGAIN + BLOBs
                          │                                 │
                          ▼                                 ▼
                 SearchCandidate {                  StoredItem {
                   content: String  ◄─ CLONE #1      content: ClipboardContent
                 }                                   thumbnail: Vec<u8>  ← WASTE
                          │                          imageData: Vec<u8>  ← WASTE
           Phase 2: compute_bucket_score()         }
           to_lowercase() ← ALLOC #1                       │
           tokenize_words() ← ALLOC #2                     ▼
                          │                        Phase 5: create_item_match()
           Phase 3: highlight_candidate()          Uses StoredItem.to_metadata()
           to_lowercase() ← ALLOC #3 (DUP!)       Uses FuzzyMatch for snippets
           tokenize_words() ← ALLOC #4 (DUP!)
           content.to_string() ← CLONE #2
                          │
                          ▼
                    FuzzyMatch {
                      content: String  ◄─ CLONE #2
                    }
```
