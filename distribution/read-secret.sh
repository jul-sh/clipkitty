#!/bin/bash
# Decrypts a secret from secrets/<NAME>.age.
# Uses keytap locally; falls back to age + AGE_SECRET_KEY in CI.
# On first local run, caches the age key in macOS Keychain so subsequent
# runs don't require keytap (biometric/PIN) if the keychain is unlocked.
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

KEYCHAIN_SERVICE="keytap"
# Use project-specific account to avoid cross-project key collisions.
# Different projects have different age recipients, so each needs its own cached key.
PROJECT_NAME="$(basename "$PROJECT_ROOT")"
KEYCHAIN_ACCOUNT="AGE_SECRET_KEY_${PROJECT_NAME}"

# Try to read the age key from macOS Keychain (silent fail if locked or missing)
try_keychain() {
    security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null
}

# Cache the age key into macOS Keychain for future runs
cache_to_keychain() {
    local age_key="$1"
    # Update if exists, add if not
    if ! security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w "$age_key" 2>/dev/null; then
        echo "Warning: Failed to cache age key in keychain — keytap will be needed next run" >&2
    fi
}

if [ -n "${AGE_SECRET_KEY:-}" ]; then
    # CI path: use the env var directly
    echo "$AGE_SECRET_KEY" | age -d -i - "$SECRET_PATH"
elif AGE_KEY="$(try_keychain)" && echo "$AGE_KEY" | age -d -i - "$SECRET_PATH" 2>/dev/null; then
    # Keychain hit and key matches recipients — output already produced above
    :
elif command -v keytap &>/dev/null; then
    # First run / keychain locked: get key from keytap, decrypt, and cache
    AGE_KEY="$(keytap reveal clipkitty --format age)"
    echo "$AGE_KEY" | age -d -i - "$SECRET_PATH"
    cache_to_keychain "$AGE_KEY"
else
    echo "Error: Neither AGE_SECRET_KEY, keychain, nor keytap available" >&2
    exit 1
fi
