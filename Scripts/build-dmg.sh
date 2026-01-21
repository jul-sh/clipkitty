#!/bin/bash
# Build a DMG installer for ClipKitty
# Usage: ./build-dmg.sh [app-path] [output-dmg-path]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

APP_PATH="${1:-$PROJECT_ROOT/ClipKitty.app}"
OUTPUT_DMG="${2:-$PROJECT_ROOT/ClipKitty.dmg}"
VOLUME_NAME="ClipKitty"

# Verify app exists
if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at $APP_PATH" >&2
    exit 1
fi

# Create temp directory for DMG contents
TEMP_DIR=$(mktemp -d)
trap "rm -rf '$TEMP_DIR'" EXIT

# Generate background image
BACKGROUND_PATH="$TEMP_DIR/background.png"
echo "Generating DMG background image..."
swift "$SCRIPT_DIR/create-dmg-background.swift" "$BACKGROUND_PATH"

# Copy app to temp directory
cp -R "$APP_PATH" "$TEMP_DIR/"

# Create DMG staging directory
STAGING_DIR="$TEMP_DIR/staging"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"

# Add background image to staging
mkdir -p "$STAGING_DIR/.background"
cp "$BACKGROUND_PATH" "$STAGING_DIR/.background/background.png"

# Remove existing DMG if present
rm -f "$OUTPUT_DMG"

# Check if create-dmg is available, otherwise use hdiutil directly
if command -v create-dmg &> /dev/null; then
    echo "Building DMG with create-dmg..."
    create-dmg \
        --volname "$VOLUME_NAME" \
        --background "$BACKGROUND_PATH" \
        --window-pos 200 120 \
        --window-size 660 500 \
        --icon-size 100 \
        --icon "$(basename "$APP_PATH")" 165 280 \
        --hide-extension "$(basename "$APP_PATH")" \
        --app-drop-link 495 280 \
        "$OUTPUT_DMG" \
        "$STAGING_DIR/"
else
    echo "Building DMG with hdiutil (install create-dmg for prettier results)..."

    # Create Applications symlink for manual build
    ln -s /Applications "$STAGING_DIR/Applications"

    # Create a temporary DMG
    TEMP_DMG="$TEMP_DIR/temp.dmg"

    # Calculate size needed (app size + 20MB buffer)
    APP_SIZE=$(du -sm "$STAGING_DIR" | cut -f1)
    DMG_SIZE=$((APP_SIZE + 20))

    # Create DMG
    hdiutil create -srcfolder "$STAGING_DIR" \
        -volname "$VOLUME_NAME" \
        -fs HFS+ \
        -fsargs "-c c=64,a=16,e=16" \
        -format UDRW \
        -size "${DMG_SIZE}m" \
        "$TEMP_DMG"

    # Mount the DMG to configure Finder view
    hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG" -mountpoint "/Volumes/$VOLUME_NAME"

    # Configure Finder view using AppleScript
    osascript <<EOF || true
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 860, 620}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 100
        set background picture of viewOptions to file ".background:background.png"
        set position of item "ClipKitty.app" of container window to {165, 280}
        set position of item "Applications" of container window to {495, 280}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

    # Unmount
    sync
    sleep 1
    hdiutil detach "/Volumes/$VOLUME_NAME" 2>/dev/null || hdiutil detach "/Volumes/$VOLUME_NAME" -force

    # Convert to compressed read-only DMG
    hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_DMG"
fi

echo ""
echo "DMG created successfully: $OUTPUT_DMG"
echo "Size: $(du -h "$OUTPUT_DMG" | cut -f1)"
