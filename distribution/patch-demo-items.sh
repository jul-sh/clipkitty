#!/bin/bash
# Patches the synthetic database with demo-specific items for marketing
# Run this before generating marketing assets
#
# Usage: ./distribution/patch-demo-items.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "Patching synthetic data with demo items..."

"$PROJECT_ROOT/Scripts/run-in-nix.sh" -c "cd '$SCRIPT_DIR/rust-data-gen' && cargo run --release -- --demo-only --db-path ../SyntheticData.sqlite"

echo "Done. Demo items added to distribution/SyntheticData.sqlite"
