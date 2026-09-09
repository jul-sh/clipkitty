#!/usr/bin/env bash
# Expose named secrets from the environment as masked GitHub step outputs.
# Run under `sops exec-env secrets.env`, which supplies the values.
#
#   sops exec-env secrets.env 'scripts/ci-secret-outputs.sh MACOS_P12_BASE64 MACOS_P12_PASSWORD'
set -euo pipefail

for name in "$@"; do
  value="${!name-}"
  if [ -z "$value" ]; then
    echo "::error::${name} is missing or empty in secrets.env."
    exit 1
  fi
  masked="${value//%/%25}"
  masked="${masked//$'\r'/%0D}"
  masked="${masked//$'\n'/%0A}"
  printf '::add-mask::%s\n' "$masked"
  delimiter="SECRET_$(uuidgen | tr -d '-')"
  while printf '%s\n' "$value" | grep -Fqx -- "$delimiter"; do
    delimiter="SECRET_$(uuidgen | tr -d '-')"
  done
  {
    printf '%s<<%s\n' "$name" "$delimiter"
    printf '%s\n' "$value"
    printf '%s\n' "$delimiter"
  } >> "$GITHUB_OUTPUT"
done
