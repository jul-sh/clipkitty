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
  echo "Unknown setting: $SETTING_NAME" >&2
  exit 1
fi

# Only extract simple quoted string values (e.g. FOO = "bar").
# Reject list values, references, or other non-string assignments.
if ! printf '%s\n' "$MATCH" | grep -qE '^[^=]+= ".*"$'; then
  echo "Setting $SETTING_NAME is not a simple quoted string" >&2
  exit 1
fi

VALUE=$(printf '%s\n' "$MATCH" | sed -E 's/^[^=]+= "(.*)"$/\1/')

printf '%s\n' "$VALUE"
