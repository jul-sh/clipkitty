#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETTINGS_FILE="$PROJECT_ROOT/bazel/clipkitty_build_settings.bzl"
SECRETS_DIR="$PROJECT_ROOT/secrets"
RECIPIENTS="$SECRETS_DIR/age-recipients.txt"

SPARKLE_BIN=""

usage() {
    echo "Usage: $0 --sparkle-bin <path-to-sparkle-bin-dir>"
    echo ""
    echo "Rotates the Sparkle EdDSA signing key:"
    echo "  1. Generates a new Ed25519 key pair"
    echo "  2. Moves current SPARKLE_PUBLIC_KEY → SPARKLE_OLD_PUBLIC_KEY in bazel/clipkitty_build_settings.bzl"
    echo "  3. Sets new public key as SPARKLE_PUBLIC_KEY"
    echo "  4. Encrypts new private key to secrets/SPARKLE_EDDSA_KEY.age"
    echo ""
    echo "Prerequisites:"
    echo "  - age CLI installed"
    echo "  - Sparkle CLI tools (from Sparkle release tarball)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --sparkle-bin) SPARKLE_BIN="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$SPARKLE_BIN" ]]; then
    echo "Error: --sparkle-bin is required"
    usage
fi

GENERATE_KEYS="$SPARKLE_BIN/generate_keys"
if [[ ! -x "$GENERATE_KEYS" ]]; then
    echo "Error: generate_keys not found at $GENERATE_KEYS"
    exit 1
fi

if ! command -v age &>/dev/null; then
    echo "Error: age CLI not found. Enter the Nix dev shell (nix develop) or run: nix profile install nixpkgs#age"
    exit 1
fi

# Get current public key from Bazel build settings
CURRENT_KEY=$(grep '^SPARKLE_PUBLIC_KEY = ' "$SETTINGS_FILE" | head -1 | sed 's/.*"\(.*\)".*/\1/' | tr -d ' ')
if [[ -z "$CURRENT_KEY" ]]; then
    echo "Error: Could not find SPARKLE_PUBLIC_KEY in $SETTINGS_FILE"
    exit 1
fi
echo "Current public key: $CURRENT_KEY"

# Generate new key pair (uses a temporary keychain account to avoid overwriting)
TEMP_ACCOUNT="sparkle-rotate-$$"
"$GENERATE_KEYS" --account "$TEMP_ACCOUNT" 2>/dev/null
NEW_KEY=$("$GENERATE_KEYS" --account "$TEMP_ACCOUNT" -p 2>/dev/null)
echo "New public key: $NEW_KEY"

# Export and encrypt new private key
TEMP_KEY=$(mktemp)
"$GENERATE_KEYS" --account "$TEMP_ACCOUNT" -x "$TEMP_KEY" 2>/dev/null
age -R "$RECIPIENTS" -o "$SECRETS_DIR/SPARKLE_EDDSA_KEY.age" < "$TEMP_KEY"
rm -f "$TEMP_KEY"
echo "Private key encrypted to secrets/SPARKLE_EDDSA_KEY.age"

# Update Bazel build settings: move current key to SPARKLE_OLD_PUBLIC_KEY, set new key
escape_sed_replacement() {
    printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

CURRENT_KEY_ESCAPED=$(escape_sed_replacement "$CURRENT_KEY")
NEW_KEY_ESCAPED=$(escape_sed_replacement "$NEW_KEY")

sed -i '' \
    "s|^SPARKLE_OLD_PUBLIC_KEY = \".*\"$|SPARKLE_OLD_PUBLIC_KEY = \"$CURRENT_KEY_ESCAPED\"|" \
    "$SETTINGS_FILE"
sed -i '' \
    "s|^SPARKLE_PUBLIC_KEY = \".*\"$|SPARKLE_PUBLIC_KEY = \"$NEW_KEY_ESCAPED\"|" \
    "$SETTINGS_FILE"

echo ""
echo "Key rotation complete!"
echo "  Old key (SPARKLE_OLD_PUBLIC_KEY): $CURRENT_KEY"
echo "  New key (SPARKLE_PUBLIC_KEY):     $NEW_KEY"
echo ""
echo "Next steps:"
echo "  1. Build and test the app with the new keys"
echo "  2. Commit the changes to bazel/clipkitty_build_settings.bzl and secrets/SPARKLE_EDDSA_KEY.age"
echo "  3. After a release with the new key, the old key can eventually be removed"
