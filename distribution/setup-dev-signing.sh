#!/bin/bash
# Sets up Developer ID signing certificate in a temporary keychain.
# This enables stable code signing for UI tests (preserves TCC permissions across builds).
#
# Usage:
#   ./distribution/setup-dev-signing.sh           # Create keychain & import cert
#   ./distribution/setup-dev-signing.sh --cleanup  # Remove temporary keychain
#
# Reads encrypted cert secrets from secrets/*.age via keytap.

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

# Remove any stale/locked temp keychains (from this or other projects) that would
# cause errSecInternalComponent during codesign.
purge_stale_temp_keychains

if all_codesigning_identities_available "Developer ID Application" "Apple Development"; then
    echo "Developer ID and Apple Development certificates already available"
    exit 0
fi

KEYCHAIN_PASSWORD=$(openssl rand -hex 16)
P12_PATH=$(mktemp "${TMPDIR:-/tmp}/clipkitty-dev-cert.XXXXXX.p12")
DEV_P12_PATH=$(mktemp "${TMPDIR:-/tmp}/clipkitty-apple-dev-cert.XXXXXX.p12")

cleanup() {
    rm -f "$P12_PATH" "$DEV_P12_PATH"
}

trap cleanup EXIT

create_unlocked_temp_keychain "$KEYCHAIN_PATH" "$KEYCHAIN_PASSWORD"

# Import Developer ID certificate
P12_PASS=$("$SCRIPT_DIR/read-secret.sh" MACOS_P12_PASSWORD)
"$SCRIPT_DIR/read-secret.sh" MACOS_P12_BASE64 | base64 --decode > "$P12_PATH"
security import "$P12_PATH" -k "$KEYCHAIN_PATH" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/productbuild

# Import Apple Development certificate (needed for CloudKit entitlements)
DEV_P12_PASS=$("$SCRIPT_DIR/read-secret.sh" MAC_DEV_P12_PASSWORD)
"$SCRIPT_DIR/read-secret.sh" MAC_DEV_P12_BASE64 | base64 --decode > "$DEV_P12_PATH"
security import "$DEV_P12_PATH" -k "$KEYCHAIN_PATH" -P "$DEV_P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/productbuild

# Allow codesign to access keys without prompt
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null

prepend_keychain_to_search_list "$KEYCHAIN_PATH"

echo "Developer signing keychain ready: $KEYCHAIN_NAME"
