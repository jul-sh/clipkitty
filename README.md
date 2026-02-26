# ClipKitty

<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/icon.png" alt="ClipKitty icon" width="60">

**Never lose what you copied.**

Unlimited history • Instant fuzzy search • Live preview • Private & offline

<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/marketing_1.png" alt="ClipKitty clipboard history" width="820">
<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/marketing_2.png" alt="ClipKitty fuzzy search" width="820">
<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/marketing_3.png" alt="ClipKitty content filter" width="820">

## Why it exists

You copied that command last week. That code snippet yesterday. That address six months ago. Your clipboard manager either forgot it, slowed down searching for it, or cut off half the content.

ClipKitty stores everything. Finds it in milliseconds—whether you have 100 items or 100 million. Shows the full text, never truncated. Built for people who copy lots of things and need to find them again.

## Why ClipKitty?

| | ClipKitty |
|---|---|
| **vs Maccy** | Same simplicity, no limits. Maccy caps at 999 items and slows past 200. ClipKitty scales to millions with live preview instead of hover tooltips. |
| **vs Raycast** | Same speed, no expiration. Raycast doesn't save long clips; it's free tier expires after 3 months ClipKitty preserves everything forever, strictly offline. |
| **vs Paste** | Same utility, no subscription. Paste charges $30/year. ClipKitty is free on GitHub or pay once on the App Store. |

## Features

* **Unlimited History**: No caps, no expiration. Text, images, links, colors—everything preserved in full, forever.
* **Fuzzy Search That Scales**: Type "improt" and find "import". Type "dockr prodction" and find "docker push production". Powered by Tantivy, the same search engine used in production databases.
* **Live Preview Pane**: See full content instantly as you navigate. Multi-line text, code blocks, images—no truncation, no waiting.
* **OCR & Smart Search**: Search text inside images and screenshots. AI-powered descriptions make visual content searchable.
* **Keyboard-First**: `⌥Space` to open, arrow keys to navigate, `Return` to paste. `⌘1-9` for quick access.
* **Privacy-First**: 100% on-device and offline. No telemetry, no cloud sync, no accounts.
* **Free & Open Source**: GPL-3.0 licensed. Install free from GitHub or support development on the App Store.

## Installation

### Quick Install (Recommended)

```bash
# Downloads the latest release and installs ClipKitty.app to /Applications
curl -sL "$(curl -s https://api.github.com/repos/jul-sh/clipkitty/releases/latest | grep browser_download_url | grep .dmg | cut -d'"' -f4)" -o /tmp/ClipKitty.dmg && hdiutil attach /tmp/ClipKitty.dmg -quiet && cp -R "/Volumes/ClipKitty/ClipKitty.app" /Applications/ && hdiutil detach "/Volumes/ClipKitty" -quiet && rm /tmp/ClipKitty.dmg
```

### Manual Download

1. Download the latest DMG from [GitHub Releases](https://github.com/jul-sh/clipkitty/releases).
2. Drag ClipKitty to your Applications folder.

## Getting Started

1. Press **⌥Space** to open your clipboard history.
2. Type to fuzzy search.
3. Use **Arrow Keys** to navigate and **Return** to paste.

## Keyboard Shortcuts

| Shortcut | Action |
| --- | --- |
| **⌥Space** | Open clipboard history |
| **↑ / ↓** | Navigate |
| **Return** | Paste selected item |
| **⌘1–9** | Jump to item 1–9 |
| **Tab** | Cycle content type filter |
| **Delete** | Delete selected item |
| **Escape** | Close |

## Building from Source

```bash
git clone https://github.com/jul-sh/clipkitty
cd clipkitty
make
```

Requires macOS 15+ and Swift 6.2+.
