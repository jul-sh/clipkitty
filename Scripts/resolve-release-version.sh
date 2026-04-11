#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version|build-number|embed-label>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_VERSION="$("$SCRIPT_DIR/read-build-setting.sh" MARKETING_VERSION)"

IFS='.' read -r major minor _patch <<< "$BASE_VERSION"
COMMIT_COUNT="$(git -C "$PROJECT_ROOT" rev-list --count HEAD)"
VERSION="${major}.${minor}.${COMMIT_COUNT}"
BUILD_NUMBER="$COMMIT_COUNT"
EMBED_LABEL="ClipKitty_${VERSION}_build_${BUILD_NUMBER}"

case "$1" in
  version)
    printf '%s\n' "$VERSION"
    ;;
  build-number)
    printf '%s\n' "$BUILD_NUMBER"
    ;;
  embed-label)
    printf '%s\n' "$EMBED_LABEL"
    ;;
  *)
    echo "Unknown output '$1'" >&2
    exit 1
    ;;
esac
