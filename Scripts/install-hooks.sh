#!/bin/bash
# Install git hooks for ClipKitty development
# Run this once after cloning the repository

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
HOOKS_DIR="$PROJECT_ROOT/.git/hooks"

echo "Installing git hooks..."

# Create pre-commit hook
cat > "$HOOKS_DIR/pre-commit" << 'HOOK'
#!/bin/bash
# Pre-commit hook for ClipKitty
# Runs SwiftFormat and SwiftLint on staged Swift files via nix shell

set -e

# Colors for output
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Get staged Swift files
STAGED_SWIFT_FILES=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.swift$' || true)

if [ -z "$STAGED_SWIFT_FILES" ]; then
    # No Swift files staged, skip checks
    exit 0
fi

# Run the checks inside nix shell to ensure tools are available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "$SCRIPT_DIR/Scripts/run-in-nix.sh" -c "
set -e
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'
STAGED_SWIFT_FILES='$STAGED_SWIFT_FILES'

# Run SwiftFormat on staged files
echo -e \"\${GREEN}Running SwiftFormat on staged files...\${NC}\"
for file in \$STAGED_SWIFT_FILES; do
    if [ -f \"\$file\" ]; then
        swiftformat \"\$file\" --swiftversion 5
        git add \"\$file\"
    fi
done
echo -e \"\${GREEN}✓ Files formatted\${NC}\"

echo -e \"\${GREEN}Running SwiftLint on staged files...\${NC}\"

# Run SwiftLint on staged files only
LINT_ERRORS=0
for file in \$STAGED_SWIFT_FILES; do
    if [ -f \"\$file\" ]; then
        # Run SwiftLint and capture output
        OUTPUT=\$(swiftlint lint --path \"\$file\" --config .swiftlint.yml 2>&1) || true

        # Check for hardcoded string warnings
        if echo \"\$OUTPUT\" | grep -q 'Hardcoded'; then
            echo -e \"\${RED}\$OUTPUT\${NC}\"
            LINT_ERRORS=1
        fi
    fi
done

if [ \$LINT_ERRORS -eq 1 ]; then
    echo ''
    echo -e \"\${RED}╔════════════════════════════════════════════════════════════╗\${NC}\"
    echo -e \"\${RED}║  Hardcoded UI strings detected!                            ║\${NC}\"
    echo -e \"\${RED}║  Please use String(localized:) for all user-facing text.   ║\${NC}\"
    echo -e \"\${RED}╚════════════════════════════════════════════════════════════╝\${NC}\"
    echo ''
    echo 'Examples:'
    echo '  Text(String(localized: \"Hello\"))        // ✓'
    echo '  Text(\"Hello\")                           // ✗'
    echo '  Section(String(localized: \"Settings\"))  // ✓'
    echo '  Section(\"Settings\")                     // ✗'
    echo ''
    echo -e \"To skip this check (not recommended): \${YELLOW}git commit --no-verify\${NC}\"
    exit 1
fi

echo -e \"\${GREEN}✓ No hardcoded UI strings found\${NC}\"
"
HOOK

chmod +x "$HOOKS_DIR/pre-commit"

echo "✓ Pre-commit hook installed"
echo ""
echo "The hook will format Swift files and check for hardcoded UI strings before each commit."
echo "SwiftFormat and SwiftLint are available via the nix shell (nix develop)."
