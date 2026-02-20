# How ClipKitty Ranking Works

ClipKitty uses **Milli-style bucket ranking** to order search results. Each candidate gets a `BucketScore` — a tuple of signals compared lexicographically. Higher-priority signals always dominate lower ones: 3/3 words matched ALWAYS beats 2/3, regardless of recency, typo count, or anything else.

This document walks through each signal, from most to least important.

## The BucketScore Tuple

```rust
pub struct BucketScore {
    pub words_matched_weight: u16, // 1. IDF-weighted word coverage
    pub recency_score: u8,         // 2. logarithmic time decay
    pub typo_score: u8,            // 3. 255 - total_edit_distance
    pub proximity_score: u16,      // 4. how close matched words are
    pub exactness_score: u8,       // 5. match quality (0-6)
    pub bm25_quantized: u16,       // 6. BM25 term-frequency signal
    pub recency: i64,              // 7. raw timestamp tiebreaker
}
```

Rust's derived `Ord` on this struct gives lexicographic comparison — field 1 dominates field 2, field 2 dominates field 3, and so on. All fields are oriented so that **higher = better**.

## 1. Words Matched Weight (most important)

Sum of `len²` for each matched query word. This is an IDF proxy — longer words are rarer and more informative, so matching them matters more.

```
Query: ["hello", "world"]     → weights: 5² + 5² = 50
Query: ["a", "magnificent"]   → weights: 1² + 11² = 122
```

Punctuation tokens (like `://`, `.`) get weight 0 — they participate in proximity and highlighting but don't inflate the match score.

Short fuzzy matches (≤3 chars) get reduced to weight 1 since they're low-confidence.

## 2. Recency Score

Logarithmic decay from 255 (just now) to 0 (~17 days old), quantized to `u8`.

```
score = 255 × (1 - ln(1 + 20·age_hours) / ln(1 + 20·400))
```

The log scale distributes resolution across human-meaningful time ranges:

| Age | Score |
|-----|-------|
| now | 255 |
| 5 min | ~227 |
| 30 min | ~187 |
| 1 hour | ~169 |
| 6 hours | ~119 |
| 24 hours | ~80 |
| 7 days | ~25 |
| 17 days | 0 |

This sits at priority #2, above typo/proximity/exactness. Effect: when two items match the same query words, the more recent one wins — even if the older one has fewer typos.

## 3. Typo Score

```
typo_score = 255 - sum(edit_distances of matched words)
```

Edit distance uses **Damerau-Levenshtein** (insertions, deletions, substitutions, adjacent transpositions each cost 1).

Fuzzy tolerance depends on word length:

| Word length | Max edit distance |
|-------------|------------------|
| 1-2 chars | 0 (exact only) |
| 3-8 chars | 1 |
| 9+ chars | 2 |

**First-character rule**: a mismatch on position 0 adds a +1 penalty. This prevents false positives like `"cat"→"bat"` (DL=1 + penalty=1 = 2, exceeds max). Exception: first-two-char transpositions (`"hte"→"the"`) are exempt since they're common fast-typing errors.

## 4. Proximity Score

Measures how close matched words appear to each other in the document.

```
proximity_score = u16::MAX - total_distance
```

For each consecutive pair of matched words:
- **Forward order** (word B appears after word A): distance = `pos_B - pos_A`
- **Reversed order** (word B appears before word A): distance = `pos_A - pos_B + 5` (inversion penalty)

```
Doc: "hello world"           query ["hello", "world"] → distance 1
Doc: "hello beautiful world" query ["hello", "world"] → distance 2
Doc: "world ... hello"       query ["hello", "world"] → distance + 5 penalty
```

Single-word queries always get `u16::MAX` (perfect proximity).

## 5. Exactness Score (0-6)

Measures how precisely the query matches the content. Evaluated top-down — first match wins.

