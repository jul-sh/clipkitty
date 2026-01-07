#!/bin/bash
set -e

APP_NAME="PaperTrail"
BUNDLE_ID="com.papertrail.app"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Building release..."
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all swift build -c release

echo "Creating app bundle..."
rm -rf "${APP_NAME}.app"
mkdir -p "${APP_NAME}.app/Contents/MacOS"
mkdir -p "${APP_NAME}.app/Contents/Resources"

# Copy executable
cp ".build/release/ClippySwift" "${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

# Copy bundled resources (fonts, etc.)
if [ -d ".build/release/ClippySwift_ClippySwift.bundle" ]; then
    cp -R ".build/release/ClippySwift_ClippySwift.bundle/Contents/Resources/"* "${APP_NAME}.app/Contents/Resources/" 2>/dev/null || true
fi

# Generate app icon
echo "Generating app icon..."
ICONSET_DIR="${SCRIPT_DIR}/AppIcons/Assets.xcassets/AppIcon.appiconset"
if [ -d "$ICONSET_DIR" ]; then
    # Create temporary iconset directory with required naming
    TEMP_ICONSET=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$TEMP_ICONSET"

    # Convert and copy icons to match Apple's iconset naming convention
    # Using sips to ensure proper PNG format (source files may be JPEG with .png extension)
    sips -s format png "${ICONSET_DIR}/16.png" --out "${TEMP_ICONSET}/icon_16x16.png" > /dev/null
    sips -s format png "${ICONSET_DIR}/32.png" --out "${TEMP_ICONSET}/icon_16x16@2x.png" > /dev/null
    sips -s format png "${ICONSET_DIR}/32.png" --out "${TEMP_ICONSET}/icon_32x32.png" > /dev/null
    sips -s format png "${ICONSET_DIR}/64.png" --out "${TEMP_ICONSET}/icon_32x32@2x.png" > /dev/null
    sips -s format png "${ICONSET_DIR}/128.png" --out "${TEMP_ICONSET}/icon_128x128.png" > /dev/null
    sips -s format png "${ICONSET_DIR}/256.png" --out "${TEMP_ICONSET}/icon_128x128@2x.png" > /dev/null
    sips -s format png "${ICONSET_DIR}/256.png" --out "${TEMP_ICONSET}/icon_256x256.png" > /dev/null
    sips -s format png "${ICONSET_DIR}/512.png" --out "${TEMP_ICONSET}/icon_256x256@2x.png" > /dev/null
    sips -s format png "${ICONSET_DIR}/512.png" --out "${TEMP_ICONSET}/icon_512x512.png" > /dev/null
    sips -s format png "${ICONSET_DIR}/1024.png" --out "${TEMP_ICONSET}/icon_512x512@2x.png" > /dev/null

    # Generate icns file
    iconutil -c icns "$TEMP_ICONSET" -o "${APP_NAME}.app/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$TEMP_ICONSET")"
    echo "App icon generated successfully"
else
    echo "Warning: Icon assets not found at $ICONSET_DIR"
fi

# Create Info.plist
cat > "${APP_NAME}.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Paper Trail</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "Done! Created ${APP_NAME}.app"
echo "Run with: open ${APP_NAME}.app"
