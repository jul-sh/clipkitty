#!/bin/bash
# Sets up the Mac Development provisioning profile for local builds.
# It restores the cached encrypted profile when possible, and otherwise uses
# the ASC CLI to register this Mac and regenerate a fresh profile secret.
#
# Usage:
#   ./distribution/setup-dev-provisioning.sh
#
# Requires:
#   - asc CLI (`./distribution/install-deps.sh`)
#   - age secrets for ASC auth and MAC_DEV_P12_*

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
PROFILE_NAME="ClipKitty Mac Development"

# Check if a valid Mac Development profile is already installed
check_existing_profile() {
    for f in "$PROFILE_DIR"/*.provisionprofile; do
        [ -f "$f" ] || continue
        local plist
        plist=$(security cms -D -i "$f" 2>/dev/null) || continue
        local name
        name=$(echo "$plist" | plutil -extract Name raw - -o - 2>/dev/null) || continue
        if [ "$name" = "$PROFILE_NAME" ]; then
            # Check expiry using ruby for portable date parsing
            local expiry
            expiry=$(echo "$plist" | plutil -extract ExpirationDate raw - -o - 2>/dev/null) || continue
            if ruby -e 'require "time"; exit(Time.parse(ARGV[0]) > Time.now ? 0 : 1)' "$expiry" 2>/dev/null; then
                echo "Mac Development profile already installed and valid"
                return 0
            fi
        fi
    done
    return 1
}

if check_existing_profile; then
    exit 0
fi

echo "Setting up Mac Development provisioning profile..."

# Try installing from .age secret first (fast path, no API calls needed)
PROFILE_SECRET="$PROJECT_ROOT/secrets/MAC_DEV_PROVISIONING_PROFILE_BASE64.age"
if [ -f "$PROFILE_SECRET" ]; then
    echo "Installing provisioning profile from .age secret..."
    TMP_PROFILE=$(mktemp "${TMPDIR:-/tmp}/clipkitty-profile.XXXXXX")
    "$SCRIPT_DIR/read-secret.sh" MAC_DEV_PROVISIONING_PROFILE_BASE64 | base64 --decode > "$TMP_PROFILE"
    PLIST=$(security cms -D -i "$TMP_PROFILE" 2>/dev/null) || true
    PP_UUID=$(echo "$PLIST" | plutil -extract UUID raw - -o - 2>/dev/null) || true
    # Check if this device is in the profile's provisioned devices list
    MAC_UDID=$(system_profiler SPHardwareDataType 2>/dev/null | awk '/Provisioning UDID/{print $3}')
    DEVICE_IN_PROFILE=$(echo "$PLIST" | ruby -e '
        require "rexml/document"
        doc = REXML::Document.new(STDIN.read)
        devs = doc.elements.to_a("//dict/key[text()=\"ProvisionedDevices\"]/../array/string").map(&:text)
        puts "yes" if devs.include?(ARGV[0])
    ' "$MAC_UDID" 2>/dev/null) || true
    if [ -n "$PP_UUID" ] && [ "$DEVICE_IN_PROFILE" = "yes" ]; then
        mkdir -p "$PROFILE_DIR"
        cp "$TMP_PROFILE" "$PROFILE_DIR/$PP_UUID.provisionprofile"
        rm -f "$TMP_PROFILE"
        echo "Provisioning profile installed from .age: $PP_UUID"
        exit 0
    fi
    rm -f "$TMP_PROFILE"
    echo "Device not in .age profile, falling back to API..."
fi

if ! command -v asc >/dev/null 2>&1; then
    echo "Error: asc CLI is required to regenerate the Mac Development provisioning profile." >&2
    echo "Run ./distribution/install-deps.sh and try again." >&2
    exit 1
fi

echo "Regenerating Mac Development provisioning profile via ASC CLI..."
"$SCRIPT_DIR/regenerate-provisioning-secrets.sh" --dev-only
