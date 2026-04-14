#!/usr/bin/env bash
#
# Build one signable ClipKitty variant via nix, copy it out of the store,
# and sign the mutable on-disk bundle in DerivedData/.
#
# Usage:
#   Scripts/nix-sign-app.sh <Configuration> [VERSION] [BUILD_NUMBER]
#
# Supported configurations:
#   * Hardened
#   * AppStore
#
# Environment:
#   * `SIGNING_IDENTITY` overrides the Hardened signing identity
#   * `APPSTORE_SIGNING_IDENTITY` overrides the App Store signing identity
#   * `PROVISIONING_PROFILE` optionally embeds a provisioning profile for the
#     App Store build before signing

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <Configuration> [VERSION] [BUILD_NUMBER]" >&2
  exit 2
fi

CONFIGURATION="$1"
VERSION="${2:-}"
BUILD_NUMBER="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="$PROJECT_ROOT/DerivedData/Build/Products/$CONFIGURATION/ClipKitty.app"

case "$CONFIGURATION" in
  Hardened)
    SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
    ENTITLEMENTS="$PROJECT_ROOT/Sources/MacApp/ClipKitty.hardened.entitlements"
    TIMESTAMP_FLAG=(--timestamp)
    ;;
  AppStore)
    SIGNING_IDENTITY="${APPSTORE_SIGNING_IDENTITY:-3rd Party Mac Developer Application}"
    ENTITLEMENTS="$PROJECT_ROOT/Sources/MacApp/ClipKitty.appstore.entitlements"
    TIMESTAMP_FLAG=()
    ;;
  *)
    echo "error: unsupported Configuration=$CONFIGURATION" >&2
    echo "supported: Hardened, AppStore" >&2
    exit 2
    ;;
esac

if ! security find-identity -v -p codesigning 2>/dev/null | grep -F -q "$SIGNING_IDENTITY"; then
  echo "error: signing identity '$SIGNING_IDENTITY' not available in keychain search list" >&2
  exit 1
fi

"$PROJECT_ROOT/Scripts/nix-build-app.sh" "$CONFIGURATION" "$VERSION" "$BUILD_NUMBER"

if [ ! -d "$APP_PATH" ]; then
  echo "error: staged app not found at $APP_PATH" >&2
  exit 1
fi

if [ "$CONFIGURATION" = "AppStore" ] && [ -n "${PROVISIONING_PROFILE:-}" ]; then
  echo "Embedding provisioning profile..."
  cp "$PROVISIONING_PROFILE" "$APP_PATH/Contents/embedded.provisionprofile"
fi

echo "Signing ClipKitty ($CONFIGURATION) with '$SIGNING_IDENTITY'..."
codesign --force --options runtime "${TIMESTAMP_FLAG[@]}" \
  --sign "$SIGNING_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  "$APP_PATH"

codesign --verify --deep --strict "$APP_PATH"
echo "Signed app staged at $APP_PATH"
