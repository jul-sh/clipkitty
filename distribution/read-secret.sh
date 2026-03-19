#!/bin/bash

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

AGE_SECRET_KEY=$("$SCRIPT_DIR/get-age-key.sh")
age -d -i <(printf '%s' "$AGE_SECRET_KEY") "$SECRET_PATH"
