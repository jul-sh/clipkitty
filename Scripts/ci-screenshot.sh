#!/bin/bash
set -e

echo "🐱 ClipKitty CI Screenshot Test"
echo "================================"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Build the app
echo ""
echo "📦 Building ClipKitty..."
./build-app.sh

# Populate database with test data
echo ""
echo "📋 Populating clipboard database with test data..."
swift run PopulateTestData

# Kill any existing instance
echo ""
echo "🔄 Restarting ClipKitty..."
pkill -9 ClipKitty 2>/dev/null || true
sleep 0.5

# Launch the app with --show-panel argument
echo ""
echo "🚀 Launching ClipKitty with panel open..."
open -a "$PROJECT_DIR/ClipKitty.app" --args --show-panel

# Set a real macOS wallpaper so the screenshot has a natural backdrop.
echo ""
echo "🖼️  Setting desktop wallpaper..."
WALLPAPER_DIR="/System/Library/Desktop Pictures"
WALLPAPER_PATH=""
for candidate in "$WALLPAPER_DIR"/*.heic "$WALLPAPER_DIR"/*.jpg "$WALLPAPER_DIR"/*.png; do
    if [ -f "$candidate" ]; then
        WALLPAPER_PATH="$candidate"
        break
    fi
done
if [ -n "$WALLPAPER_PATH" ]; then
    if ! osascript -e "tell application \"System Events\" to tell every desktop to set picture to POSIX file \"${WALLPAPER_PATH}\""; then
        echo "⚠️  Failed to set wallpaper; continuing with current background"
    fi
else
    echo "⚠️  No system wallpaper found, keeping current background"
fi

# Wait for app to start and panel to render
sleep 2

# Take screenshot
echo ""
echo "📸 Taking screenshot..."
SCREENSHOT_PATH="$PROJECT_DIR/screenshot-clipkitty.png"

WINDOW_BOUNDS=$(osascript <<'EOF' 2>/dev/null || true
tell application "System Events"
    tell process "ClipKitty"
        if (count of windows) is 0 then return ""
        set win to window 1
        set {x, y} to position of win
        set {w, h} to size of win
        return (x as integer) & "," & (y as integer) & "," & (w as integer) & "," & (h as integer)
    end tell
end tell
EOF
)

if [ -n "$WINDOW_BOUNDS" ]; then
    screencapture -x -R "$WINDOW_BOUNDS" "$SCREENSHOT_PATH" 2>/dev/null
else
    echo "⚠️  Could not resolve window bounds; falling back to full-screen capture"
    screencapture -x "$SCREENSHOT_PATH" 2>/dev/null
fi

if [ -f "$SCREENSHOT_PATH" ]; then
    SIZE=$(ls -lh "$SCREENSHOT_PATH" | awk '{print $5}')
    echo "✅ Screenshot saved: $SCREENSHOT_PATH ($SIZE)"
else
    echo "⚠️  screencapture failed (no display available)"
    exit 1
fi

echo ""
echo "🎉 Done!"
