#!/bin/bash
# Sets up Developer ID signing certificate in a temporary keychain.
# This enables stable code signing for UI tests (preserves TCC permissions across builds).
#
# Usage:
#   ./distribution/setup-dev-signing.sh           # Create keychain & import cert
#   ./distribution/setup-dev-signing.sh --cleanup  # Remove temporary keychain
#
# Requires AGE_SECRET_KEY environment variable (or reads from macOS Keychain via get-age-key.sh).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KEYCHAIN_NAME="clipkitty_dev.keychain-db"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN_NAME"

if [ "$1" = "--cleanup" ]; then
    security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
    exit 0
fi

# Check if Developer ID signing identity is already usable
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    echo "Developer ID certificate already available"
    exit 0
fi

# Resolve AGE_SECRET_KEY - this is also used as the keychain password
AGE_SECRET_KEY=$("$SCRIPT_DIR/get-age-key.sh") || exit 1

# Use a hash of the AGE key as the keychain password (keychains have length limits)
KEYCHAIN_PASSWORD=$(printf '%s' "$AGE_SECRET_KEY" | shasum -a 256 | cut -d' ' -f1)

# If keychain exists, try to unlock it with the derived password
if [ -f "$KEYCHAIN_PATH" ]; then
    if security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" 2>/dev/null; then
        echo "Developer signing keychain unlocked: $KEYCHAIN_NAME"
        exit 0
    fi
    # Password didn't work (AGE key changed?), remove stale keychain
    security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
fi

# Decrypt secrets
printf '%s' "$AGE_SECRET_KEY" > /tmp/_ck_age.txt
P12_PASS=$(age -d -i /tmp/_ck_age.txt "$PROJECT_ROOT/secrets/MACOS_P12_PASSWORD.age")
age -d -i /tmp/_ck_age.txt "$PROJECT_ROOT/secrets/MACOS_P12_BASE64.age" \
    | base64 --decode > /tmp/_ck_dev.p12
rm -f /tmp/_ck_age.txt

# Create temporary keychain with derived password
security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -t 3600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

# Import certificate
security import /tmp/_ck_dev.p12 -k "$KEYCHAIN_PATH" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/productbuild
rm -f /tmp/_ck_dev.p12

# Allow codesign to access keys without prompt
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null

# Add to keychain search list (prepend so our certs are found first)
EXISTING=$(security list-keychains -d user | tr -d '" ' | tr '\n' ' ')
security list-keychains -d user -s "$KEYCHAIN_PATH" $EXISTING

echo "Developer signing keychain ready: $KEYCHAIN_NAME"
