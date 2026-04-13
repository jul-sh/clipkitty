#!/usr/bin/env bash
#
# Export the ClipKitty app icon as a 512x512 PNG via Xcode's Icon Composer
# ictool. Used by CI for gh-pages publishing, and by README previews.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

"$ICTOOL" "$PROJECT_ROOT/AppIcon.icon" \
  --export-image \
  --output-file "$PROJECT_ROOT/icon.png" \
  --platform macOS \
  --rendition Default \
  --width 512 \
  --height 512 \
  --scale 1
