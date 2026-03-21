#!/bin/bash
# Sets up App Store signing certificates in a temporary keychain.
# This avoids interactive keychain password prompts for codesign/productbuild.
#
# Usage:
#   ./distribution/setup-signing.sh           # Create keychain & import certs
#   ./distribution/setup-signing.sh --cleanup  # Remove temporary keychain
#
# Reads encrypted cert secrets from secrets/*.age via tapkey.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYCHAIN_NAME="clipkitty_signing.keychain-db"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN_NAME"

source "$SCRIPT_DIR/signing-common.sh"

if [ "${1:-}" = "--cleanup" ]; then
    delete_temp_keychain "$KEYCHAIN_PATH"
    exit 0
fi

# Repo-managed temp keychains are disposable. Never try to unlock a stale one.
delete_temp_keychain "$KEYCHAIN_PATH"

if all_codesigning_identities_available \
    "3rd Party Mac Developer Application" \
    "3rd Party Mac Developer Installer"; then
    echo "Signing certificates already available"
    exit 0
fi

P12_PASS=$("$SCRIPT_DIR/read-secret.sh" P12_PASSWORD)
APP_P12_PATH=$(mktemp "${TMPDIR:-/tmp}/clipkitty-app-cert.XXXXXX.p12")
INST_P12_PATH=$(mktemp "${TMPDIR:-/tmp}/clipkitty-inst-cert.XXXXXX.p12")
WWDR_CERT=""

cleanup() {
    rm -f "$APP_P12_PATH" "$INST_P12_PATH"
    if [ -n "$WWDR_CERT" ]; then
        rm -f "$WWDR_CERT"
    fi
}

trap cleanup EXIT

"$SCRIPT_DIR/read-secret.sh" APPSTORE_APP_CERT_BASE64 | base64 --decode > "$APP_P12_PATH"
"$SCRIPT_DIR/read-secret.sh" APPSTORE_CERT_BASE64 | base64 --decode > "$INST_P12_PATH"

# Create temporary keychain with a fresh per-run password.
KEYCHAIN_PASSWORD=$(openssl rand -hex 16)
create_unlocked_temp_keychain "$KEYCHAIN_PATH" "$KEYCHAIN_PASSWORD"

# Install Apple WWDR intermediate certificate (needed for cert chain validation)
if ! security find-certificate -c "Apple Worldwide Developer Relations Certification Authority" /Library/Keychains/System.keychain >/dev/null 2>&1; then
    WWDR_CERT=$(mktemp "${TMPDIR:-/tmp}/clipkitty-wwdr.XXXXXX.cer")
    curl -sLo "$WWDR_CERT" https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
    sudo security add-trusted-cert -d -r unspecified -k /Library/Keychains/System.keychain "$WWDR_CERT"
fi

# Import certificates
security import "$APP_P12_PATH" -k "$KEYCHAIN_PATH" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/productbuild
security import "$INST_P12_PATH" -k "$KEYCHAIN_PATH" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/productbuild

# Remove duplicate Application cert (installer P12 bundles an extra one)
HASHES=$(security find-certificate -a -c "3rd Party Mac Developer Application" -Z \
    "$KEYCHAIN_PATH" 2>/dev/null | grep "SHA-1" | awk '{print $NF}')
echo "$HASHES" | tail -n +2 | while read -r HASH; do
    security delete-certificate -Z "$HASH" "$KEYCHAIN_PATH" 2>/dev/null || true
done

# Allow codesign/productbuild to access keys without prompt
security set-key-partition-list \
    -S apple-tool:,apple:,codesign:,productbuild: \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null

prepend_keychain_to_search_list "$KEYCHAIN_PATH"

echo "Signing keychain ready: $KEYCHAIN_NAME"
