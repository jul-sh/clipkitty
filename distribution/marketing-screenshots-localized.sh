#!/usr/bin/env bash
#
# Capture localized App Store marketing screenshots via the ClipKittyUITests
# testTakeMarketingScreenshots UI test. Assumes ClipKitty.xcworkspace is
# already materialised (run Scripts/nix-generate.sh).
#
# Uses the Debug config (same as Run UI Tests) so the test host app is
# built once and reused across locales. Screenshots are about rendered UI
# content, not the distribution variant — AppStore config would force a
# universal rebuild that conflicts with the staged nix-built .app under
# DerivedData/Build/Products/AppStore/.
#
# The test runs in its own DerivedData dir (DerivedData-marketing) so it
# cannot disturb the staged AppStore .app that downstream upload steps
# depend on.
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
MARKETING_DERIVED_DATA="$PROJECT_ROOT/DerivedData-marketing"

SCREENSHOT_LOCALES=(en es zh-Hans zh-Hant ja ko fr de pt-BR ru)

cd "$PROJECT_ROOT"

"$SCRIPT_DIR/patch-demo-items.sh"

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
      -workspace $APP_NAME.xcworkspace \
      -scheme ClipKittyUITests \
      -destination \"platform=macOS\" \
      -derivedDataPath $MARKETING_DERIVED_DATA \
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
