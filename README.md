# ClipKitty

<img src="AppIcon.icon/Assets/Image%204.png" alt="ClipKitty icon" width="30">

A fast, native clipboard manager for macOS with support for unlimited clipboard history.

<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/screenshot.png" alt="ClipKitty screenshot" width="820">

## Features

- **Instant access** – Press ⌥Space (customizable) or click the menu bar icon
- **Fast search** – FTS5 trigram-powered substring matching
- **Keyboard-driven** – Arrow keys to navigate, Return to paste
- **Lightweight** – Native Swift app in the menu bar, no dock icon


## Privacy & Security Audit

ClipKitty is built as a **"Zero-Trust"** application. Since it is unsigned and local-first, we provide you with the tools to verify its privacy promises yourself.

### Our "Zero-Trust" Promise

1. **Hard-Boxed Sandbox**: The app is trapped in its own container (`~/Library/Containers/com.clipkitty.app`). It cannot "crawl" your home folder.
2. **Read-Only File System**: It can only touch files you explicitly select via a "Save" or "Open" dialog.
3. **Hardware Kill-Switch**: Access to your camera, microphone, and location is blocked at the macOS kernel level.
4. **Offline by Design**: There are no network entitlements. The app is unable to talk to the internet.
5. **Anti-Snoop Lock**: The app cannot "ask" other apps for data using Apple Events. It only knows what you actively copy.

### Self-Verify (The "Show Your Receipts" Command)

Run this command on the ClipKitty app bundle to see the cryptographic proof of these restrictions:

```bash
codesign -d --entitlements - ClipKitty.app
```

**What you will see:**
* `com.apple.security.app-sandbox`: **TRUE** (We are in a cage)
* `com.apple.security.network.client`: **MISSING** (We can't send data)
* `com.apple.security.device.camera`: **MISSING** (We can't see you)
* `com.apple.security.automation.apple-events`: **MISSING** (No snooping)

## Releases

Every commit is released automatically; download the latest build from GitHub Releases.
