#!/bin/bash
# Patches the synthetic database with demo-specific items for marketing
# Run this before generating marketing assets
#
# Usage: ./Scripts/patch-demo-items.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "Patching synthetic data with demo items..."

"$SCRIPT_DIR/run-in-nix.sh" -c "cd rust-data-gen && cargo run --release -- --demo-only --db-path ../Sources/App/SyntheticData.sqlite"

echo "Done. Demo items added to Sources/App/SyntheticData.sqlite"
