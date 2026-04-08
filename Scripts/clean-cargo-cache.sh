#!/usr/bin/env bash
# Clean stale Cargo build artifacts to keep target/ manageable.
# Run periodically (e.g., weekly) or when disk space is tight.
#
# Requires: cargo install cargo-sweep

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

echo "==> Sweeping artifacts older than 14 days..."
if command -v cargo-sweep &>/dev/null; then
    cargo sweep --time 14
else
    echo "    cargo-sweep not installed. Install with: cargo install cargo-sweep"
fi

echo "==> Cleaning extracted registry sources..."
rm -rf ~/.cargo/registry/src/
echo "    Done. Cargo will re-extract crates on next build."

echo ""
du -sh target/ 2>/dev/null || true
echo "Clean complete."
