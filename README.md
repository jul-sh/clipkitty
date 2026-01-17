# ClipKitty

<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/icon.png" alt="ClipKitty icon" width="60">

**Never lose a copy again.** ClipKitty is a fast, native clipboard manager for macOS that keeps your entire copy history searchable and instantly accessible—without cluttering your screen.

<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/screenshot.png" alt="ClipKitty screenshot" width="820">

## What it does

- **One hotkey away** – Press ⌥Space to open your clipboard history (customizable)
- **Search anything** – Find text, links, images, and more with instant full-text search
- **Keyboard-first** – Navigate with arrows, press Return to paste. Or click to select
- **Always available** – Lives in your menu bar, never in your dock
- **Handle anything** – From single characters to millions of items, lightning-fast performance

## Why you'll love it

- **Capture everything** – Unlimited clipboard history without performance hits
- **Search like a pro** – Powerful FTS5 search with substring matching; type as you think
- **Respectfully minimal** – No ads, no accounts, no telemetry. Just your data, locally
- **Built right** – Native Swift on macOS, optimized for speed and battery life

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
