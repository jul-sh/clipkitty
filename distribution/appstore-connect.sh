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
# Decode the base64-encoded private key to a temp file for asc CLI
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
    echo "$ASC_PRIVATE_KEY_B64" | base64 --decode > "$ASC_KEY_FILE"
    export ASC_KEY_FILE
    trap 'rm -f "$ASC_KEY_FILE"' EXIT

    echo "Authenticated with key ID: $ASC_KEY_ID"
}

# --- Subcommands ---

upload_binary() {
    echo "=== Uploading binary to App Store Connect ==="
    if [[ ! -f "$PKG_PATH" ]]; then
        echo "Error: Package not found at $PKG_PATH" >&2
        exit 1
    fi

    xcrun altool --upload-package "$PKG_PATH" \
        --type macos \
        --apple-id "$APP_APPLE_ID" \
        --bundle-id "$BUNDLE_ID" \
        --bundle-version "${BUILD_NUMBER:-$(git -C "$PROJECT_ROOT" rev-list --count HEAD)}" \
        --bundle-short-version-string "${VERSION:-1.0.0}" \
        --apiKey "$ASC_KEY_ID" \
        --apiIssuer "$ASC_ISSUER_ID" \
        --apiPrivateKey "$ASC_KEY_FILE"

    echo "Binary uploaded successfully."
}

upload_metadata() {
    echo "=== Uploading metadata to App Store Connect ==="

    asc apps metadata set \
        --app-id "$APP_APPLE_ID" \
        --locale en-US \
        --name "$(cat "$METADATA_DIR/en-US/name.txt")" \
        --subtitle "$(cat "$METADATA_DIR/en-US/subtitle.txt")" \
        --description "$(cat "$METADATA_DIR/en-US/description.txt")" \
        --keywords "$(cat "$METADATA_DIR/en-US/keywords.txt")" \
        --promotional-text "$(cat "$METADATA_DIR/en-US/promotional_text.txt")" \
        --marketing-url "$(cat "$METADATA_DIR/en-US/marketing_url.txt")" \
        --support-url "$(cat "$METADATA_DIR/en-US/support_url.txt")" \
        --privacy-url "$(cat "$METADATA_DIR/en-US/privacy_url.txt")" \
        --api-key "$ASC_KEY_ID" \
        --issuer-id "$ASC_ISSUER_ID" \
        --private-key-path "$ASC_KEY_FILE"

    echo "Metadata uploaded successfully."
}

upload_screenshots() {
    echo "=== Uploading screenshots to App Store Connect ==="

    local screenshots_found=0
    for screenshot in "$SCREENSHOTS_DIR"/screenshot_*.png; do
        if [[ -f "$screenshot" ]]; then
            echo "Uploading: $(basename "$screenshot")"
            asc apps screenshots upload \
                --app-id "$APP_APPLE_ID" \
                --locale en-US \
                --display-type APP_DESKTOP \
                --file "$screenshot" \
                --api-key "$ASC_KEY_ID" \
                --issuer-id "$ASC_ISSUER_ID" \
                --private-key-path "$ASC_KEY_FILE"
            screenshots_found=1
        fi
    done

    if [[ $screenshots_found -eq 0 ]]; then
        echo "Warning: No screenshots found in $SCREENSHOTS_DIR"
    else
        echo "Screenshots uploaded successfully."
    fi
}

submit_for_review() {
    echo "=== Submitting build for App Review ==="

    asc submit create \
        --app-id "$APP_APPLE_ID" \
        --api-key "$ASC_KEY_ID" \
        --issuer-id "$ASC_ISSUER_ID" \
        --private-key-path "$ASC_KEY_FILE"

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
        upload_metadata
        upload_screenshots
        ;;
    upload)
        upload_binary
        ;;
    metadata)
        upload_metadata
        upload_screenshots
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
