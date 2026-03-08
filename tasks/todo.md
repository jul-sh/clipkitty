# UI Test Database Seeding Fix

## Root Cause

UI tests reported 0 items (`testDatabaseNotEmpty` failed) because `distribution/SyntheticData.sqlite` was a **Git LFS pointer** (132-byte ASCII text) instead of the actual 3.7MB SQLite database. `git lfs pull` had not been run on this checkout.

The test copied this pointer file as the database. Rust's SQLite opened it as a corrupt/empty database — 0 items. No error was surfaced because the test had no validation of the source file.

## Fixes Applied

1. **LFS validation in `setupTestDatabase`**: Checks file size and content to detect LFS pointers. Fails with descriptive message: "Run `git lfs pull` first."
2. **Post-copy size validation**: Asserts the copied database exceeds 1KB.
3. **Makefile `uitest` target**: Runs `git lfs pull` before launching tests.

## Files Changed
- `Tests/UITests/ClipKittyUITests.swift` — LFS guard, post-copy size assertion
- `Makefile` — `git lfs pull` in `uitest` target

---

# TextPreviewView: Migrate to TextKit 2 + STTextKitPlus

## Summary
Migrated `TextPreviewView` from TextKit 1 to TextKit 2 with rendering attributes. Highlights are now applied via `NSTextLayoutManager.setRenderingAttributes(_:for:)` instead of mutating `NSTextContentStorage`, with efficient diff-based invalidation and scroll-to-match using STTextKitPlus.

## What Changed

### TextPreviewView (ContentView.swift)
- **TextKit 2 initialization**: `NSTextView(frame:textContainer:)` — never accesses `.layoutManager` (avoids TextKit 1 downgrade)
- **Rendering attributes**: Highlights applied via `tlm.setRenderingAttributes()` not storage mutations
- **Diff-based invalidation**: On highlight changes, only invalidates removed/added ranges (not full document)
- **Scroll via STTextKitPlus**: Uses `tlm.textSegmentFrame(in:type:.highlight)` for scroll target rect
- **Document height via TextKit 2**: Uses `enumerateTextLayoutFragments` instead of `layoutManager?.usedRect`
- **MatchRange type**: Carries resolved `NSTextRange` + original scalar indices for efficient hashing

### HighlightStyler
- Added `renderingAttributes(for:)` — semantic wrapper around `attributes(for:)` for TextKit 2 usage
- Removed `applyHighlights(_:to:text:)` — no longer needed (was storage-level mutation)

### Dependencies
- Added `STTextKitPlus` 0.3.0 (krzyzanowskim) — TextKit 2 helpers, specifically `textSegmentFrame(in:type:)`
- `Tuist/Package.swift` — added package dependency
- `Project.swift` — added `.external(name: "STTextKitPlus")` to ClipKitty target

## Architecture

```
Rust (HighlightRange: scalar indices)
  → nsRange(in:) → NSRange (UTF-16)
  → tcm.location(offsetBy:) → NSTextRange (TextKit 2)
  → tlm.setRenderingAttributes() (visual only, no storage mutation)
  → tlm.textSegmentFrame() (scroll target via STTextKitPlus)
```

## What NOT to do
- Never call `.layoutManager` on the NSTextView — silently downgrades to TextKit 1
- Never apply highlights via `NSTextContentStorage.performEditingTransaction` — triggers undo, is slower
- Never call `ensureLayout(for:)` on the full document range — only the target match range

## Tests Passing
- `testNsRangeAsciiText` ✅
- `testNsRangeAtBeginning` ✅
- `testNsRangeInvalidRange` ✅
- `testNsRangeOfEmoji` ✅
- `testNsRangeWithEmoji` ✅
- `testNsRangeWithMultipleEmojis` ✅
- `testNsRangeWithNFDCombiningCharacters` ✅
- `testSearchHighlightsDoNotDrift` ✅
- `testSearchHighlightsWithEmojiContent` ✅

## Files Changed
1. `Sources/App/ContentView.swift` — TextPreviewView rewritten for TextKit 2
2. `Sources/App/Highlighting/HighlightStyler.swift` — Added renderingAttributes, removed applyHighlights
3. `Tuist/Package.swift` — Added STTextKitPlus dependency
4. `Project.swift` — Added STTextKitPlus to ClipKitty target
