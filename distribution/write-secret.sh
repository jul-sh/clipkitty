#!/bin/bash
# Encrypts bytes into secrets/<NAME>.age using the repo recipients file.
#
# Usage:
#   echo -n "secret" | ./distribution/write-secret.sh SECRET_NAME
#   ./distribution/write-secret.sh SECRET_NAME --from-file ./path/to/file
#
# Notes:
#   - This script encrypts exactly the bytes it receives.
#   - Callers should base64-encode binary data first if they want a *_BASE64 secret.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_DIR="$PROJECT_ROOT/secrets"
RECIPIENTS_FILE="$SECRETS_DIR/age-recipients.txt"

usage() {
    echo "Usage: $0 SECRET_NAME [--from-file PATH]" >&2
    exit 1
}

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
    usage
fi

if ! command -v age >/dev/null 2>&1; then
    echo "Error: age is required to write encrypted secrets" >&2
    exit 1
fi

if [ ! -f "$RECIPIENTS_FILE" ]; then
    echo "Error: Recipients file not found: $RECIPIENTS_FILE" >&2
    exit 1
fi

SECRET_NAME="${1%.age}"
OUTPUT_PATH="$SECRETS_DIR/$SECRET_NAME.age"

TMP_INPUT="$(mktemp "${TMPDIR:-/tmp}/clipkitty-secret-input.XXXXXX")"
TMP_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/clipkitty-secret-output.XXXXXX")"

cleanup() {
    rm -f "$TMP_INPUT" "$TMP_OUTPUT"
}

trap cleanup EXIT

case "${2:-}" in
    "")
        cat > "$TMP_INPUT"
        ;;
    --from-file)
        [ "$#" -eq 3 ] || usage
        cp "$3" "$TMP_INPUT"
        ;;
    *)
        usage
        ;;
esac

age -R "$RECIPIENTS_FILE" -o "$TMP_OUTPUT" "$TMP_INPUT"
mv "$TMP_OUTPUT" "$OUTPUT_PATH"

echo "$OUTPUT_PATH"
