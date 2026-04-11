#!/usr/bin/env bash
#
# Run bazelisk inside a Nix shell, preventing Nix from interpreting
# Bazel flags (like --embed_label) as its own flags.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec nix shell --no-update-lock-file --inputs-from "$ROOT_DIR" nixpkgs#bazelisk --command sh -c 'exec bazelisk "$@"' _ "$@"
