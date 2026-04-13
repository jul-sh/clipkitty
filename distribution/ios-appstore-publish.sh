#!/usr/bin/env bash
#
# Archive the iOS ClipKitty app, export an IPA, and upload to App Store
# Connect via distribution/publish.py.
#
# Usage:
#   distribution/ios-appstore-publish.sh <VERSION> <BUILD_NUMBER>
#
# Prerequisites:
#   * ClipKitty.xcworkspace materialised (Scripts/nix-generate.sh).
#   * iOS distribution certificate + provisioning profile(s) installed in
#     the keychain by CI prior to invocation.
#   * An ExportOptions-iOS.plist living next to this script.

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <VERSION> <BUILD_NUMBER>" >&2
  exit 2
fi

VERSION="$1"
BUILD_NUMBER="$2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="ClipKitty"
DERIVED_DATA="$PROJECT_ROOT/DerivedData"
ARCHIVE_PATH="$DERIVED_DATA/ClipKittyiOS.xcarchive"

cd "$PROJECT_ROOT"

echo "Archiving ClipKittyiOS (AppStore) v$VERSION ($BUILD_NUMBER)..."
xcodebuild archive \
  -workspace "$PROJECT_ROOT/$APP_NAME.xcworkspace" \
  -scheme ClipKittyiOS-AppStore \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=iOS" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

echo "Exporting IPA..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$SCRIPT_DIR/ExportOptions-iOS.plist" \
  -exportPath "$PROJECT_ROOT"

echo "IPA exported: $PROJECT_ROOT/ClipKittyiOS.ipa"

echo "Publishing iOS build to App Store Connect..."
"$SCRIPT_DIR/publish.py" --platform ios ${PUBLISH_FLAGS:-} --version "$VERSION"
