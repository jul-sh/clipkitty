#!/usr/bin/env bash
# Verify authoritative pinned-input files are committed and unchanged.
# Also fail if SwiftPM resolution files appear on disk: Swift pins live in
# nix/lib.nix and `Package.resolved` is treated as generated stray state.

set -euo pipefail

PINNED_FILES=(
  Cargo.lock
  flake.lock
)

ERRORS=0

for f in "${PINNED_FILES[@]}"; do
  # Check the file is tracked by git
  if ! git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    echo "NOT TRACKED: $f (must be committed)"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Check for modifications (staged or unstaged)
  if ! git diff --exit-code -- "$f" >/dev/null 2>&1; then
    echo "MODIFIED: $f"
    ERRORS=$((ERRORS + 1))
  fi
  if ! git diff --cached --exit-code -- "$f" >/dev/null 2>&1; then
    echo "STAGED CHANGES: $f"
    ERRORS=$((ERRORS + 1))
  fi
done

# Check for stray SwiftPM resolution files. They should never be tracked or
# present in the worktree because the canonical pinset lives in nix/lib.nix.
STRAY_SWIFT_RESOLVED=(
  Package.resolved
  Tuist/Package.resolved
  distribution/SparkleUpdater/Package.resolved
)

for f in "${STRAY_SWIFT_RESOLVED[@]}"; do
  if [ -e "$f" ]; then
    echo "STRAY SWIFTPM STATE: $f (Swift pins belong in nix/lib.nix)"
    ERRORS=$((ERRORS + 1))
  fi
done

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "Pinned-input drift detected."
  exit 1
fi

echo "Pinned inputs are committed, unchanged, and free of stray SwiftPM lockfiles."
