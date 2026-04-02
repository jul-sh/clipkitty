#!/bin/bash

# Shared helpers for authenticating the official `asc` CLI from repo-managed
# age-encrypted secrets. This repo historically stored the App Store Connect
# API key under NOTARY_* names, so we fall back to those for compatibility.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

read_optional_secret() {
    local name="${1%.age}"
    local path="$PROJECT_ROOT/secrets/$name.age"

    if [ ! -f "$path" ]; then
        return 1
    fi

    "$SCRIPT_DIR/read-secret.sh" "$name"
}

asc_auth_key_id() {
    read_optional_secret APPSTORE_KEY_ID || read_optional_secret NOTARY_KEY_ID
}

asc_auth_issuer_id() {
    read_optional_secret APPSTORE_ISSUER_ID || read_optional_secret NOTARY_ISSUER_ID
}

asc_auth_private_key_b64() {
    read_optional_secret APPSTORE_KEY_BASE64 || read_optional_secret NOTARY_KEY_BASE64
}

export_asc_auth_env() {
    export ASC_KEY_ID
    export ASC_ISSUER_ID
    export ASC_PRIVATE_KEY_B64

    ASC_KEY_ID="$(asc_auth_key_id)"
    ASC_ISSUER_ID="$(asc_auth_issuer_id)"
    ASC_PRIVATE_KEY_B64="$(asc_auth_private_key_b64)"
}

usage() {
    cat <<'EOF' >&2
Usage: ./distribution/asc-auth.sh [field]

Fields:
  key-id           Print the App Store Connect key ID
  issuer-id        Print the App Store Connect issuer ID
  private-key-b64  Print the base64-encoded private key
EOF
    exit 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    [ "$#" -eq 1 ] || usage

    case "$1" in
        key-id)
            asc_auth_key_id
            ;;
        issuer-id)
            asc_auth_issuer_id
            ;;
        private-key-b64)
            asc_auth_private_key_b64
            ;;
        *)
            usage
            ;;
    esac
fi
