# Ranking V2 Implementation Plan

## Summary

Reorder the `BucketScore` tuple so structural intent dominates recency, add a
document-density signal, value punctuation, and introduce acronym matching.

### New Tuple (8 fields → 8 fields)

```
OLD:  Weight → Recency → Typo → Proximity → Exactness → BM25 → Timestamp
NEW:  Weight → Intent  → Density → Recency → Proximity → Typo → BM25 → Timestamp
```

```rust
pub struct BucketScore {
    pub words_matched_weight: u16, // 1. MODIFIED: punctuation weight + 0.5x fuzzy penalty
    pub intent_tier: u8,           // 2. NEW: coarsened from exactness (4 tiers)
    pub density_score: u8,         // 3. NEW: matched-chars / doc-length
    pub recency_score: u8,         // 4. DEMOTED from #2
    pub proximity_score: u16,      // 5. PROMOTED from #4 (now above typo)
    pub typo_score: u8,            // 6. DEMOTED from #3
    pub bm25_quantized: u16,       // 7. UNCHANGED
    pub recency: i64,              // 8. UNCHANGED: raw timestamp tiebreaker
}
```

The old `exactness_score` field is **deleted**, not kept as a secondary tiebreaker.
`intent_tier` fully replaces it at a higher position.

---

## Step 1: Tuple Reorder (intent above recency, proximity above typo)

**What changes:** Reorder the struct fields so `derive(Ord)` gives the new
lexicographic comparison. Delete `exactness_score`, add `intent_tier` in its
place.

**`intent_tier` definition** — evaluated top-down, first match wins:

| Tier | Condition | Maps from |
|------|-----------|-----------|
| **4** | Content starts with query (prefix), OR first word anchored + forward sequence | Old exactness 6, 5 |
| **3** | Full query is contiguous substring anywhere, OR acronym match (Step 5) | Old exactness 4, acronym |
| **2** | All words in forward order, each with edit distance ≤ 1 | Old exactness 3, 2 + minor fuzzy |
| **1** | Everything else (reversed, heavy fuzzy, scattered) | Old exactness 1, 0 |

No single-word exception. The tier cascade handles single words naturally:
- `password` matching doc `password` → Tier 4 (prefix of content)
- `password` as substring in long doc → Tier 3
- `pasword` (1 edit) matching `password` in forward position → Tier 2
- `passwrod` (2 edits) or reversed matches → Tier 1

**Implementation:**
1. Rename `compute_exactness` → `compute_intent_tier` with the 4-tier logic.
2. Change struct field from `exactness_score: u8` to `intent_tier: u8`.
3. Move the field from position #5 to position #2.
4. Swap `proximity_score` and `typo_score` field order.

**Tests fixed:** Cases 1, 4, 5, 7, 8, 12, 14.

