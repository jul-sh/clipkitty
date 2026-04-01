#!/bin/bash
# Regenerates provisioning profile age secrets from the current App Store
# Connect state using the official `asc` CLI.
#
# Default behavior:
#   - Ensures the bundle has iCloud capability enabled
#   - Regenerates the Mac Development profile secret for the current Mac
#   - Regenerates the Mac App Store profile secret for CI/distribution
#
# Existing certificate secrets stay in place; they are still valid through 2027.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_DIR="$PROJECT_ROOT/secrets"
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"

source "$SCRIPT_DIR/asc-auth.sh"

BUNDLE_IDENTIFIER="com.eviljuliette.clipkitty"
DEV_PROFILE_NAME="ClipKitty Mac Development"
APPSTORE_PROFILE_NAME="ClipKitty Mac App Store"
PRIMARY_ICLOUD_CONTAINER="iCloud.com.eviljuliette.clipkitty"
# ASC's iCloud capability setting still uses the legacy XCODE_6 marker for
# macOS bundle IDs, but freshly generated profiles pick up the current iCloud
# containers correctly from the bundle state.
ICLOUD_SETTINGS='[{"key":"ICLOUD_VERSION","options":[{"key":"XCODE_6","enabled":true}]}]'

REGENERATE_DEV=1
REGENERATE_APPSTORE=1
DEVICE_NAME=""

usage() {
    cat <<'EOF' >&2
Usage: ./distribution/regenerate-provisioning-secrets.sh [options]

Options:
  --dev-only          Regenerate only the Mac Development profile secret
  --appstore-only     Regenerate only the Mac App Store profile secret
  --device-name NAME  Override the name used when registering the local Mac
EOF
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dev-only)
            REGENERATE_DEV=1
            REGENERATE_APPSTORE=0
            shift
            ;;
        --appstore-only)
            REGENERATE_DEV=0
            REGENERATE_APPSTORE=1
            shift
            ;;
        --device-name)
            [ "$#" -ge 2 ] || usage
            DEVICE_NAME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

require_cmd() {
    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Required command not found: $cmd" >&2
            exit 1
        fi
    done
}

require_cmd asc python3 openssl security base64 age
export_asc_auth_env

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clipkitty-profiles.XXXXXX")"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

asc_json() {
    asc "$@"
}

json_expr() {
    local expr="$1"
    python3 -c '
import json, sys

data = json.load(sys.stdin)
result = eval(sys.argv[1])
if result is None:
    pass
elif isinstance(result, (dict, list)):
    print(json.dumps(result))
else:
    print(result)
' "$expr"
}

bundle_resource_id() {
    local bundle_json="$1"
    printf '%s' "$bundle_json" | python3 -c '
import json, sys
target = sys.argv[1]
for item in json.load(sys.stdin).get("data", []):
    if item.get("attributes", {}).get("identifier") == target:
        print(item["id"])
        break
' "$BUNDLE_IDENTIFIER"
}

capability_row() {
    local capabilities_json="$1"
    local cap_type="$2"
    printf '%s' "$capabilities_json" | python3 -c '
import json, sys
target = sys.argv[1]
for item in json.load(sys.stdin).get("data", []):
    if item.get("attributes", {}).get("capabilityType") == target:
        print(json.dumps(item))
        break
' "$cap_type"
}

profile_rows_matching() {
    local profiles_json="$1"
    local profile_name="$2"
    local profile_type="$3"
    printf '%s' "$profiles_json" | python3 -c '
import json, sys
target_name, target_type = sys.argv[1], sys.argv[2]
for item in json.load(sys.stdin).get("data", []):
    attrs = item.get("attributes", {})
    if attrs.get("name") == target_name and attrs.get("profileType") == target_type:
        print(item["id"])
' "$profile_name" "$profile_type"
}

profile_id() {
    local profile_json="$1"
    printf '%s' "$profile_json" | json_expr 'data["data"]["id"]'
}

profile_contains_icloud_container() {
    local profile_path="$1"
    local plist
    plist=$(security cms -D -i "$profile_path" 2>/dev/null)
    grep -Fq "<string>$PRIMARY_ICLOUD_CONTAINER</string>" <<<"$plist"
}

profile_contains_device() {
    local profile_path="$1"
    local udid="$2"
    local plist
    plist=$(security cms -D -i "$profile_path" 2>/dev/null)
    grep -Fq "<string>$udid</string>" <<<"$plist"
}

