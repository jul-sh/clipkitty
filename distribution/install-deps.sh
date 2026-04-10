#!/bin/bash
# Local Homebrew fallback for ClipKitty development dependencies.
# CI uses Nix (see flake.nix); this script is for local dev without Nix.
# Skips packages that are already installed.

set -e

DEPS=(
    age           # For decrypting secrets (provisioning profile, API keys)
    create-dmg    # For building DMG installers
    ffmpeg        # For video recording and processing
)

echo "=== Installing ClipKitty Dependencies ==="

# Check if Homebrew is installed
if ! command -v brew &> /dev/null; then
    echo "Error: Homebrew is required. Install from https://brew.sh"
    exit 1
fi

for dep in "${DEPS[@]}"; do
    if brew list "$dep" &> /dev/null; then
        echo "✓ $dep (already installed)"
    else
        echo "Installing $dep..."
        brew install "$dep"
    fi
done

# Install ASC CLI
if command -v asc &> /dev/null; then
    echo "✓ asc (already installed)"
else
    echo "Installing asc (App Store Connect CLI)..."
    brew install asc
fi

echo ""
echo "All dependencies installed."
