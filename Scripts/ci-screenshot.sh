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

# Wait for app to start and panel to render
sleep 2

# Take screenshot
echo ""
echo "📸 Taking screenshot..."
SCREENSHOT_PATH="$PROJECT_DIR/screenshot-clipkitty.png"

if screencapture -x "$SCREENSHOT_PATH" 2>/dev/null; then
    if [ -f "$SCREENSHOT_PATH" ]; then
        SIZE=$(ls -lh "$SCREENSHOT_PATH" | awk '{print $5}')
        echo "✅ Screenshot saved: $SCREENSHOT_PATH ($SIZE)"
    else
        echo "⚠️  Screenshot file not created"
        exit 1
    fi
else
    echo "⚠️  screencapture failed (no display available)"
    exit 1
fi

echo ""
echo "🎉 Done!"
