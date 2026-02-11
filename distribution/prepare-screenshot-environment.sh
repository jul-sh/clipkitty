#!/bin/bash
# Prepares macOS environment for taking clean screenshots
# Hides all windows except the app, sets background, and restores state afterward
# Usage: ./distribution/prepare-screenshot-environment.sh <command>
# Example: ./distribution/prepare-screenshot-environment.sh "xcodebuild test ..."

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BACKGROUND_IMAGE="$(make -s -C "$SCRIPT_DIR" print-background-image)"

if [ -n "$CI" ]; then
    echo "Setting up screenshot environment..."

    # Set clean background
    echo "Setting desktop background to: $BACKGROUND_IMAGE"
    osascript -e "tell application \"Finder\" to set desktop picture to POSIX file \"$BACKGROUND_IMAGE\""

    echo "CI detected - cleaning dock..."
    PREV_APPS_FILE="$(mktemp /tmp/dock_apps.XXXXXX)"
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