remove_local_profiles_named() {
    local name="$1"
    local path
    for path in "$PROFILE_DIR"/*.provisionprofile; do
        [ -f "$path" ] || continue
        local plist
        plist=$(security cms -D -i "$path" 2>/dev/null) || continue
        local current_name
        current_name=$(echo "$plist" | plutil -extract Name raw - -o - 2>/dev/null) || continue
        if [ "$current_name" = "$name" ]; then
            rm -f "$path"
        fi
    done
}

install_profile_locally() {
    local profile_path="$1"
    local name="$2"
    local uuid
    uuid=$(security cms -D -i "$profile_path" 2>/dev/null | plutil -extract UUID raw - -o - 2>/dev/null)
    if [ -z "$uuid" ]; then
        echo "Error: Could not read UUID from profile $profile_path" >&2
        exit 1
    fi
    mkdir -p "$PROFILE_DIR"
    remove_local_profiles_named "$name"
    cp "$profile_path" "$PROFILE_DIR/$uuid.provisionprofile"
}

secret_p12_serial() {
    local p12_secret="$1"
    local password_secret="$2"
    local p12_path="$TMP_DIR/$p12_secret.p12"
    local password_file="$TMP_DIR/$password_secret.txt"

    "$SCRIPT_DIR/read-secret.sh" "$p12_secret" | base64 --decode > "$p12_path"
    "$SCRIPT_DIR/read-secret.sh" "$password_secret" > "$password_file"

    openssl pkcs12 -in "$p12_path" -passin file:"$password_file" -clcerts -nokeys 2>/dev/null \
        | openssl x509 -noout -serial 2>/dev/null \
        | awk -F= '{print $2}'
}

certificate_id_for_serial() {
    local certificates_json="$1"
    local serial="$2"
    printf '%s' "$certificates_json" | python3 -c '
import json, sys

def normalize(value):
    value = (value or "").upper().lstrip("0")
    return value or "0"

target = normalize(sys.argv[1])
for item in json.load(sys.stdin).get("data", []):
    attrs = item.get("attributes", {})
    if normalize(attrs.get("serialNumber")) == target:
        print(item["id"])
        break
' "$serial"
}

device_id_for_udid() {
    local devices_json="$1"
    local udid="$2"
    printf '%s' "$devices_json" | python3 -c '
import json, sys
target = sys.argv[1].upper()
for item in json.load(sys.stdin).get("data", []):
    attrs = item.get("attributes", {})
    if (attrs.get("udid") or "").upper() == target:
        print(item["id"])
        break
' "$udid"
}

ensure_icloud_capability() {
    local bundle_id="$1"
    local capabilities_json capability_json capability_settings

    capabilities_json="$(asc_json bundle-ids capabilities list --bundle "$bundle_id")"
    capability_json="$(capability_row "$capabilities_json" ICLOUD)"

    if [ -z "$capability_json" ]; then
        echo "Enabling ICLOUD capability for $BUNDLE_IDENTIFIER..."
        asc_json bundle-ids capabilities add \
            --bundle "$bundle_id" \
            --capability ICLOUD \
            --settings "$ICLOUD_SETTINGS" >/dev/null
        return
    fi

    capability_settings="$(printf '%s' "$capability_json" | json_expr 'data["attributes"].get("settings", [])')"
    echo "iCloud capability already enabled: $capability_settings"
}

delete_profiles_named() {
    local profile_name="$1"
    local profile_type="$2"
    local profiles_json ids id

    profiles_json="$(asc_json profiles list --profile-type "$profile_type" --paginate)"
    ids="$(profile_rows_matching "$profiles_json" "$profile_name" "$profile_type")"

    for id in $ids; do
        echo "Deleting stale profile $profile_name ($id)..."
        asc_json profiles delete --id "$id" --confirm >/dev/null
    done
}

download_profile_to() {
    local profile_id="$1"
    local output_path="$2"
    asc_json profiles download --id "$profile_id" --output "$output_path" >/dev/null
}

resolve_bundle_id() {
    local bundles_json
    bundles_json="$(asc_json bundle-ids list --paginate)"
    BUNDLE_RESOURCE_ID="$(bundle_resource_id "$bundles_json")"

    if [ -z "$BUNDLE_RESOURCE_ID" ]; then
        echo "Error: Could not resolve App Store Connect bundle resource for $BUNDLE_IDENTIFIER" >&2
        exit 1
    fi
}

resolve_dev_device_id() {
    DEV_UDID="$(system_profiler SPHardwareDataType 2>/dev/null | awk '/Provisioning UDID/{print $3}')"
    if [ -z "$DEV_UDID" ]; then
        echo "Error: Could not determine this Mac's Provisioning UDID" >&2
        exit 1
    fi

    if [ -z "$DEVICE_NAME" ]; then
        DEVICE_NAME="$(scutil --get ComputerName 2>/dev/null || hostname -s)"
    fi

    local devices_json
    devices_json="$(asc_json devices list --platform MAC_OS --paginate)"
    DEV_DEVICE_ID="$(device_id_for_udid "$devices_json" "$DEV_UDID")"

    if [ -n "$DEV_DEVICE_ID" ]; then
        echo "Local Mac already registered for development: $DEV_DEVICE_ID"
        return
    fi

    echo "Registering this Mac for development provisioning..."
    DEV_DEVICE_ID="$(asc_json devices register --name "$DEVICE_NAME" --udid "$DEV_UDID" --platform MAC_OS | json_expr 'data["data"]["id"]')"
}

regenerate_dev_profile() {
    local certificates_json dev_serial dev_cert_id profile_json new_profile_id profile_path

    echo "Regenerating Mac Development profile secret..."
    resolve_dev_device_id

    certificates_json="$(asc_json certificates list --paginate)"
    dev_serial="$(secret_p12_serial MAC_DEV_P12_BASE64 MAC_DEV_P12_PASSWORD)"
    DEV_CERT_ID="$(certificate_id_for_serial "$certificates_json" "$dev_serial")"

    if [ -z "$DEV_CERT_ID" ]; then
        echo "Error: Could not find Apple Development certificate for serial $dev_serial in App Store Connect" >&2
        exit 1
    fi

    delete_profiles_named "$DEV_PROFILE_NAME" MAC_APP_DEVELOPMENT

    profile_json="$(asc_json profiles create \
        --name "$DEV_PROFILE_NAME" \
        --profile-type MAC_APP_DEVELOPMENT \
        --bundle "$BUNDLE_RESOURCE_ID" \
        --certificate "$DEV_CERT_ID" \
        --device "$DEV_DEVICE_ID")"

    new_profile_id="$(profile_id "$profile_json")"
    profile_path="$TMP_DIR/mac-dev.provisionprofile"
    download_profile_to "$new_profile_id" "$profile_path"

    if ! profile_contains_icloud_container "$profile_path"; then
        echo "Error: Regenerated Mac Development profile is still missing $PRIMARY_ICLOUD_CONTAINER" >&2
        exit 1
    fi

    if ! profile_contains_device "$profile_path" "$DEV_UDID"; then
        echo "Error: Regenerated Mac Development profile does not include this Mac ($DEV_UDID)" >&2
        exit 1
    fi

    base64 < "$profile_path" | "$SCRIPT_DIR/write-secret.sh" MAC_DEV_PROVISIONING_PROFILE_BASE64 >/dev/null
    install_profile_locally "$profile_path" "$DEV_PROFILE_NAME"
    echo "Updated MAC_DEV_PROVISIONING_PROFILE_BASE64.age"
}

regenerate_appstore_profile() {
    local certificates_json appstore_serial appstore_cert_id profile_json new_profile_id profile_path

    echo "Regenerating Mac App Store profile secret..."
    certificates_json="$(asc_json certificates list --paginate)"
    appstore_serial="$(secret_p12_serial APPSTORE_APP_CERT_BASE64 P12_PASSWORD)"
    APPSTORE_CERT_ID="$(certificate_id_for_serial "$certificates_json" "$appstore_serial")"

    if [ -z "$APPSTORE_CERT_ID" ]; then
        echo "Error: Could not find App Store application certificate for serial $appstore_serial in App Store Connect" >&2
        exit 1
    fi

    delete_profiles_named "$APPSTORE_PROFILE_NAME" MAC_APP_STORE

    profile_json="$(asc_json profiles create \
        --name "$APPSTORE_PROFILE_NAME" \
        --profile-type MAC_APP_STORE \
        --bundle "$BUNDLE_RESOURCE_ID" \
        --certificate "$APPSTORE_CERT_ID")"

    new_profile_id="$(profile_id "$profile_json")"
    profile_path="$TMP_DIR/mac-app-store.provisionprofile"
    download_profile_to "$new_profile_id" "$profile_path"

    if ! profile_contains_icloud_container "$profile_path"; then
        echo "Error: Regenerated Mac App Store profile is still missing $PRIMARY_ICLOUD_CONTAINER" >&2
        exit 1
    fi

    base64 < "$profile_path" | "$SCRIPT_DIR/write-secret.sh" PROVISION_PROFILE_BASE64 >/dev/null
    echo "Updated PROVISION_PROFILE_BASE64.age"
}

resolve_bundle_id
ensure_icloud_capability "$BUNDLE_RESOURCE_ID"

if [ "$REGENERATE_DEV" -eq 1 ]; then
    regenerate_dev_profile
fi

if [ "$REGENERATE_APPSTORE" -eq 1 ]; then
    regenerate_appstore_profile
fi

echo "Provisioning secrets regenerated successfully."
