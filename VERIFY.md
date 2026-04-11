# Verifying ClipKitty Builds

Open source lets you read the code. But the app you download? How can you verify it was built from that code?

## The Solution

ClipKitty is built entirely on GitHub's infrastructure; not on a developer's laptop. For every build, GitHub cryptographically signs an attestation: showing that this exact binary came from this exact commit.

You can verify this yourself.

## Verify the Installed App

```bash
HASH=$(shasum -a 256 /Applications/ClipKitty.app/Contents/MacOS/ClipKitty | cut -d' ' -f1)
echo "https://github.com/jul-sh/clipkitty/attestations/sha256:$HASH"
```

## Verify a Downloaded DMG

```bash
HASH=$(shasum -a 256 ~/Downloads/ClipKitty.dmg | cut -d' ' -f1)
echo "https://github.com/jul-sh/clipkitty/attestations/sha256:$HASH"
```

## Verify the Hardened Build

```bash
HASH=$(shasum -a 256 ~/Downloads/ClipKitty-Hardened.zip | cut -d' ' -f1)
echo "https://github.com/jul-sh/clipkitty/attestations/sha256:$HASH"
```

You can also verify the hardened build's entitlements contain no network or file access:

```bash
codesign -d --entitlements - /Applications/ClipKitty.app
```

What you want to see is basically nothing except `com.apple.security.app-sandbox`. No `network.client`, no `icloud`, no `files.user-selected`.

This gives you defense in depth. First, the code that does network requests and filesystem access is compiled out of the hardened binary; it does not exist. Second, even if it did, macOS App Sandbox would block it at the kernel level because the entitlements are not there. Both layers have to fail for the app to do something you did not ask it to do.

Open the URL. If an attestation exists, you'll see the exact commit that produced your binary. From there you can browse the exact source code used for that build.

The Apple app bundles themselves are produced by Bazel, with the Swift package graph pinned by [Package.resolved](Package.resolved) and the Bazel module graph pinned by [MODULE.bazel.lock](MODULE.bazel.lock).

## Further Reading

- [GitHub Artifact Attestations](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations)
- [SLSA Supply Chain Security](https://slsa.dev)
