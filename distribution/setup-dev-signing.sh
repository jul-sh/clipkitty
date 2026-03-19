#!/bin/bash
# Sets up Developer ID signing certificate in a temporary keychain.
# This enables stable code signing for UI tests (preserves TCC permissions across builds).
#
# Usage:
#   ./distribution/setup-dev-signing.sh           # Create keychain & import cert
#   ./distribution/setup-dev-signing.sh --cleanup  # Remove temporary keychain
#
# Reads encrypted cert secrets from secrets/*.age using the age key from
# the login keychain (or AGE_SECRET_KEY in CI).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYCHAIN_NAME="clipkitty_dev.keychain-db"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN_NAME"

source "$SCRIPT_DIR/signing-common.sh"

if [ "${1:-}" = "--cleanup" ]; then
    delete_temp_keychain "$KEYCHAIN_PATH"
    exit 0
fi

# Repo-managed temp keychains are disposable. Never try to unlock a stale one.
delete_temp_keychain "$KEYCHAIN_PATH"

if all_codesigning_identities_available "Developer ID Application"; then
    echo "Developer ID certificate already available"
    exit 0
fi

AGE_SECRET_KEY=$("$SCRIPT_DIR/get-age-key.sh")
export AGE_SECRET_KEY

KEYCHAIN_PASSWORD=$(openssl rand -hex 16)
P12_PATH=$(mktemp "${TMPDIR:-/tmp}/clipkitty-dev-cert.XXXXXX.p12")

cleanup() {
    rm -f "$P12_PATH"
}

trap cleanup EXIT

P12_PASS=$("$SCRIPT_DIR/read-secret.sh" MACOS_P12_PASSWORD)
"$SCRIPT_DIR/read-secret.sh" MACOS_P12_BASE64 | base64 --decode > "$P12_PATH"

create_unlocked_temp_keychain "$KEYCHAIN_PATH" "$KEYCHAIN_PASSWORD"

# Import certificate
security import "$P12_PATH" -k "$KEYCHAIN_PATH" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/productbuild

# Allow codesign to access keys without prompt
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null

prepend_keychain_to_search_list "$KEYCHAIN_PATH"

echo "Developer signing keychain ready: $KEYCHAIN_NAME"
