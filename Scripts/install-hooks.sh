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
# Runs SwiftLint on staged Swift files to catch hardcoded UI strings

set -e

# Colors for output
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Check if SwiftLint is installed (available via nix shell or brew)
if ! command -v swiftlint &> /dev/null; then
    echo -e "${YELLOW}Warning: SwiftLint not available. Enter the nix shell or install with: brew install swiftlint${NC}"
    echo -e "${YELLOW}Skipping lint check...${NC}"
    exit 0
fi

# Get staged Swift files
STAGED_SWIFT_FILES=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.swift$' || true)

if [ -z "$STAGED_SWIFT_FILES" ]; then
    # No Swift files staged, skip linting
    exit 0
fi

echo -e "${GREEN}Running SwiftLint on staged files...${NC}"

# Run SwiftLint on staged files only
LINT_ERRORS=0
for file in $STAGED_SWIFT_FILES; do
    if [ -f "$file" ]; then
        # Run SwiftLint and capture output
        OUTPUT=$(swiftlint lint --path "$file" --config .swiftlint.yml 2>&1) || true

        # Check for hardcoded string warnings
        if echo "$OUTPUT" | grep -q "Hardcoded"; then
            echo -e "${RED}$OUTPUT${NC}"
            LINT_ERRORS=1
        fi
    fi
done

if [ $LINT_ERRORS -eq 1 ]; then
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  Hardcoded UI strings detected!                            ║${NC}"
    echo -e "${RED}║  Please use String(localized:) for all user-facing text.   ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Examples:"
    echo '  Text(String(localized: "Hello"))        // ✓'
    echo '  Text("Hello")                           // ✗'
    echo '  Section(String(localized: "Settings"))  // ✓'
    echo '  Section("Settings")                     // ✗'
    echo ""
    echo -e "To skip this check (not recommended): ${YELLOW}git commit --no-verify${NC}"
    exit 1
fi

echo -e "${GREEN}✓ No hardcoded UI strings found${NC}"
exit 0
HOOK

chmod +x "$HOOKS_DIR/pre-commit"

echo "✓ Pre-commit hook installed"
echo ""
echo "The hook will check for hardcoded UI strings before each commit."
echo "SwiftLint is available via the nix shell (nix develop)."
