# ClipKitty

<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/icon.png" alt="ClipKitty icon" width="60">

**The clipboard manager for power users.** ClipKitty is a native macOS app that gives you instant preview, fuzzy search, and a history that scales to millions of items—without slowing down.

<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/screenshot.png" alt="ClipKitty screenshot" width="820">

## Why ClipKitty?

**Instant preview.** See the full content of any item before you paste. Code snippets, multiline text, JSON blobs—no more guessing which "https://..." is the right one.

**Fuzzy search.** Find what you need even with typos. Search "improt" and still find "import". Whitespace-aware phrase matching when you need precision.

**Scales forever.** Built on SQLite FTS5 with trigram indexing. Your first item loads as fast as your millionth. No lag, no memory bloat, no cleanup prompts.

## Features

- **One hotkey** – ⌥Space opens your history (customizable)
- **Keyboard-first** – Arrow keys to navigate, Return to paste
- **Live preview** – See full content in the preview pane as you navigate
- **Smart search** – Substring matching, fuzzy tolerance, phrase search with trailing space
- **Images & links** – Stores screenshots, copies link metadata automatically
- **Privacy-first** – Sandboxed, offline-only, no telemetry

## Quick Start

1. **Download** from [GitHub Releases](https://github.com/jul-sh/clipkitty/releases)
2. **Open** ClipKitty.app (or drag to Applications)
3. **Press ⌥Space** to open your clipboard history
4. **Search** by typing, or use arrow keys to navigate
5. **Paste** by pressing Return

That's it. Start copying things, and they'll automatically appear in your history.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌥Space | Toggle clipboard history panel |
| ↑ / ↓ | Navigate list |
| Return | Paste selected item |
| Escape | Close panel |
| ⌘1–9 | Jump to item 1–9 |
| Click item | Select & focus search |

All shortcuts are customizable in Settings.

## Privacy & Security

Your clipboard data is **never sent anywhere**. ClipKitty runs entirely offline on your machine.

**What it can access:**
- Your clipboard (when you copy)
- Your clipboard history (stored locally in `~/Library/Application Support/ClipKitty`)

**What it cannot access:**
- Your files, folders, or home directory
- The internet or any external servers
- Your camera, microphone, or location
- Other apps or system processes

This is enforced by macOS itself through [App Sandbox](https://developer.apple.com/app-sandboxing/). Verify the permissions yourself:

```bash
codesign -d --entitlements - /Applications/ClipKitty.app
```

You'll see `app-sandbox` is enabled and network/automation entitlements are absent.

## Download

Get the latest build from [GitHub Releases](https://github.com/jul-sh/clipkitty/releases). Every commit is automatically built and released.

## Build from Source

```bash
git clone https://github.com/jul-sh/clipkitty
cd clipkitty
make build bundle icon plist
```

The app will be created at `ClipKitty.app`. Requires macOS 15+ and Swift 6.2+.
