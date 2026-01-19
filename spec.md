This is a clipboard manager with search functionality, implementation detailed below.

### The Specifications

*   **Scale:** 1,000,000+ items (SQLite database).
*   **Performance Target:** < 80ms execution time.
*   **Quality:**
    1.  **Exact Matches:** Must appear at the very top.
    2.  **Fuzzy Matches:** Must handle typos (e.g., "aple" -> "apple") and partial words.
*   **UI/UX:** SwiftUI based, requiring smooth infinite scrolling without "jumping" results.

---

### The Strategy: "The ID Map & Hydration" Pattern

To meet the <80ms target on 1 million rows while solving the ranking paradox, we moved the heavy lifting from Swift (Application Layer) to SQLite (Data Layer) and decoupled **Searching** from **Loading**.

#### 1. The Engine: Native Trigrams (C-Level Speed)
Instead of using slow, memory-intensive Swift libraries like `Fuse` for fuzzy matching, we utilize SQLite's **FTS5 Trigram Tokenizer**.
*   **How it works:** It breaks text into 3-letter chunks (`clipboard` -> `cli`, `lip`, `ipb`...).
*   **Why:** It allows the database to find "clpboard" (missing 'i') instantly using mathematical set overlaps, without scanning every single row text.
*   **Performance:** Queries run in **< 5ms** even on large datasets because it uses an inverted index.

#### 2. The Ranking: Two-Tier Sorting
We ensure exact matches appear first using SQLite's built-in BM25 ranking algorithm.
*   **Tier 1:** The engine automatically scores documents. A document containing the exact word "Apple" gets a higher score than a document containing "ApplePie" or "Aple".
*   **Tier 2:** We sort by this score (`ORDER BY rank`). This guarantees that the user sees the most relevant item first, regardless of whether it was copied 5 minutes ago or 5 years ago.

#### 3. The Architecture: "Map first, Hydrate later"
This is the secret sauce for handling 1 million items without crashing memory (OOM).

*   **Phase A: The Map (Search)**
    When the user types, we fetch **only the IDs** (`Int64`) of the top 2,000 matches.
    *   *Payload:* ~16KB of RAM (tiny).
    *   *Speed:* Instant.
    *   *Result:* We now have a fixed "Map" of the entire result set in memory: `[BestID, SecondBestID, ..., WorstID]`.

*   **Phase B: Hydration (Pagination)**
    We calculate which IDs correspond to the user's viewport (e.g., the first 20). We query the database for the heavy content (text, images) **only for those 20 items**.
    *   *Payload:* Only what is visible on screen.

*   **Phase C: Infinite Scroll**
    When the user scrolls, we do **not** run the search again. We simply look at our "Map" (the array of IDs), pick the next 20 integers, and fetch their content. This ensures perfectly smooth scrolling with zero CPU spikes.

### Why this wins
1.  **Solves the "Old Item" Problem:** Time-based pagination hides relevant old items. This strategy retrieves the most relevant item instantly, even if it's #1,000,000 in the database.
2.  **Zero Battery Drain:** No Swift-based Levenshtein loops iterating over strings.
3.  **Crash Proof:** It never loads more data into RAM than what fits on the screen.




Your goal:


Migrate the business logic of this clipboard manager fully into rust. Swift shall only be used a thin UI layer. The goal is to reduce the scope of swift as much as possible while avoiding code bloat. Fully migrate the app, and ensure with tests that it is functionally equivalent and as fast or faster.