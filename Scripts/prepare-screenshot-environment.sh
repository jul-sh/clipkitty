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

    # Show all hidden windows
    osascript -e "tell application \"Finder\" to set visible of every window to true" 2>/dev/null || true

    # Restore dock apps
    if [ -f "$PREV_APPS_FILE" ]; then
        defaults write com.apple.dock persistent-apps -array-add "$(cat "$PREV_APPS_FILE")" 2>/dev/null || true
        rm -f "$PREV_APPS_FILE"
        killall Dock 2>/dev/null || true
    fi
}

# Set trap to cleanup on exit
trap cleanup EXIT

echo "Setting up screenshot environment..."

# Save and hide all windows except Finder
echo "Hiding other applications..."
osascript <<'APPLESCRIPT'
tell application "System Events"
    set visibleApps to (name of every application process whose visible is true)
    repeat with appName in visibleApps
        if appName is not "Finder" and appName is not "System Events" and appName is not "loginwindow" then
            tell application appName
                try
                    set visible of every window to false
                end try
            end tell
        end if
    end repeat
end tell
APPLESCRIPT

# Save current desktop background and Dock apps
echo "Saving current desktop configuration..."
osascript -e 'tell application "Finder" to get desktop picture' > "$PREV_BG_FILE" 2>/dev/null || true
defaults read com.apple.dock persistent-apps | head -1 > "$PREV_APPS_FILE" 2>/dev/null || true

# Set clean background
echo "Setting desktop background to: $BACKGROUND_IMAGE"
osascript -e "tell application \"Finder\" to set desktop picture to POSIX file \"$BACKGROUND_IMAGE\""

# Clean dock (remove apps, keep only Finder)
defaults write com.apple.dock persistent-apps -array
killall Dock 2>/dev/null || true
sleep 1

echo "Environment ready. Running command..."
echo ""

# Run the provided command
eval "$@"

exit_code=$?
echo ""
echo "Command completed with exit code: $exit_code"

exit $exit_code
