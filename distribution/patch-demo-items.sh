#!/bin/bash
# Patches the synthetic database with demo-specific items for marketing
# Run this before generating marketing assets
#
# Deduplication approach:
# - Base DB (SyntheticData.sqlite) contains only text items (48KB)
# - Images stored as files in distribution/images/ (~3.5MB total)
# - At screenshot time: copy base DB + inject images for target locale
# - Result: ~3.5MB per locale instead of 35MB×10 = 350MB
#
# Usage: ./distribution/patch-demo-items.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# All supported locales
LOCALES=("en" "es" "zh-Hans" "zh-Hant" "ja" "ko" "fr" "de" "pt-BR" "ru")

echo "Patching synthetic data with demo items..."

# Step 1: Ensure base database has demo text items (no images)
echo "Refreshing base database with demo text items..."
"$PROJECT_ROOT/Scripts/run-in-nix.sh" -c "cd '$SCRIPT_DIR/rust-data-gen' && cargo run --release -- --demo-only --db-path ../SyntheticData.sqlite"

# Step 2: Remove any images from base DB (keep it text-only)
echo "Stripping images from base database..."
sqlite3 "$SCRIPT_DIR/SyntheticData.sqlite" "DELETE FROM image_items; DELETE FROM items WHERE contentType='image'; VACUUM;"

# Step 3: Generate locale-specific databases with images
for locale in "${LOCALES[@]}"; do
    if [ "$locale" = "en" ]; then
        db_name="SyntheticData.sqlite"
    else
        db_name="SyntheticData_${locale}.sqlite"
        # Copy base DB for non-English locales
        cp "$SCRIPT_DIR/SyntheticData.sqlite" "$SCRIPT_DIR/$db_name"
        # Replace English text items with localized ones
        "$PROJECT_ROOT/Scripts/run-in-nix.sh" -c "cd '$SCRIPT_DIR/rust-data-gen' && cargo run --release -- --demo-only --locale $locale --db-path ../$db_name"
    fi

    # Inject images for this locale
    echo "Injecting images for $locale..."
    python3 "$SCRIPT_DIR/inject-images.py" "$SCRIPT_DIR/$db_name" "$locale"
done

echo ""
echo "Done. Generated demo databases:"
for locale in "${LOCALES[@]}"; do
    if [ "$locale" = "en" ]; then
        ls -lh "$SCRIPT_DIR/SyntheticData.sqlite" | awk '{print "  - SyntheticData.sqlite (" $5 ")"}'
    else
        ls -lh "$SCRIPT_DIR/SyntheticData_${locale}.sqlite" | awk '{print "  - SyntheticData_" loc ".sqlite (" $5 ")"}' loc="$locale"
    fi
done
