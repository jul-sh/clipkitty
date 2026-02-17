#!/bin/bash
# Prepares macOS environment for taking clean screenshots
# Sets a neutral desktop background, hides other windows, and restores state afterward
# Usage: ./distribution/prepare-screenshot-environment.sh <command>
# Example: ./distribution/prepare-screenshot-environment.sh "xcodebuild test ..."

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BACKGROUND_IMAGE="/System/Library/Desktop Pictures/Solid Colors/Silver.png"

# Save current state for restoration
PREV_DESKTOP="$(osascript -e 'tell application "Finder" to get POSIX path of (desktop picture as alias)' 2>/dev/null || true)"
VISIBLE_APPS_FILE="$(mktemp /tmp/clipkitty_visible_apps.XXXXXX)"
osascript -e 'tell application "System Events" to get name of every process whose visible is true' 2>/dev/null | tr ',' '\n' | sed 's/^ *//' > "$VISIBLE_APPS_FILE" || true

restore_environment() {
    echo "Restoring environment..."
    # Restore visibility only to apps that were previously visible
    if [ -s "$VISIBLE_APPS_FILE" ]; then
        while IFS= read -r app_name; do
            [ -z "$app_name" ] && continue
            osascript -e "tell application \"System Events\" to set visible of process \"$app_name\" to true" 2>/dev/null || true
        done < "$VISIBLE_APPS_FILE"
    fi
    rm -f "$VISIBLE_APPS_FILE"
    if [ -n "$PREV_DESKTOP" ] && [ -f "$PREV_DESKTOP" ]; then
        osascript -e "tell application \"Finder\" to set desktop picture to POSIX file \"$PREV_DESKTOP\"" 2>/dev/null || true
    fi
}
trap restore_environment EXIT

echo "Setting desktop background to: $BACKGROUND_IMAGE"
osascript -e "tell application \"Finder\" to set desktop picture to POSIX file \"$BACKGROUND_IMAGE\"" 2>/dev/null || true

echo "Hiding other windows..."
osascript -e 'tell application "System Events" to set visible of every process whose name is not "ClipKitty" to false' 2>/dev/null || true

if [ -n "$CI" ]; then
    echo "CI detected - cleaning dock..."
    defaults write com.apple.dock persistent-apps -array
    killall Dock 2>/dev/null || true
fi

sleep 1
echo "Environment ready. Running command..."
echo ""

# Run the provided command
eval "$@"

exit_code=$?
echo ""
echo "Command completed with exit code: $exit_code"

exit $exit_code
