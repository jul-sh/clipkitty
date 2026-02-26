#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_FILE="$PROJECT_ROOT/Project.swift"
SECRETS_DIR="$PROJECT_ROOT/secrets"
RECIPIENTS="$SECRETS_DIR/age-recipients.txt"

SPARKLE_BIN=""

usage() {
    echo "Usage: $0 --sparkle-bin <path-to-sparkle-bin-dir>"
    echo ""
    echo "Rotates the Sparkle EdDSA signing key:"
    echo "  1. Generates a new Ed25519 key pair"
    echo "  2. Moves current SUPublicEDKey → SUOldPublicEDKey in Project.swift"
    echo "  3. Sets new public key as SUPublicEDKey"
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
    echo "Error: age CLI not found. Install with: brew install age"
    exit 1
fi

# Get current public key from Project.swift
CURRENT_KEY=$(grep 'SUPublicEDKey' "$PROJECT_FILE" | head -1 | sed 's/.*"\(.*\)".*/\1/' | tr -d ' ')
if [[ -z "$CURRENT_KEY" ]]; then
    echo "Error: Could not find SUPublicEDKey in $PROJECT_FILE"
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

# Update Project.swift: move current key to SUOldPublicEDKey, set new key
if grep -q 'SUOldPublicEDKey' "$PROJECT_FILE"; then
    # Update existing SUOldPublicEDKey
    sed -i '' "s|\"SUOldPublicEDKey\":.*|\"SUOldPublicEDKey\": \"$CURRENT_KEY\",|" "$PROJECT_FILE"
else
    # Add SUOldPublicEDKey after SUPublicEDKey
    sed -i '' "/\"SUPublicEDKey\"/a\\
                \"SUOldPublicEDKey\": \"$CURRENT_KEY\"," "$PROJECT_FILE"
fi

# Update SUPublicEDKey with new key
sed -i '' "s|\"SUPublicEDKey\":.*|\"SUPublicEDKey\": \"$NEW_KEY\",|" "$PROJECT_FILE"

echo ""
echo "Key rotation complete!"
echo "  Old key (SUOldPublicEDKey): $CURRENT_KEY"
echo "  New key (SUPublicEDKey):    $NEW_KEY"
echo ""
echo "Next steps:"
echo "  1. Build and test the app with the new keys"
echo "  2. Commit the changes to Project.swift and secrets/SPARKLE_EDDSA_KEY.age"
echo "  3. After a release with the new key, the old key can eventually be removed"
