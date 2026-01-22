# ClipKitty

<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/icon.png" alt="ClipKitty icon" width="60">

**Your clipboard history from day one. Searchable in milliseconds.**

Unlimited history • Instant fuzzy search • Multi-line preview • Private

<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/screenshot.png" alt="ClipKitty screenshot" width="820">

## Why it exists

You copied that command last week. That error message yesterday. That address three months ago. Your clipboard manager either forgot it, slowed to a crawl searching for it, or truncated half of it.

ClipKitty stores everything. And with optimized fuzzy search you'll find your last item as quickly as your millionth. Built for people who copy lots of things and need to find them again.

## Why ClipKitty over alternatives?

**vs Maccy**: Maccy caps at 999 items, and its search slows down past 200. ClipKitty keeps unlimited history, scaling to millions with no performance degradation. With ClipKitty offers a life multi-line preview pane instead of waiting for tooltips.

**vs Raycast**: Raycast truncates items at ~32k characters and limits free history to 3 months. ClipKitty has no character limits and keeps everything forever. Fully offline; your clipboard never touches the cloud.

**vs Paste**: ClipKitty forces no subscription. Just a fast, local clipboard manager you own outright. Fast fuzzy search on top.

## Features

- **Unlimited clipboard history**: Clipboard history that doesn’t forget, doesn’t truncate, and stays fast.
- **Fuzzy search that scales**: Type “improt” and find “import”. Stays fast whether you have 100 items or 1,000,000. ClipKitty uses nucleo and tantivy; the same infrastructure as production search engines. Results in under 50ms whether your history holds 100 items or 1,000,000.
- **Live preview**: See full content as you navigate. No truncation, no waiting for tooltips.
- **Keyboard-first**: ⌥Space to open, arrow keys to navigate, Return to paste.
- **Privacy-first**: On device, fully offline, no telemetry.

## Installation

### Easy Install via Homebrew

If you have [Homebrew](https://brew.sh) installed, run:

```bash
brew install jul-sh/tap/clipkitty
```

### Manual Download

1. Download from [GitHub Releases](https://github.com/jul-sh/clipkitty/releases)
1. Press **⌥Space** to open your clipboard history
1. Type to search, arrow keys to navigate, Return to paste

## Keyboard shortcuts

|Shortcut|Action                |
|--------|----------------------|
|⌥Space  |Open clipboard history|
|↑ / ↓   |Navigate              |
|Return  |Paste selected item   |
|⌘1–9    |Jump to item 1–9      |
|Escape  |Close                 |

All shortcuts are customizable in Settings.

## Privacy

Your clipboard data never leaves your machine. ClipKitty runs entirely offline.

## Building from source

```bash
git clone https://github.com/jul-sh/clipkitty
cd clipkitty
make build bundle icon plist
```

Requires macOS 15+ and Swift 6.2+.
