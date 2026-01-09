#!/bin/bash
set -e

APP_NAME="ClipKitty"
BUNDLE_ID="com.clipkitty.app"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Update this path to where your .icon folder is actually located
ICON_SOURCE="${SCRIPT_DIR}/AppIcon.icon"

echo "Building release..."
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all swift build -c release

echo "Creating app bundle..."
rm -rf "${APP_NAME}.app"
mkdir -p "${APP_NAME}.app/Contents/MacOS"
mkdir -p "${APP_NAME}.app/Contents/Resources"

# Copy executable
cp ".build/release/ClipKitty" "${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

# Copy bundled resources
if [ -d ".build/release/ClipKitty_ClipKitty.bundle" ]; then
    cp -R ".build/release/ClipKitty_ClipKitty.bundle/Contents/Resources/"* "${APP_NAME}.app/Contents/Resources/" 2>/dev/null || true
fi

# Generate app icon (MODERN METHOD)
echo "Compiling Liquid Glass icon..."
if [ -d "$ICON_SOURCE" ]; then
    # Compile the .icon file into Assets.car
    xcrun actool "$ICON_SOURCE" \
      --compile "${APP_NAME}.app/Contents/Resources" \
      --platform macosx \
      --target-device mac \
      --minimum-deployment-target 15.0 \
      --app-icon "AppIcon" \
      --output-partial-info-plist /dev/null
    
    echo "Assets.car generated successfully"
else
    echo "Warning: .icon source not found at $ICON_SOURCE"
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
    <string>ClipKitty</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

# Force Finder to refresh the icon
touch "${APP_NAME}.app"

echo "Done! Created ${APP_NAME}.app"
