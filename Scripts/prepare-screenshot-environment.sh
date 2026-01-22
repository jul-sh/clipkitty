#!/bin/bash
# Prepares macOS environment for taking clean screenshots
# Hides all windows except the app, sets background, and restores state afterward
# Usage: ./Scripts/prepare-screenshot-environment.sh <command>
# Example: ./Scripts/prepare-screenshot-environment.sh "xcodebuild test ..."

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BACKGROUND_IMAGE="$(make -s -C "$PROJECT_ROOT" print-background-image)"

# Temp file to store previous background
PREV_BG_FILE="/tmp/previous_background.heic"
PREV_APPS_FILE="/tmp/previous_dock_apps.plist"

cleanup() {
    echo "Restoring desktop environment..."

    # Restore previous background
    if [ -f "$PREV_BG_FILE" ]; then
        osascript -e "tell application \"Finder\" to set desktop picture to POSIX file \"$PREV_BG_FILE\"" 2>/dev/null || true
        rm -f "$PREV_BG_FILE"
    fi
}

# Set trap to cleanup on exit
trap cleanup EXIT

echo "Setting up screenshot environment..."

# Save current desktop background
echo "Saving current desktop configuration..."
osascript -e 'tell application "Finder" to get desktop picture' > "$PREV_BG_FILE" 2>/dev/null || true

# Set clean background
echo "Setting desktop background to: $BACKGROUND_IMAGE"
osascript -e "tell application \"Finder\" to set desktop picture to POSIX file \"$BACKGROUND_IMAGE\""

# Clean dock (only in CI)
if [ -n "$CI" ]; then
    echo "CI detected - cleaning dock..."
    defaults read com.apple.dock persistent-apps | head -1 > "$PREV_APPS_FILE" 2>/dev/null || true
    defaults write com.apple.dock persistent-apps -array
    killall Dock 2>/dev/null || true
    sleep 1
else
    echo "Local environment detected - preserving dock configuration"
fi

echo "Environment ready. Running command..."
echo ""

# Run the provided command
eval "$@"

exit_code=$?
echo ""
echo "Command completed with exit code: $exit_code"

exit $exit_code
