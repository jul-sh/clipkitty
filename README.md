# ClipKitty

<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/icon.png" alt="ClipKitty icon" width="60">

**Never lose what you copied.**

Unlimited history • Instant fuzzy search • Live preview • iCloud Sync • Secure & Attested

<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/marketing_1.png" alt="ClipKitty clipboard history" width="820">

## Why ClipKitty

Most clipboard managers feel fine at first.

Then you need something from last week, last month, or longer ago; and it is gone, hard to find, or cut off.

ClipKitty keeps your all clipboard history available and makes it easy to search, preview, and paste.

## Features

- **Unlimited history**; no small item cap and no short expiration window
- **Fast, forgiving search**; find what you're looking for, even if you only remember parts, or mispell words
- **Full previews**; see complete text, code, images, and colors before you paste
- **Works with more than text**; including images, files, links, and color values
- **Optional iCloud Sync**; keep your history across devices when you want it
- **Private by default**; on-device, no telemetry, no accounts
- **Open source and attested**; you can verify the app was built from the public source

## Installation

### Quick Install 

<a href="https://apps.apple.com/us/app/clipkitty-clipboard-manager/id6759137247?mt=12"><img src="https://github.com/jul-sh/clipkitty/raw/main/distribution/MacAppStore.png" alt="Download on the Mac App Store" width="200"></a>

### Manual Download

1. Download the latest DMG from [GitHub Releases](https://github.com/jul-sh/clipkitty/releases).
2. Drag ClipKitty to your Applications folder.

## Getting started

- Press **⌥Space** to open ClipKitty
- Type to search your clipboard history
- Use **↑ / ↓** to choose an item
- Press **Return** to paste

## Privacy

Your clipboard history contains sensitive information. ClipKitty keeps that history on-device by default.

There are no accounts, no telemetry, and no third-party servers.

If you enable iCloud Sync, your data stays in your private iCloud container.

### Verify the build

ClipKitty publishes attested builds. See [VERIFY.md](VERIFY.md).

## Alternatives

| | ClipKitty |
|---|---|
| **vs Maccy** | Same simplicity, no limits. Maccy caps at 200 items and makes you wait on tooltips to view your history. ClipKitty scales to millions, comes with instant live preview, and syncs securely via iCloud. |
| **vs Raycast** | Same speed, better search, no expiration. Raycast doesn't save long clips and offers limited search only. Its free tier expires after 3 months; sync requires a paid subscription. ClipKitty preserves everything forever, syncs via iCloud for free, and finds items more reliably with smarter, typo tolerant search. |
| **vs Paste** | Same utility, no subscription. Paste charges $30/year. You own ClipKitty outright. Plus ClipKitty ships with an intuitive list with instant live preview, vs paste's horizontal carousel. |

# Behind the Scenes

### How Search Works

ClipKitty's search system has a few hard requirements:

- it has to search as the user types, so every keystroke is on the hot path
- it has to stay fast on large histories, not just toy databases
- it has to keep full long documents searchable, not silently truncate them away
- it has to handle fuzzy matching and typo tolerance, because exact-match search is too brittle for clipboard recall
- it has to return one clipboard item per result, even if the internal search representation is more granular
- it has to show useful snippets, previews, and highlights, not just IDs and scores

Those requirements pull against each other. The naive approach is: every time the user types, scan every clipboard item, compute a fuzzy score against the full text, and sort the results. That works for 100 items. It stops working with thousands of items, and it really stops working when some items are hundreds of kilobytes or megabytes long.

ClipKitty solves that by splitting search into cheap recall and expensive judgment:

1. **Store everything in full.**
   The source of truth lives in SQLite. Nothing is truncated out of storage. If you copied a huge log, code file, or stack trace, the whole thing is still there.
2. **Index searchable units, not just rows.**
   Small items are indexed as one unit. Large items are indexed as overlapping chunks. This matters because relevance is usually local. If one 16 KB region is a great match, we want to reason about that region, not pay to analyze the entire 1 MB document on every query.
3. **Use Tantivy for fast broad recall.**
   For normal queries, Tantivy indexes trigrams and word positions. That gives a cheap first pass that is typo-tolerant and can still reward phrase-like matches. For very short queries, ClipKitty uses a simpler prefix/contains path because trigrams are not a good fit below 3 characters.
4. **Collapse chunks back to one parent item immediately.**
   Large items are chunked internally, but the product is still item-based. During Phase 1 collection, ClipKitty keeps only the best hit per parent item. If 20 chunks from one giant document match, that still becomes one candidate, not 20.
5. **Make large documents earn their way in.**
   A huge document almost always contains common words like `the`, `error`, or `function`. Without adjustment, those documents float upward on weak evidence and flood the expensive path. Phase 1 therefore blends Tantivy relevance with an evidence-density score, recency, and a size-aware BM25 penalty for weak large-document matches. Strong local evidence such as word proximity still wins. Weak “it matched somewhere in one of many chunks” evidence does not.
6. **Only rerank the head.**
   Phase 2 is the high-quality, expensive reranker. It does more detailed matching and prepares the signals used for final ordering. But there is no reason to spend that cost on the entire tail. ClipKitty reranks only a bounded top slice, then appends the rest in Phase 1 order.
7. **Use the matched region for snippets, highlights, and preview bootstrapping.**
   For large items, the row snippet and highlight analysis come from the best matching chunk, not from the top of the document. That makes results more legible and avoids wasting time analyzing irrelevant parts of large content on the hot path. When a full preview is opened, those chunk-local highlights are mapped back into full-document offsets.

The important idea is that search quality does not come from doing expensive work on everything. It comes from doing cheap work to find plausible candidates, then doing expensive work only where it can change what the user sees.

### Problems This Solves

- **Typos without brute force:** trigram recall finds `improt` when the stored text says `import`.
- **Scale without truncation:** large items stay fully searchable without forcing every query to scan their full text.
- **Large documents stop polluting common queries:** a 1 MB document no longer ranks highly just because it contains `error` 300 times.
- **Relevant previews:** snippets come from the matched region instead of the first lines of a huge paste.
- **Useful highlighting:** highlighted regions reflect where the match actually happened, including inside large documents.
- **Stable latency:** the hot path is bounded by chunk size and head size, not by total bytes in the worst matching documents.

## Building from Source

```bash
git clone https://github.com/jul-sh/clipkitty
cd clipkitty
make
```

Build a specific variant by setting `CONFIGURATION`. If you want the hardened one, you are building a different binary with different capabilities, not the same app with a few checkboxes unchecked.

```bash
make all CONFIGURATION=SparkleRelease  # With auto-update support
make all CONFIGURATION=Hardened        # Hardened (no network/files/sync)
make -C distribution hardened          # Hardened signed DMG
```

Requires macOS 15+ and Swift 6.2+.
