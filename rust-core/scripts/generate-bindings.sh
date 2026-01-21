#!/bin/bash
# Thin wrapper to call Rust binary for generating UniFFI Swift bindings
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
cargo run --bin generate-bindings
