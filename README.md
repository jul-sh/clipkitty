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

Clipboard search sounds simple until you ask for the version people actually want:

- history can grow for months or years
- typos still work, because memory is fuzzy and fingers are worse
- highlighting that reflects which words matched
- search updates on every keystroke
- huge clips, logs, stack traces, and source files stay searchable in full

The obvious baseline is to iterate over every item, for every query. This stops working with thousands of items, and it really stops working when some items are hundreds of kilobytes or megabytes long. Maccy does this, and the limitations are why its history is capped at 200 items, and why it freezes if you copy a long item.

The smarter move is indexing. Instead of doing all the work when the user types, do some of it earlier, when an item is saved. Build a structure that says "this word appears over here", so a query can jump to likely matches instead of rereading the whole clipboard.

The simplest index is a prefix tree over the words at the start of each item. This is what Raycast uses for clipboard history. It is fast, and it supports much longer histories than scanning. But the tradeoff shows up in the UX: it only finds exact matches at the exact start of an item. If you copied `docker compose exec api rails console`, searching `rails console` should find it. A start-only index misses it. It also breaks typo tolerance: Raycast finds nothing for `improt` when the item says `import`.

ClipKitty uses a trigram-based index for candidate recall. A trigram is a three-character slice of text: `import` contains `imp`, `mpo`, `por`, and `ort`. At query time, it uses those precomputed slices to follow posting lists to likely matches instead of scanning the full history, while also returning useful match-quality signals such as overlap and word-position evidence. This is fast, but it is still an approximation: shared trigrams are not the same as a good human match.

To mitigate those weaknesses, ClipKitty takes the best matches from recall and reranks them separately. Because this is already a much smaller set, ClipKitty can afford to spend more compute finding the best human match: fine grained typo tolerance, recency, document size, and intelligent highlighting all matter here.

The important idea is that search quality does not come from doing expensive work on everything. It comes from doing cheap work to find plausible candidates, then doing expensive work only where it can change what the user sees.

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
