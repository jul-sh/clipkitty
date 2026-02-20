#!/bin/bash
# Sets up App Store signing certificates in a temporary keychain.
# This avoids interactive keychain password prompts for codesign/productbuild.
#
# Usage:
#   ./distribution/setup-signing.sh           # Create keychain & import certs
#   ./distribution/setup-signing.sh --cleanup  # Remove temporary keychain
#
# Requires AGE_SECRET_KEY environment variable (or reads from macOS Keychain).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KEYCHAIN_NAME="clipkitty_signing.keychain-db"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN_NAME"

if [ "$1" = "--cleanup" ]; then
    security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
    exit 0
fi

# Check if signing identities are already usable (CI case)
if security find-identity -v -p codesigning 2>/dev/null | grep -q "3rd Party Mac Developer Application" && \
   security find-identity -v 2>/dev/null | grep -q "3rd Party Mac Developer Installer"; then
    # Test that productbuild can actually access the key (non-interactive)
    # by checking if the keychain is a temp one (not login)
    if security list-keychains -d user 2>/dev/null | grep -q "signing_temp\|clipkitty_signing"; then
        echo "Signing certificates already available"
        exit 0
    fi
fi

# Resolve AGE_SECRET_KEY
if [ -z "$AGE_SECRET_KEY" ]; then
    AGE_SECRET_KEY=$(security find-generic-password -s clipkitty -a AGE_SECRET_KEY -w 2>/dev/null) || true
fi
if [ -z "$AGE_SECRET_KEY" ]; then
    echo "Error: AGE_SECRET_KEY not set and not found in Keychain" >&2
    exit 1
fi

# Decrypt secrets
printf '%s' "$AGE_SECRET_KEY" > /tmp/_ck_age.txt
P12_PASS=$(age -d -i /tmp/_ck_age.txt "$PROJECT_ROOT/secrets/P12_PASSWORD.age")
age -d -i /tmp/_ck_age.txt "$PROJECT_ROOT/secrets/APPSTORE_APP_CERT_BASE64.age" \
    | base64 --decode > /tmp/_ck_app.p12
age -d -i /tmp/_ck_age.txt "$PROJECT_ROOT/secrets/APPSTORE_CERT_BASE64.age" \
    | base64 --decode > /tmp/_ck_inst.p12
rm -f /tmp/_ck_age.txt

# Create temporary keychain with known password
KEYCHAIN_PASSWORD=$(openssl rand -hex 16)
security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -t 3600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

# Import certificates
security import /tmp/_ck_app.p12 -k "$KEYCHAIN_PATH" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/productbuild
security import /tmp/_ck_inst.p12 -k "$KEYCHAIN_PATH" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/productbuild
rm -f /tmp/_ck_app.p12 /tmp/_ck_inst.p12

# Remove duplicate Application cert (installer P12 bundles an extra one)
HASHES=$(security find-certificate -a -c "3rd Party Mac Developer Application" -Z \
    "$KEYCHAIN_PATH" 2>/dev/null | grep "SHA-1" | awk '{print $NF}')
FIRST=$(echo "$HASHES" | head -1)
echo "$HASHES" | tail -n +2 | while read -r HASH; do
    security delete-certificate -Z "$HASH" "$KEYCHAIN_PATH" 2>/dev/null || true
done

# Allow codesign/productbuild to access keys without prompt
security set-key-partition-list \
    -S apple-tool:,apple:,codesign:,productbuild: \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null

# Add to keychain search list (prepend so our certs are found first)
EXISTING=$(security list-keychains -d user | tr -d '" ' | tr '\n' ' ')
security list-keychains -d user -s "$KEYCHAIN_PATH" $EXISTING

echo "Signing keychain ready: $KEYCHAIN_NAME"
