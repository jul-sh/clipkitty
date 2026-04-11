#!/usr/bin/env bash
# Verify authoritative lockfiles are committed and unchanged.
# Fails if any listed lockfile is missing from git, has staged/unstaged changes,
# or exists as an untracked file (indicating it was regenerated).

set -euo pipefail

LOCKFILES=(
  Cargo.lock
  flake.lock
  MODULE.bazel.lock
  Package.resolved
)

ERRORS=0

for f in "${LOCKFILES[@]}"; do
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

# Also check for untracked lockfiles that might shadow tracked ones
for f in "${LOCKFILES[@]}"; do
  if git ls-files --others --exclude-standard -- "$f" | grep -q .; then
    echo "UNTRACKED COPY: $f (lockfile was regenerated outside git)"
    ERRORS=$((ERRORS + 1))
  fi
done

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "Lockfile drift detected. CI lockfiles must remain committed and unchanged."
  exit 1
fi

echo "All lockfiles committed and unchanged."
