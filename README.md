# ClipKitty

<img src="AppIcon.icon/Assets/Image%204.png" alt="ClipKitty icon" width="30">

A fast, native clipboard manager for macOS with support for unlimited clipboard history.

<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/screenshot.png" alt="ClipKitty screenshot" width="820">

## Features

- **Instant access** – Press ⌥Space (customizable) or click the menu bar icon
- **Fast search** – FTS5 trigram-powered substring matching
- **Keyboard-driven** – Arrow keys to navigate, Return to paste
- **Lightweight** – Native Swift app in the menu bar, no dock icon


## Privacy

ClipKitty is 100% private. It does not send data to any server. This is enforced by the macOS App Sandbox:

1. **Hard-Disabled Network**: The app is built without any network entitlements. macOS will physically prevent the app from making outgoing or incoming connections.
2. **Open for Verification**: You can verify this yourself using the Terminal:

```bash
codesign -d --entitlements - /path/to/ClipKitty.app
```

If the output does not contain `com.apple.security.network.client`, the app is unable to talk to the internet.

## Releases

Every commit is released automatically; download the latest build from GitHub Releases.
