#!/usr/bin/env bash
#
# Build the AppStore variant, sign + package for the Mac App Store, and
# upload via distribution/publish.py.
#
# Usage:
#   distribution/appstore-publish.sh <VERSION> <BUILD_NUMBER>
#
# Inputs:
#   * A staged `DerivedData/Build/Products/AppStore/ClipKitty.app` is
#     produced by `Scripts/nix-sign-app.sh AppStore $VERSION $BUILD_NUMBER`.
#   * A provisioning profile from PROVISION_PROFILE_BASE64 (decrypted from
#     secrets/) — written to ClipKitty.provisionprofile in PROJECT_ROOT.
#   * App Store identities ("3rd Party Mac Developer Application" +
#     "3rd Party Mac Developer Installer") present in the keychain search
#     list. CI installs them from apple-actions/import-codesign-certs.
#
# Outputs:
#   * $PROJECT_ROOT/ClipKitty.pkg (signed installer package).
#   * Upload result from `distribution/publish.py`.
#
# The original Makefile target also re-ran the entire nix build here; we now
# delegate the build + mutable-copy + signing step to Scripts/nix-sign-app.sh
# so Hardened and App Store flows share one post-store signing contract.

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
APP_PATH="$DERIVED_DATA/Build/Products/AppStore/$APP_NAME.app"

APPSTORE_SIGNING_IDENTITY="${APPSTORE_SIGNING_IDENTITY:-3rd Party Mac Developer Application}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-3rd Party Mac Developer Installer}"

cd "$PROJECT_ROOT"

"$SCRIPT_DIR/setup-signing.sh"

cleanup() {
  "$SCRIPT_DIR/setup-signing.sh" --cleanup || true
  rm -f "$PROJECT_ROOT/ClipKitty.provisionprofile"
}
trap cleanup EXIT

PROV="${PROVISIONING_PROFILE:-}"
if [ -z "$PROV" ]; then
  echo "Decrypting provisioning profile from secrets..."
  "$SCRIPT_DIR/read-secret.sh" PROVISION_PROFILE_BASE64 \
    | base64 --decode > "$PROJECT_ROOT/ClipKitty.provisionprofile"
  PROV="$PROJECT_ROOT/ClipKitty.provisionprofile"
fi

# Re-stage the nix-built bundle with the runtime-versioned plist, embed the
# provisioning profile into the copied-out bundle, and sign it in place.
PROVISIONING_PROFILE="$PROV" \
APPSTORE_SIGNING_IDENTITY="$APPSTORE_SIGNING_IDENTITY" \
  "$PROJECT_ROOT/Scripts/nix-sign-app.sh" AppStore "$VERSION" "$BUILD_NUMBER"

echo "Creating installer package..."
rm -f "$PROJECT_ROOT/$APP_NAME.pkg"
productbuild --component "$APP_PATH" /Applications \
  --sign "$INSTALLER_IDENTITY" \
  "$PROJECT_ROOT/$APP_NAME.pkg"

echo "Installer package created: $PROJECT_ROOT/$APP_NAME.pkg"

echo "Publishing to App Store Connect..."
"$SCRIPT_DIR/publish.py" ${PUBLISH_FLAGS:-} --version "$VERSION"
