# Zero-Trust Privacy & Dotfiles Sync

I have implemented a comprehensive "Zero-Trust" security model for ClipKitty and synchronized the new version with your `dotfiles` repository.

## Work Summary

### 1. ClipKitty: Zero-Trust Lockdown
- **Sandbox Hardening**: Refactored `ClipKitty.entitlements` to be terse and technical. All hardware (camera, microphone, location) and network entitlements have been removed.
- **FileSystem Isolation**: Removed the `user-selected.read-write` entitlement, confining the app strictly to its own container (`~/Library/Containers/com.clipkitty.app`).
- **Technical Documentation**: Updated `README.md` and inline comments to follow a "first principles" approach, removing marketing language in favor of technical rigor.

### 2. Documentation & Assets
- **Compiled Icon**: Updated the build system to retain `AppIcon.icns`.
- **CI/CD Integration**: Modified the `screenshot.yml` workflow to automatically convert the compiled icon to a high-resolution PNG and deploy it to `gh-pages`.
- **README Refresh**: The README now points to the high-res `icon.png` on `gh-pages` and includes a verifiable cryptographic security audit.

### 3. Dotfiles Synchronization
- **Version Lock**: Updated `dotfiles/external.lock.json` with the latest ClipKitty commit (`e36e2e827420fc6694d443d0891436cccf770ef2`).
- **SHA256 Verification**: Manually built the release ZIP using the CI's `ditto` parameters to obtain the exact SHA256 hash required for the Nix installation.

### 4. Dotfiles Configuration
- **Curl Persistent Config**: Added `proto-default = "https"` to `dotfiles/dotfiles/.curlrc`. This file is managed by Home Manager and will be automatically symlinked to `~/.curlrc`.
- **Commit**: [4e6b9f3](https://github.com/jul-sh/dotfiles/commit/4e6b9f3)

## Verification Results

### Cryptographic Entitlements
I've verified the final binary with `codesign`; the output confirms only the core sandbox is present:
```bash
Executable=/Users/julsh/git/clipkitty/ClipKitty.app/Contents/MacOS/ClipKitty
[Dict]
        [Key] com.apple.security.app-sandbox
        [Value]
                [Bool] true
```

### Dotfiles State
The `dotfiles` repository is updated and pushed:
```bash
[main 80b98f7] Update ClipKitty
 1 file changed, 3 insertions(+), 3 deletions(-)
```
