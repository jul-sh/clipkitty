#!/bin/bash
# Installs Homebrew dependencies for ClipKitty development
# Skips packages that are already installed

set -e

DEPS=(
    create-dmg    # For building DMG installers
    imagemagick   # For marketing screenshot processing
    ffmpeg        # For video recording and processing
    cliclick      # For UI automation in preview video recording
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

echo ""
echo "All dependencies installed."
