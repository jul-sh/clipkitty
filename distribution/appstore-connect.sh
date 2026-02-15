#!/bin/bash
# Upload builds and metadata to App Store Connect using the ASC CLI
# Usage: ./appstore-connect.sh <release|upload|metadata|submit>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# App Store Connect constants (from former fastlane/Appfile)
APP_APPLE_ID="6759137247"
BUNDLE_ID="com.eviljuliette.clipkitty"

# Metadata paths
METADATA_DIR="$SCRIPT_DIR/metadata"
SCREENSHOTS_DIR="$PROJECT_ROOT/marketing"

# Binary location
PKG_PATH="$PROJECT_ROOT/ClipKitty.pkg"

# --- Authentication ---
# Decode the base64-encoded private key to a temp file.
# asc CLI reads ASC_KEY_ID, ASC_ISSUER_ID env vars and the key file path.
setup_auth() {
    if [[ -z "${ASC_PRIVATE_KEY_B64:-}" ]]; then
        echo "Error: ASC_PRIVATE_KEY_B64 env var is required" >&2
        exit 1
    fi
    if [[ -z "${ASC_KEY_ID:-}" ]]; then
        echo "Error: ASC_KEY_ID env var is required" >&2
        exit 1
    fi
    if [[ -z "${ASC_ISSUER_ID:-}" ]]; then
        echo "Error: ASC_ISSUER_ID env var is required" >&2
        exit 1
    fi

    ASC_KEY_FILE="$(mktemp -t asc_key.XXXXXX).p8"
    CLEANUP_DIR=""
    echo "$ASC_PRIVATE_KEY_B64" | base64 --decode > "$ASC_KEY_FILE"
    chmod 600 "$ASC_KEY_FILE"
    export ASC_PRIVATE_KEY_PATH="$ASC_KEY_FILE"
    trap 'rm -f "$ASC_KEY_FILE"; [[ -n "${CLEANUP_DIR:-}" ]] && rm -rf "$CLEANUP_DIR"' EXIT

    echo "Authenticated with key ID: $ASC_KEY_ID"
}

# --- Helpers ---

# Look up the editable App Store version ID (PREPARE_FOR_SUBMISSION state).
# Falls back to the most recent version if none is editable.
get_version_id() {
    local version_id
    version_id=$(asc versions list --app "$APP_APPLE_ID" --platform MAC_OS \
        --state PREPARE_FOR_SUBMISSION --output json --pretty=false \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'])" 2>/dev/null) || true

    if [[ -z "$version_id" ]]; then
        version_id=$(asc versions list --app "$APP_APPLE_ID" --platform MAC_OS \
            --output json --pretty=false \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'])" 2>/dev/null) || true
    fi

    if [[ -z "$version_id" ]]; then
        echo "Error: Could not determine App Store version ID" >&2
        exit 1
    fi

    echo "$version_id"
}

# --- Subcommands ---

upload_binary() {
    echo "=== Uploading binary to App Store Connect ==="
    if [[ ! -f "$PKG_PATH" ]]; then
        echo "Error: Package not found at $PKG_PATH" >&2
        exit 1
    fi

    asc builds upload \
        --app "$APP_APPLE_ID" \
        --pkg "$PKG_PATH" \
        --version "${VERSION:-1.0.0}" \
        --build-number "${BUILD_NUMBER:-$(git -C "$PROJECT_ROOT" rev-list --count HEAD)}" \
        --wait

    echo "Binary uploaded successfully."
}

upload_metadata_and_screenshots() {
    echo "=== Uploading metadata & screenshots to App Store Connect ==="

    local version_id
    version_id=$(get_version_id)
    echo "Target version ID: $version_id"

    # Assemble a fastlane-style directory for asc migrate import.
    # It expects: <dir>/metadata/... and optionally <dir>/screenshots/en-US/...
    local fastlane_dir
    fastlane_dir=$(mktemp -d)
    CLEANUP_DIR="$fastlane_dir"

    ln -s "$METADATA_DIR" "$fastlane_dir/metadata"

    if compgen -G "$SCREENSHOTS_DIR/screenshot_*.png" > /dev/null; then
        mkdir -p "$fastlane_dir/screenshots/en-US"
        cp "$SCREENSHOTS_DIR"/screenshot_*.png "$fastlane_dir/screenshots/en-US/"
        echo "Including screenshots from $SCREENSHOTS_DIR"
    else
        echo "Warning: No screenshots found in $SCREENSHOTS_DIR (skipping)"
    fi

    asc migrate import \
        --app "$APP_APPLE_ID" \
        --version-id "$version_id" \
        --fastlane-dir "$fastlane_dir"

    rm -rf "$fastlane_dir"
    CLEANUP_DIR=""

    echo "Metadata uploaded successfully."
}

submit_for_review() {
    echo "=== Submitting build for App Review ==="

    asc submit create \
        --app "$APP_APPLE_ID" \
        --platform MAC_OS \
        --version "${VERSION:-1.0.0}" \
        --confirm

    echo "Build submitted for review."
}

# --- Main ---

COMMAND="${1:-}"

if [[ -z "$COMMAND" ]]; then
    echo "Usage: $0 <release|upload|metadata|submit>" >&2
    exit 1
fi

setup_auth

case "$COMMAND" in
    release)
        upload_binary
        upload_metadata_and_screenshots
        ;;
    upload)
        upload_binary
        ;;
    metadata)
        upload_metadata_and_screenshots
        ;;
    submit)
        submit_for_review
        ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        echo "Usage: $0 <release|upload|metadata|submit>" >&2
        exit 1
        ;;
esac

echo "=== Done ==="
