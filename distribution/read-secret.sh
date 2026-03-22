#!/bin/bash
# Decrypts a secret from secrets/<NAME>.age.
# Uses keytap locally; falls back to age + AGE_SECRET_KEY in CI.
#
# Usage:
#   ./distribution/read-secret.sh SECRET_NAME

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 SECRET_NAME" >&2
    exit 1
fi

SECRET_NAME="${1%.age}"
SECRET_PATH="$PROJECT_ROOT/secrets/$SECRET_NAME.age"

if [ ! -f "$SECRET_PATH" ]; then
    echo "Error: Secret file not found: $SECRET_PATH" >&2
    exit 1
fi

if [ -n "${AGE_SECRET_KEY:-}" ]; then
    echo "$AGE_SECRET_KEY" | age -d -i - "$SECRET_PATH"
elif command -v keytap &>/dev/null; then
    keytap decrypt "$SECRET_PATH" --key clipkitty
else
    echo "Error: Neither AGE_SECRET_KEY nor keytap available" >&2
    exit 1
fi
