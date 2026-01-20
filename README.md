# ClipKitty

<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/icon.png" alt="ClipKitty icon" width="60">

**The clipboard manager that actually remembers.**
*When 999 items isn’t enough.*

Most clipboard managers cap out at a few hundred items and call it a day. ClipKitty stores everything; your first item loads as fast as your millionth. Built for people who copy thousands of things and need to find them again.

<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/screenshot.png" alt="ClipKitty screenshot" width="820">

## The problem

You copied that API response last week. That error message yesterday. That address three months ago. Your clipboard manager either forgot it, slowed to a crawl searching for it, or truncated half of it.

**ClipKitty doesn’t forget.** SQLite FTS5 with trigram indexing means search stays instant at any scale. No item limits, no time limits, no character limits.

## Why ClipKitty over alternatives?

**vs Maccy**: Maccy caps at 999 items, and its search slows down past 200. ClipKitty keeps unlimited history, scaling to millions with no performance degradation. With ClipKitty offers a life multi-line preview pane instead of waiting for tooltips.

**vs Raycast**: Raycast truncates items at ~32k characters and limits free history to 3 months. ClipKitty has no character limits and keeps everything forever. Fully offline; your clipboard never touches the cloud.

**vs Paste**: ClipKitty forces no no subscription. Just a fast, local clipboard manager you own outright. Fast fuzzy search on top.

## Features

- **Fuzzy search that scales**: Type “improt” and find “import”. Stays fast whether you have 100 items or 100,000.
- **Live preview**: See full content as you navigate. No truncation, no waiting for tooltips.
- **Keyboard-first**: ⌥Space to open, arrow keys to navigate, Return to paste.
- **Privacy-first**: Sandboxed, offline-only, no telemetry. Verify it yourself with `codesign -d --entitlements -`.

## Quick start

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

The app is sandboxed by macOS. It can access your clipboard and its own local storage (`~/Library/Application Support/ClipKitty`). It cannot access the internet, your files, or other apps. You can verify:

```bash
codesign -d --entitlements - /Applications/ClipKitty.app
```

## Building from source

```bash
git clone https://github.com/jul-sh/clipkitty
cd clipkitty
make build bundle icon plist
```

Requires macOS 15+ and Swift 6.2+.
