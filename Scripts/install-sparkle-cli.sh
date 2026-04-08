#!/usr/bin/env bash
# Install Sparkle CLI tools with SHA256 verification.
# Usage: install-sparkle-cli.sh [install_dir]
# Adds the Sparkle bin directory to GITHUB_PATH if in CI.

set -euo pipefail

SPARKLE_VERSION="2.9.0"
SPARKLE_SHA256="01e0f0ebf6614061ea816d414de50f937d64ffa6822ad572243031ca3676fe19"
INSTALL_DIR="${1:-/tmp/sparkle}"

curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" -o /tmp/sparkle.tar.xz
echo "${SPARKLE_SHA256}  /tmp/sparkle.tar.xz" | shasum -a 256 --check
mkdir -p "$INSTALL_DIR"
tar -xf /tmp/sparkle.tar.xz -C "$INSTALL_DIR"
rm -f /tmp/sparkle.tar.xz

# Add to PATH in GitHub Actions
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$INSTALL_DIR/bin" >> "$GITHUB_PATH"
fi

echo "Sparkle CLI ${SPARKLE_VERSION} installed to $INSTALL_DIR"