| Level | Condition | Example |
|-------|-----------|--------|
| **6** | Query is a **prefix** of content | `"hello wo"` → `"hello world foo"` |
| **5** | First word anchored at doc start + all words in **forward sequence** | `"hello wrold"` → `"hello world foo"` |
| **4** | Full query is a **substring** anywhere | `"hello world"` → `"say hello world"` |
| **3** | All matched words are **exact** | `"hello" + "world"` in `"hello beautiful world"` (no anchoring) |
| **2** | All matched words are exact or **prefix** (0 edit distance) | Typing in progress: `"hel"` matching `"hello"` |
| **1** | Mix of exact/prefix and **fuzzy** | `"hello"` exact + `"wrld"` fuzzy |
| **0** | All matches are **fuzzy** only | `"hallo"` matching `"hello"` |

The implementation in `compute_exactness`:

```rust
fn compute_exactness(content_lower: &str, query_words: &[&str], word_matches: &[WordMatch]) -> u8 {
    // ...

    // Level 6: query is prefix of content
    if content_lower.starts_with(&full_query) {
        return 6;
    }

    // Level 5: first word anchored at doc start, all words in forward sequence
    if all_matched && word_matches.len() > 1 {
        let first = &word_matches[0];
        if first.doc_word_pos == 0 && first.edit_dist == 0 {
            let in_sequence = word_matches.windows(2)
                .all(|w| w[1].doc_word_pos > w[0].doc_word_pos);
            if in_sequence {
                return 5;
            }
        }
    }

    // Level 4: full query is substring anywhere
    if content_lower.contains(&full_query) {
        return 4;
    }

    // Levels 3-0: word-level match quality
    // ...
}
```

Levels 6 and 5 reward content that **starts with what you typed** — the most common intent in a clipboard manager. Level 5 is tolerant of typos and intervening words, as long as the first word is correct and the sequence is forward.

## 6. BM25 Quantized

Standard BM25 score from the Tantivy full-text index, scaled by 100× and stored as `u16`. This is a tiebreaker that prefers documents where query terms are statistically more significant (higher term frequency, lower document frequency).

It sits below all the other signals because BM25 alone can't distinguish the nuanced intent signals that the bucket fields above capture.

## 7. Raw Timestamp (final tiebreaker)

If everything else is identical, the most recently copied item wins. This is the unix timestamp of when the item was added to the clipboard.

## Word Matching Pipeline

Before scoring, each query word is matched against every document word. The match cascade tries each strategy in order and takes the first hit:

```
Exact  →  Prefix (last word only, ≥2 chars)  →  Fuzzy (edit distance)  →  Subsequence
```

```rust
pub fn does_word_match(qw_lower: &str, dw_lower: &str, allow_prefix: bool) -> WordMatchKind {
    if dw_lower == qw_lower                                    { return Exact; }
    if allow_prefix && qw_lower.len() >= 2
       && dw_lower.starts_with(qw_lower)                      { return Prefix; }
    if let Some(dist) = edit_distance_bounded(qw, dw, max)    { return Fuzzy(dist); }
    if let Some(gaps) = subsequence_match(qw, dw)             { return Subsequence(gaps); }
    None
}
```

**Subsequence matching** handles abbreviation-style queries like `"impt"→"import"`. Guards prevent false positives:
- Query must be ≥4 characters
- Must cover ≥50% of target length
- First character must match
- Returns a gap count (non-contiguous segments) that feeds into edit_dist

## Worked Example

Query: `"hello world"`
Two candidate items, both copied 1 hour ago with BM25 = 5.0:

| | Content A: `"hello world foo"` | Content B: `"say hello world"` |
|---|---|---|
| words_matched_weight | 50 (5² + 5²) | 50 (5² + 5²) |
| recency_score | 169 | 169 |
| typo_score | 255 (0 edits) | 255 (0 edits) |
| proximity_score | 65534 (distance 1) | 65534 (distance 1) |
| **exactness_score** | **6** (prefix of content) | **4** (substring, not prefix) |
| bm25_quantized | 500 | 500 |

**Content A wins** — it starts with the query, getting exactness 6 vs 4. The first four fields are tied, so exactness breaks it.

This is the core insight: the tuple structure means you only need to look at the first field that differs.
