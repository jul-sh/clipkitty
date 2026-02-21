#!/bin/bash
# Outputs AGE_SECRET_KEY from environment or macOS Keychain.
# Exits 1 if not found in either location.
#
# Usage:
#   AGE_SECRET_KEY=$(./distribution/get-age-key.sh)
#
# To store in Keychain:
#   security add-generic-password -s clipkitty -a AGE_SECRET_KEY -w 'AGE-SECRET-KEY-...'

if [ -n "$AGE_SECRET_KEY" ]; then
    printf '%s' "$AGE_SECRET_KEY"
elif KEY=$(security find-generic-password -s clipkitty -a AGE_SECRET_KEY -w 2>/dev/null); then
    printf '%s' "$KEY"
else
    echo "Error: AGE_SECRET_KEY not set and not found in Keychain" >&2
    echo "  Set via: export AGE_SECRET_KEY='AGE-SECRET-KEY-...'" >&2
    echo "  Or store: security add-generic-password -s clipkitty -a AGE_SECRET_KEY -w 'KEY'" >&2
    exit 1
fi
