#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <SETTING_NAME>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS_FILE="$SCRIPT_DIR/../bazel/clipkitty_build_settings.bzl"
SETTING_NAME="$1"

MATCH=$(
  grep -E "^${SETTING_NAME} = " "$SETTINGS_FILE" \
    | head -1 \
    || true
)

if [[ -z "$MATCH" ]]; then
  echo "Unknown or non-string setting: $SETTING_NAME" >&2
  exit 1
fi

VALUE=$(printf '%s\n' "$MATCH" | sed -E 's/^[^=]+= "(.*)"$/\1/')

printf '%s\n' "$VALUE"
