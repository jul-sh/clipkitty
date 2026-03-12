# Verifying ClipKitty

How do you know the app you're running was actually built from this public source code?

## The Problem

Open source lets you read the code. But the binary you download? There's no guarantee it was built from that code. The developer could publish clean source code while shipping a binary built from something completely different.

## The Solution

ClipKitty is built entirely on GitHub's infrastructure; not on a developer's laptop. For every build, GitHub cryptographically signs an attestation: showing that this exact binary came from this exact commit.

You can verify this yourself.

## Verify Your Installed App

```bash
gh attestation verify /Applications/ClipKitty.app/Contents/MacOS/ClipKitty --owner jul-sh
```

If valid, you'll see which commit built your binary:

```
✓ Verification succeeded!

sha256:a1b2c3d4e5f6...

Repo:   jul-sh/clipkitty
Commit: 5c75461...
```

That commit hash links directly to the source code that produced the app on your machine.

## Requirements

[Install the GitHub CLI](https://cli.github.com)

## Further Reading

- [GitHub Artifact Attestations](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations)
- [SLSA Supply Chain Security](https://slsa.dev)
