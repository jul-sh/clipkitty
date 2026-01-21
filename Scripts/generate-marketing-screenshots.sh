#!/bin/bash
# Generates professional App Store marketing screenshots from raw captures
# Requires: ImageMagick (brew install imagemagick)
# Input: /tmp/clipkitty_marketing_*.png (from testTakeMarketingScreenshots)
# Output: marketing/screenshot_*.png (with rounded corners, shadows, captions)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_ROOT/marketing"
ASSETS_DIR="$PROJECT_ROOT/marketing/assets"

# Marketing captions - benefit-focused, not feature-focused
CAPTION_1="Never lose a copy again"
CAPTION_2="Find anything instantly"
CAPTION_3="See your full content"

# App Store dimensions for Mac
FINAL_WIDTH=2880
FINAL_HEIGHT=1800

# Styling
CORNER_RADIUS=24
SHADOW_OPACITY=50
SHADOW_BLUR=30
SHADOW_OFFSET=20
CAPTION_SIZE=72
CAPTION_COLOR="white"
CAPTION_Y_OFFSET=80

# Create output directories
mkdir -p "$OUTPUT_DIR"
mkdir -p "$ASSETS_DIR"

# Check for ImageMagick
if ! command -v magick &> /dev/null; then
    echo "Error: ImageMagick is required. Install with: brew install imagemagick"
    exit 1
fi

echo "=== ClipKitty Marketing Screenshot Generator ==="
echo ""

# Use the background image file (from environment or default)
BACKGROUND_IMAGE="${BACKGROUND_IMAGE:-/System/Library/Desktop Pictures/Solid Colors/Cyan.png}"
BG_RESIZED="$ASSETS_DIR/background_resized.png"

if [ ! -f "$BG_RESIZED" ]; then
    echo "Preparing background..."
    # Resize background file to App Store dimensions
    magick "$BACKGROUND_IMAGE" -resize "${FINAL_WIDTH}x${FINAL_HEIGHT}!" "$BG_RESIZED"
    echo "Created: $BG_RESIZED"
fi

# Use background
GRADIENT_BG="$BG_RESIZED"

# Function to process a single screenshot
process_screenshot() {
    local INPUT="$1"
    local OUTPUT="$2"
    local CAPTION="$3"

    if [ ! -f "$INPUT" ]; then
        echo "Warning: Input file not found: $INPUT"
        return 1
    fi

    echo "Processing: $(basename "$INPUT")"
    echo "  Caption: \"$CAPTION\""

    # Get input dimensions
    local INPUT_WIDTH=$(magick identify -format "%w" "$INPUT")
    local INPUT_HEIGHT=$(magick identify -format "%h" "$INPUT")
    echo "  Input size: ${INPUT_WIDTH}x${INPUT_HEIGHT}"

    # Scale down the screenshot to fit nicely on the background
    # Leave room for caption at top
    local SCALE_WIDTH=$((FINAL_WIDTH - 300))
    local SCALE_HEIGHT=$((FINAL_HEIGHT - 300))

    # Step 1: Add rounded corners using a mask approach
    magick "$INPUT" \
        -alpha set \
        \( +clone -alpha extract \
            -draw "fill black rectangle 0,0 ${INPUT_WIDTH},${INPUT_HEIGHT}" \
            -fill white \
            -draw "roundrectangle 0,0 $((INPUT_WIDTH-1)),$((INPUT_HEIGHT-1)) ${CORNER_RADIUS},${CORNER_RADIUS}" \
        \) \
        -alpha off -compose CopyOpacity -composite \
        "/tmp/clipkitty_rounded.png"

    # Step 2: Add drop shadow
    magick "/tmp/clipkitty_rounded.png" \
        \( +clone -background "rgba(0,0,0,0.5)" -shadow "${SHADOW_OPACITY}x${SHADOW_BLUR}+0+${SHADOW_OFFSET}" \) \
        +swap -background none -layers merge +repage \
        "/tmp/clipkitty_shadowed.png"

    # Step 3: Resize to fit
    magick "/tmp/clipkitty_shadowed.png" \
        -resize "${SCALE_WIDTH}x${SCALE_HEIGHT}>" \
        "/tmp/clipkitty_resized.png"

    # Step 4: Composite onto background with caption
    # Use Arial-Bold which is available on macOS
    magick "$GRADIENT_BG" \
        "/tmp/clipkitty_resized.png" -gravity center -geometry +0+50 -composite \
        -gravity north -fill "$CAPTION_COLOR" \
        -font "Arial-Bold" -pointsize $CAPTION_SIZE \
        -annotate +0+$CAPTION_Y_OFFSET "$CAPTION" \
        "$OUTPUT"

    # Clean up temp files
    rm -f "/tmp/clipkitty_rounded.png" "/tmp/clipkitty_shadowed.png" "/tmp/clipkitty_resized.png"

    echo "  Output: $OUTPUT"
    echo ""
}

# Check if raw screenshots exist
RAW_1="/tmp/clipkitty_marketing_1_history.png"
RAW_2="/tmp/clipkitty_marketing_2_search.png"
RAW_3="/tmp/clipkitty_marketing_3_preview.png"

MISSING_FILES=0
for f in "$RAW_1" "$RAW_2" "$RAW_3"; do
    if [ ! -f "$f" ]; then
        echo "Missing: $f"
        MISSING_FILES=1
    fi
done

if [ $MISSING_FILES -eq 1 ]; then
    echo ""
    echo "Raw screenshots not found. Run the marketing screenshots test first:"
    echo "  make marketing-screenshots-capture"
    echo ""
    echo "Or run the full pipeline:"
    echo "  make marketing"
    exit 1
fi

# Process each screenshot
process_screenshot "$RAW_1" "$OUTPUT_DIR/screenshot_1.png" "$CAPTION_1"
process_screenshot "$RAW_2" "$OUTPUT_DIR/screenshot_2.png" "$CAPTION_2"
process_screenshot "$RAW_3" "$OUTPUT_DIR/screenshot_3.png" "$CAPTION_3"

echo "=== Screenshot Generation Complete ==="
echo ""
echo "Output files:"
ls -lh "$OUTPUT_DIR"/screenshot_*.png 2>/dev/null || echo "  (none generated)"
echo ""
echo "App Store Requirements:"
echo "  - Resolution: ${FINAL_WIDTH}x${FINAL_HEIGHT} ✓"
echo "  - Format: PNG ✓"
echo "  - Count: Up to 10 allowed (3 generated)"
