#!/usr/bin/env bash
#
# Build one ClipKitty app variant via nix and materialise it under
# DerivedData/Build/Products/<Configuration>/ClipKitty.app, the path every
# downstream signing/zip/notarisation step already expects.
#
# Usage:
#   Scripts/nix-build-app.sh <Configuration> [VERSION] [BUILD_NUMBER]
#
# Configuration is one of: Release, Debug, Hardened, SparkleRelease, AppStore.
# VERSION / BUILD_NUMBER are optional; when set, the script patches the
# copied-out Info.plist with CFBundleShortVersionString / CFBundleVersion.
# The nix derivation itself stays deterministic; per-commit versioning lives
# in the post-copy patch so the store path is stable across runs.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <Configuration> [VERSION] [BUILD_NUMBER]" >&2
  exit 2
fi

CONFIGURATION="$1"
VERSION="${2:-}"
BUILD_NUMBER="${3:-}"

case "$CONFIGURATION" in
  Release)        VARIANT="clipkitty" ;;
  Debug)          VARIANT="clipkitty-debug" ;;
  Hardened)       VARIANT="clipkitty-hardened" ;;
  SparkleRelease) VARIANT="clipkitty-sparkle" ;;
  AppStore)       VARIANT="clipkitty-appstore" ;;
  *)
    echo "error: unknown Configuration=$CONFIGURATION" >&2
    echo "known: Release, Debug, Hardened, SparkleRelease, AppStore" >&2
    exit 2
    ;;
esac

APP_NAME="ClipKitty"
PRODUCTS="DerivedData/Build/Products"
DEST_DIR="$PRODUCTS/$CONFIGURATION"
DEST_APP="$DEST_DIR/$APP_NAME.app"

echo "Building $APP_NAME via nix: .#$VARIANT ($CONFIGURATION)"
nix build ".#$VARIANT" --out-link "result-$CONFIGURATION"

mkdir -p "$DEST_DIR"
rm -rf "$DEST_APP"
cp -R "result-$CONFIGURATION/$APP_NAME.app" "$DEST_APP"
chmod -R u+w "$DEST_APP"

APP_PLIST="$DEST_APP/Contents/Info.plist"
if [ -n "$VERSION" ]; then
  echo "Setting CFBundleShortVersionString = $VERSION"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PLIST"
fi
if [ -n "$BUILD_NUMBER" ]; then
  echo "Setting CFBundleVersion = $BUILD_NUMBER"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_PLIST"
fi

echo "Staged at $DEST_APP"
