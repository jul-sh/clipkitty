#!/usr/bin/env bash
#
# Capture localized App Store marketing screenshots via the ClipKittyUITests
# testTakeMarketingScreenshots UI test. Assumes:
#   * ClipKitty.xcworkspace is already materialised (run Scripts/nix-generate.sh).
#   * The AppStore variant is already staged under
#     DerivedData/Build/Products/AppStore/ClipKitty.app
#     (run Scripts/nix-build-app.sh AppStore first).
#
# For each locale, this script:
#   1. Writes /tmp/clipkitty_screenshot_locale.txt so the UI test can pick
#      up the language (via -AppleLanguages inside the test runner).
#   2. Points /tmp/clipkitty_screenshot_db.txt at the matching
#      SyntheticData_<locale>.sqlite (English uses SyntheticData.sqlite).
#   3. Runs xcodebuild test through prepare-screenshot-environment.sh, which
#      resets Mission Control and dock state so captures are reproducible.
#   4. Copies /tmp/clipkitty_<locale>_marketing_*.png into
#      marketing/<locale>/screenshot_{1,2,3}.png.
#
# The result artifact the CI pipeline uploads is the populated marketing/
# directory tree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="ClipKitty"
DERIVED_DATA="$PROJECT_ROOT/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/AppStore/$APP_NAME.app"

SCREENSHOT_LOCALES=(en es zh-Hans zh-Hant ja ko fr de pt-BR ru)

cd "$PROJECT_ROOT"

"$SCRIPT_DIR/patch-demo-items.sh"

# Re-sign the staged AppStore bundle with the local Developer ID identity so
# xcodebuild test can launch it. The nix build leaves it unsigned because
# macOS keychains aren't reachable from the Nix sandbox.
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    SIGNING_IDENTITY="Developer ID Application"
  else
    SIGNING_IDENTITY="-"
  fi
fi
codesign --force --options runtime \
  --sign "$SIGNING_IDENTITY" \
  --entitlements "$PROJECT_ROOT/Sources/MacApp/ClipKitty.appstore.entitlements" \
  "$APP_PATH"

rm -f /tmp/clipkitty_screenshot_locale.txt /tmp/clipkitty_screenshot_db.txt

SKIP_SIGNING_FLAG=""
if [ "${SKIP_SIGNING:-}" = "1" ]; then
  SKIP_SIGNING_FLAG="CODE_SIGNING_ALLOWED=NO"
fi

for locale in "${SCREENSHOT_LOCALES[@]}"; do
  echo "Capturing screenshots for $locale..."
  mkdir -p "marketing/$locale"

  echo "$locale" > /tmp/clipkitty_screenshot_locale.txt
  if [ "$locale" = "en" ]; then
    echo "SyntheticData.sqlite" > /tmp/clipkitty_screenshot_db.txt
  else
    echo "SyntheticData_${locale}.sqlite" > /tmp/clipkitty_screenshot_db.txt
  fi

  log_file="/tmp/clipkitty_marketing_xcodebuild_${locale}.log"
  set +e
  "$SCRIPT_DIR/prepare-screenshot-environment.sh" \
    "cd $PROJECT_ROOT && xcodebuild test \
      -scheme ClipKittyUITests \
      -configuration AppStore \
      -destination \"platform=macOS\" \
      -derivedDataPath DerivedData \
      $SKIP_SIGNING_FLAG \
      -only-testing:ClipKittyUITests/ClipKittyUITests/testTakeMarketingScreenshots \
      > $log_file 2>&1"
  xcodebuild_rc=$?
  set -e
  grep -E '(Test Case|passed|failed)' "$log_file" || true

  if [ "$locale" = "en" ]; then
    expected_screenshot=/tmp/clipkitty_marketing_1_history.png
  else
    expected_screenshot="/tmp/clipkitty_${locale}_marketing_1_history.png"
  fi
  if [ ! -f "$expected_screenshot" ]; then
    echo "::error::No screenshot produced for $locale (xcodebuild rc=$xcodebuild_rc). Log tail:"
    tail -300 "$log_file" || true
    exit 1
  fi

  if [ "$locale" = "en" ]; then
    cp /tmp/clipkitty_marketing_1_history.png "marketing/$locale/screenshot_1.png"
    cp /tmp/clipkitty_marketing_2_search.png "marketing/$locale/screenshot_2.png"
    cp /tmp/clipkitty_marketing_3_filter.png "marketing/$locale/screenshot_3.png"
  else
    cp "/tmp/clipkitty_${locale}_marketing_1_history.png" "marketing/$locale/screenshot_1.png"
    cp "/tmp/clipkitty_${locale}_marketing_2_search.png" "marketing/$locale/screenshot_2.png"
    cp "/tmp/clipkitty_${locale}_marketing_3_filter.png" "marketing/$locale/screenshot_3.png"
  fi
  echo "  $locale screenshots saved to marketing/$locale/"
done

rm -f /tmp/clipkitty_screenshot_locale.txt /tmp/clipkitty_screenshot_db.txt
echo "All localized screenshots complete!"
