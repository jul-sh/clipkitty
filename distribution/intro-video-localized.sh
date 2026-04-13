#!/usr/bin/env bash
#
# Record localized App Store intro videos for every supported locale.
#
# For each locale this script:
#   1. Copies the matching SyntheticData_<locale>.sqlite into
#      SyntheticData_video.sqlite (en uses the plain SyntheticData.sqlite).
#   2. Re-runs rust-data-gen with --video-only so the DB contains the
#      sequenced items the recording test drives.
#   3. Injects the locale-specific demo images via inject-images.py.
#   4. Records marketing/<locale>/intro_video.mov through
#      record-preview-video.sh (wrapped by prepare-screenshot-environment.sh
#      so dock/window state is reset before each capture).
#
# Prerequisites:
#   * ClipKitty.xcworkspace must be materialised (Scripts/nix-generate.sh).
#   * The Nix wrapper (Scripts/run-in-nix.sh) must be available for cargo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$SCRIPT_DIR"

NIX_SHELL=("$PROJECT_ROOT/Scripts/run-in-nix.sh" -c)

CARGO_LOCKED=""
if [ "${LOCKED:-}" = "1" ]; then
  CARGO_LOCKED="--locked"
fi

SCREENSHOT_LOCALES=(en es zh-Hans zh-Hant ja ko fr de pt-BR ru)

rm -f /tmp/clipkitty_screenshot_locale.txt

for locale in "${SCREENSHOT_LOCALES[@]}"; do
  echo "=== Recording intro video for $locale ==="
  echo "$locale" > /tmp/clipkitty_screenshot_locale.txt

  if [ "$locale" = "en" ]; then
    cp "$DIST_DIR/SyntheticData.sqlite" "$DIST_DIR/SyntheticData_video.sqlite"
  else
    cp "$DIST_DIR/SyntheticData_${locale}.sqlite" "$DIST_DIR/SyntheticData_video.sqlite"
  fi

  "${NIX_SHELL[@]}" "cd $PROJECT_ROOT && cargo run $CARGO_LOCKED -p rust-data-gen --release -- --video-only --locale $locale --db-path $DIST_DIR/SyntheticData_video.sqlite"
  python3 "$DIST_DIR/inject-images.py" "$DIST_DIR/SyntheticData_video.sqlite" "$locale"

  mkdir -p "$PROJECT_ROOT/marketing/$locale"
  "$DIST_DIR/prepare-screenshot-environment.sh" \
    "$DIST_DIR/record-preview-video.sh \
      --db SyntheticData_video.sqlite \
      --output $locale/intro_video.mov \
      --duration 30"

  echo "  $locale video saved to marketing/$locale/intro_video.mov"
done

rm -f /tmp/clipkitty_screenshot_locale.txt
echo "All localized intro videos complete!"
