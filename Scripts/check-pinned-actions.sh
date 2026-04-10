#!/usr/bin/env bash
# Validates that all GitHub Actions `uses:` references are pinned to full SHAs.
# Exits non-zero if any unpinned references are found.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOWS_DIR="$ROOT_DIR/.github/workflows"

if [ ! -d "$WORKFLOWS_DIR" ]; then
  echo "No workflows directory found at $WORKFLOWS_DIR"
  exit 0
fi

ERRORS=0

while IFS= read -r line; do
  # Extract the action reference (everything after uses: and before any comment)
  ref=$(echo "$line" | sed 's/.*uses: *\([^#]*\).*/\1/' | xargs)
  file=$(echo "$line" | cut -d: -f1)

  # Skip docker:// and local ./ references
  if [[ "$ref" == docker://* ]] || [[ "$ref" == ./* ]]; then
    continue
  fi

  # Check if the ref contains a 40-char hex SHA after the @
  if ! echo "$ref" | grep -qE '@[0-9a-f]{40}$'; then
    echo "UNPINNED: $file: $ref"
    ERRORS=$((ERRORS + 1))
  fi
done < <(grep -rn 'uses:' "$WORKFLOWS_DIR" --include='*.yml' --include='*.yaml' | grep -v '^\s*#')

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "Found $ERRORS unpinned GitHub Action reference(s)."
  echo "Pin all actions to full commit SHAs (40 hex characters)."
  exit 1
fi

echo "All GitHub Actions are pinned to full SHAs."
