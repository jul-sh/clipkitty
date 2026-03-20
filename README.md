# ClipKitty

<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/icon.png" alt="ClipKitty icon" width="60">

**Never lose what you copied.**

Unlimited history • Instant fuzzy search • Live preview • Private & offline

<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/marketing_1.png" alt="ClipKitty clipboard history" width="820">
<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/marketing_2.png" alt="ClipKitty fuzzy search" width="820">
<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/marketing_3.png" alt="ClipKitty content filter" width="820">

## Why it exists

You copied that command last week. That code snippet yesterday. That address six months ago. Your clipboard manager either forgot it, couldn't find it, or cut off half the content.

ClipKitty stores everything. Finds it in milliseconds; whether you have 100 items or 100,000. Built for people who copy lots of things and need to find them again.

## Why ClipKitty?

| | ClipKitty |
|---|---|
| **vs Maccy** | Same simplicity, no limits. Maccy caps at 999 items and slows past 200. ClipKitty scales to millions. And with live preview you never have to wait for tooltips to see what you're pasting. |
| **vs Raycast** | Same speed, better search, no expiration. Raycast doesn't save long clips; it's free tier expires after 3 months. ClipKitty preserves everything forever and finds it faster with smarter, typo tolerant search. |
| **vs Paste** | Same utility, no subscription. Paste charges $30/year. ClipKitty is free on GitHub or pay once on the App Store. |

## Features

* **Unlimited History**: No caps, no expiration. Text, images, files, colors; everything preserved in full, forever.
* **Fuzzy Search That Scales**: Type "improt" and find "import". Type "dockr prodction" and find "docker push production". All under 50ms; even with millions of items.
* **Live Preview Pane**: See full content instantly as you navigate. Multi-line text, code blocks, images; no truncation, no waiting on tooltips.
* **OCR & Smart Search**: Search text inside images and screenshots. AI-powered descriptions make visual content searchable.
* **Keyboard-First**: `⌥Space` to open, arrow keys to navigate, `Return` to paste. `⌘1-9` for quick access.
* **Privacy-First**: 100% on-device and offline. No telemetry, no cloud sync, no accounts.
* **Secure & Attested**: Don't take my word for it. Source code is fully open source and auditable. Builds are attested: you can [verify](VERIFY.md) the app was built from the public source code.

## Installation

### Quick Install 

<a href="https://apps.apple.com/us/app/clipkitty-clipboard-manager/id6759137247?mt=12"><img src="https://github.com/jul-sh/clipkitty/raw/main/distribution/MacAppStore.png" alt="Download on the Mac App Store" width="200"></a>

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
| **Escape** | Close |

## Building from Source

```bash
git clone https://github.com/jul-sh/clipkitty
cd clipkitty
make
```

Requires macOS 15+ and Swift 6.2+.
