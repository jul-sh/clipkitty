# ClipKitty

<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/icon.png" alt="ClipKitty icon" width="60">

A fast, native clipboard manager for macOS with support for unlimited clipboard history.

<img src="https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/screenshot.png" alt="ClipKitty screenshot" width="820">

## Features

- **Instant access** – Press ⌥Space (customizable) or click the menu bar icon
- **Fast search** – FTS5 trigram-powered substring matching
- **Keyboard-driven** – Arrow keys to navigate, Return to paste
- **Lightweight** – Native Swift app in the menu bar, no dock icon
- **Scales to millions** – O(log n) keyset pagination, streaming results, cancellable queries


## Security Audit

ClipKitty execution is local-only; security is enforced by the macOS App Sandbox kernel subsystem.

### Constraints

1. **Sandbox**: Process resides in a containerized root (`~/Library/Containers/com.clipkitty.app`); no access to the user home directory.
2. **FileSystem**: Entitlements for disk access are omitted; app state is restricted to the internal container.
3. **Hardware**: No camera, microphone, or location entitlements; the kernel denies access to all telemetry and capture devices.
4. **Network**: No `com.apple.security.network.*` entitlements; socket creation for external traffic is blocked.
5. **Automation**: No Apple Events entitlements; the app cannot script other processes or exfiltrate cross-app state.

### Verification

Audit the cryptographic entitlements of the binary:

```bash
codesign -d --entitlements - ClipKitty.app
```

Expected output:
* `com.apple.security.app-sandbox`: **true**
* `com.apple.security.network.client`: **missing**
* `com.apple.security.automation.apple-events`: **missing**

## Releases

Every commit is released automatically; download the latest build from GitHub Releases.
