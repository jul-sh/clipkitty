#!/bin/bash
# Checks that all String(localized:) and NSLocalizedString() keys in Swift source
# have a corresponding entry in the xcstrings catalog.
#
# Usage: Scripts/check-localization.sh [file ...]
#   If files are given, only those files are scanned.
#   If no files are given, all Swift files under Sources/ are scanned.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

MAC_CATALOG="Sources/MacApp/Resources/Localizable.xcstrings"
IOS_CATALOG="Sources/iOSApp/Resources/Localizable.xcstrings"

if [ ! -f "$MAC_CATALOG" ] && [ ! -f "$IOS_CATALOG" ]; then
    echo -e "${RED}No localization catalog found${NC}"
    exit 1
fi

# Build set of catalog keys from all available catalogs (one per line)
CATALOG_KEYS=$(python3 -c "
import json, sys, os
keys = set()
for path in ['$MAC_CATALOG', '$IOS_CATALOG']:
    if os.path.isfile(path):
        with open(path) as f:
            data = json.load(f)
        keys.update(data['strings'].keys())
for key in sorted(keys):
    print(key)
")

# Determine which files to scan
if [ $# -gt 0 ]; then
    FILES="$@"
else
    FILES=$(find Sources -name '*.swift' -type f)
fi

MISSING=()

for file in $FILES; do
    [ -f "$file" ] || continue

    # Extract String(localized: "...") keys — skip interpolated strings (contain backslash)
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        # Skip interpolated strings — they use runtime substitution and Xcode
        # resolves them via the interpolation key format automatically
        if [[ "$key" == *'\'* ]]; then
            continue
        fi
        if ! echo "$CATALOG_KEYS" | grep -qxF "$key"; then
            MISSING+=("$file: \"$key\"")
        fi
    done < <(grep -oE 'String\(localized: "([^"]*)"' "$file" 2>/dev/null | sed 's/String(localized: "//;s/"$//' || true)

    # Extract NSLocalizedString("...") keys
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        if ! echo "$CATALOG_KEYS" | grep -qxF "$key"; then
            MISSING+=("$file: \"$key\"")
        fi
    done < <(grep -oE 'NSLocalizedString\("([^"]*)"' "$file" 2>/dev/null | sed 's/NSLocalizedString("//;s/"$//' || true)
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  Missing localization catalog entries!                     ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "The following strings are used in code but missing from any localization catalog:"
    echo "  $MAC_CATALOG"
    echo "  $IOS_CATALOG"
    echo ""
    for entry in "${MISSING[@]}"; do
        echo "  - $entry"
    done
    echo ""
    echo "To fix: add each missing key to the appropriate catalog with translations for all supported languages."
    echo "  Mac strings: $MAC_CATALOG"
    echo "  iOS strings: $IOS_CATALOG"
    echo ""
    echo "The catalog is a JSON file. For each missing key, add an entry under \"strings\" like:"
    echo ""
    echo '  "Your Key Here": {'
    echo '    "localizations": {'
    echo '      "de":      { "stringUnit": { "state": "translated", "value": "German translation" } },'
    echo '      "en":      { "stringUnit": { "state": "translated", "value": "English text" } },'
    echo '      "es":      { "stringUnit": { "state": "translated", "value": "Spanish translation" } },'
    echo '      "fr":      { "stringUnit": { "state": "translated", "value": "French translation" } },'
    echo '      "ja":      { "stringUnit": { "state": "translated", "value": "Japanese translation" } },'
    echo '      "ko":      { "stringUnit": { "state": "translated", "value": "Korean translation" } },'
    echo '      "pt-BR":   { "stringUnit": { "state": "translated", "value": "Brazilian Portuguese translation" } },'
    echo '      "ru":      { "stringUnit": { "state": "translated", "value": "Russian translation" } },'
    echo '      "zh-Hans": { "stringUnit": { "state": "translated", "value": "Simplified Chinese translation" } },'
    echo '      "zh-Hant": { "stringUnit": { "state": "translated", "value": "Traditional Chinese translation" } }'
    echo '    }'
    echo '  }'
    echo ""
    echo "The \"en\" value should match the key. Provide accurate translations for all other languages."
    echo "Keep entries sorted alphabetically by key in the catalog."
    echo ""
    exit 1
fi

echo -e "${GREEN}✓ All localized strings have catalog entries${NC}"
exit 0