**Existing tests to update:**
- `test_recency_dominates_typo` — recency still dominates typo (now #4 vs #6). Passes.
- `test_recency_dominates_proximity` — recency still above proximity (#4 vs #5). Passes.
- `test_typo_dominates_within_same_recency` — typo is now #6, proximity is #5.
  Both items have same proximity (single word = MAX), so typo still breaks tie. Passes.
- All `test_exactness_*` tests — rewrite for `compute_intent_tier` returning 1-4.
- `test_full_bucket_score_integration` — update field names and expected values.

---

## Step 2: Document Density Score

**Problem the proposal missed:** When two items have the same `intent_tier`
(e.g., both Tier 3 substring matches), the denser document should win. A
clipboard item that IS the thing (short) is more relevant than a document that
merely MENTIONS the thing (long). BM25 captures this, but at position #7 it
never decides anything.

**Solution:** A dedicated `density_score: u8` at position #3 (between
`intent_tier` and `recency_score`).

```rust
fn compute_density_score(
    matched_word_lengths: &[usize], // char lengths of matched query words
    doc_char_len: usize,
) -> u8 {
    if doc_char_len == 0 {
        return 255;
    }
    let matched_chars: usize = matched_word_lengths.iter().sum();
    let ratio = matched_chars as f64 / doc_char_len as f64;
    (ratio * 255.0).round().clamp(0.0, 255.0) as u8
}
```

Examples:
- `password` (8 chars) matching `password` (8 chars) → ratio 1.0 → **255**
- `password` matching `my password` (11 chars) → ratio 0.73 → **186**
- `password` matching a 500-char doc → ratio 0.016 → **4**

**Why continuous, not bucketed:** Buckets add design decisions (where are the
boundaries?) and lose information. A continuous u8 provides 256 levels of
resolution. The position in the tuple already limits its power — it only matters
when intent_tier is tied. Within that constraint, more resolution is better.

**Implementation:**
1. Add `density_score: u8` to `BucketScore` between `intent_tier` and
   `recency_score`.
2. In `compute_bucket_score`, collect char-lengths of matched query words,
   pass them with `content_lower.chars().count()` to `compute_density_score`.
3. Add unit tests for density calculation.

**Tests fixed:** Case 13.

---

## Step 3: Punctuation Weight

**Problem:** Punctuation tokens (`.`, `/`, `-`) currently get `match_weight: 0`.
When the user types `192.168.1.1`, the dots carry no weight — so `192.168.1.1`
and `192 168 1 1` tie on `words_matched_weight`.

**Fix:** Give punctuation tokens their `len²` weight (usually 1) when the query
explicitly contains them. The tokenizer already emits them as separate tokens;
they just need non-zero weight.

**Implementation:**
In `match_query_words`, change:
```rust
// Before:
let match_weight = if is_word_token(qw) { (qw.len() as u16).pow(2) } else { 0 };

// After:
let match_weight = (qw.len() as u16).saturating_mul(qw.len() as u16);
```

Remove the `is_word_token` gate entirely. Punctuation tokens are short (weight
1-4), so they won't dominate scoring. But they WILL differentiate `192.168.1.1`
(matches all 7 tokens, weight 20+3=23) from `192 168 1 1` (matches 4 numeric
tokens, weight 20, dots unmatched).

**Tests fixed:** Case 9.

---

## Step 4: 0.5× Fuzzy Weight Penalty

**Problem:** A fuzzy match of a short query word (≤3 chars) currently gets
weight 1 regardless of length. This is too blunt — a 3-char word gets weight 1,
but a 4-char word gets full weight (16). The cliff at 3→4 chars is arbitrary.

**Fix:** Replace the `≤3 → weight 1` rule with a universal `0.5×` penalty for
fuzzy and subsequence matches:

```rust
// Before:
let w = if qw.len() <= 3 { 1 } else { match_weight };

// After:
let w = match_weight / 2;
```

This applies equally to all word lengths. An exact match of `api` (3 chars) gets
weight 9. A fuzzy match of `api` gets weight 4. The exact match always wins on
weight alone, protecting against false positives.

**Guard retained:** The `max_edit_distance` graduation (0 edits for 1-2 chars,
1 for 3-8, 2 for 9+) and the first-character penalty remain unchanged. These are
the real false-positive guards. The weight penalty is a secondary signal, not the
primary defense.

**Implementation:**
1. In `match_query_words`, replace the `if qw.len() <= 3 { 1 }` branches in
   both `Fuzzy` and `Subsequence` arms with `match_weight / 2`.

**Tests fixed:** Contributes to Case 11 (forward-order typo match gets proper
weight).

---

## Step 5: Acronym Matching

**Problem:** `lgtm` has no way to match `looks good to me`. The subsequence
matcher checks within a single word, not across word boundaries.

**Solution:** Add `WordMatchKind::Acronym` that matches a query word against the
first characters of N consecutive document words.

### Match Logic

```rust
fn try_acronym_match(qw: &str, doc_words: &[&str], start: usize) -> Option<usize> {
    let q_chars: Vec<char> = qw.chars().collect();
    if q_chars.len() < 3 { return None; } // min 3 chars to avoid noise
    if start + q_chars.len() > doc_words.len() { return None; }

    for (i, &qc) in q_chars.iter().enumerate() {
        let dw = doc_words[start + i];
        if !dw.starts_with(qc) { return None; }
    }
    Some(q_chars.len()) // number of doc words consumed
}
```

**Guards against false positives:**
- Minimum query length: 3 characters (prevents `ab` → `Any Body`).
- Each query character must match the **first character** of a consecutive
  document word. No gaps allowed.
- Only alphanumeric document words count (skip punctuation tokens).

### Integration with `match_query_words`

Acronym matching is fundamentally different from the other match kinds: one query
word matches N document words. The current pipeline is 1:1 (one query word → one
doc word). Acronym breaks this assumption.

**Approach:** Check for acronym match BEFORE the per-doc-word loop. If the query
word matches as an acronym starting at some position, return immediately with:
- `matched: true`
- `edit_dist: 0`
- `doc_word_pos`: position of the first doc word in the acronym span
- `is_exact: false` (not a literal match)
- `match_weight`: full `len²` (acronyms are high-intent, like exact matches)

Add `Acronym` variant to `WordMatchKind` for highlighting/display purposes, but
for scoring, treat it like an exact match (0 edit distance, full weight).

### Intent Tier

Acronym matches get **Tier 3** (same as contiguous substring). They represent
strong structural intent — the user typed an abbreviation of a known phrase.

**Implementation:**
1. Add `Acronym` to `WordMatchKind` enum.
2. Add `try_acronym_match` function.
3. In `match_query_words`, before the per-doc-word loop, try acronym matching
   at each starting position. Take the first hit.
4. In `compute_intent_tier`, check for acronym matches when evaluating Tier 3.

**Tests fixed:** Case 15.

---

## Step 6: Update Existing Tests

Several existing tests assert the current tuple ordering. These need updating:

1. **`test_exactness_*`** (7 tests) — Rewrite for `compute_intent_tier` returning
   1-4 instead of `compute_exactness` returning 0-6.
2. **`test_full_bucket_score_integration`** — Update field names (`intent_tier`,
   `density_score`) and expected values.
3. **`test_proximity_inversion_penalty`** — Still valid, no changes.
4. **`test_recency_dominates_*`** and **`test_typo_dominates_*`** — Verify they
   still hold under new ordering. Most should pass since the tests compare items
   with equal values in the higher-priority fields.

---

## Step 7: Remove `#[ignore]` from V2 Tests

Un-ignore all 11 `test_v2_*` tests. Verify all pass. Run the full test suite to
confirm no regressions.

---

## Implementation Order

| Step | What | Scope | Tests Fixed |
|------|------|-------|-------------|
| 1 | Tuple reorder + `intent_tier` | `BucketScore` struct, `compute_intent_tier` | 1,4,5,7,8,12,14 |
| 2 | Density score | New `compute_density_score`, struct field | 13 |
| 3 | Punctuation weight | One line in `match_query_words` | 9 |
| 4 | 0.5× fuzzy penalty | Two lines in `match_query_words` | 11 |
| 5 | Acronym matching | New `try_acronym_match`, `WordMatchKind::Acronym` | 15 |
| 6 | Update existing tests | Test module | — |
| 7 | Un-ignore v2 tests | Test module | — |

Steps 1-4 are pure refactors of existing logic. Step 5 adds new matching
capability. Each step is independently committable and testable.
