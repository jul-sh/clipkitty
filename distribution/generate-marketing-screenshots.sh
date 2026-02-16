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
CAPTION_COLOR="black"
CAPTION_Y_OFFSET=80

# Create output directories
mkdir -p "$OUTPUT_DIR"
mkdir -p "$ASSETS_DIR"

# Check for ImageMagick - prefer imagemagick-full for font rendering support
MAGICK_FULL="/opt/homebrew/opt/imagemagick-full/bin/magick"
if [ -x "$MAGICK_FULL" ]; then
    MAGICK="$MAGICK_FULL"
    echo "Using imagemagick-full (with font support)"
elif command -v magick &> /dev/null; then
    MAGICK="magick"
    echo "Warning: Using regular imagemagick (captions may not render)"
    echo "For full font support, run: brew install imagemagick-full"
else
    echo "Error: ImageMagick is required. Install with: brew install imagemagick-full"
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
    $MAGICK "$BACKGROUND_IMAGE" -resize "${FINAL_WIDTH}x${FINAL_HEIGHT}!" "$BG_RESIZED"
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
    local INPUT_WIDTH=$($MAGICK identify -format "%w" "$INPUT")
    local INPUT_HEIGHT=$($MAGICK identify -format "%h" "$INPUT")
    echo "  Input size: ${INPUT_WIDTH}x${INPUT_HEIGHT}"

    # Scale the screenshot to fill most of the canvas
    local SCALE_WIDTH=$FINAL_WIDTH
    local SCALE_HEIGHT=$FINAL_HEIGHT

    # Step 1: Resize to fit (Catrom = bicubic sharp, avoids blur on upscale)
    $MAGICK "$INPUT" \
        -filter Catrom -resize "${SCALE_WIDTH}x${SCALE_HEIGHT}" \
        "/tmp/clipkitty_resized.png"

    # Step 2: Composite onto background (shifted up from center)
    FONT_PATH="/System/Library/Fonts/SFNS.ttf"

    if $MAGICK -background none -fill "$CAPTION_COLOR" \
        -font "$FONT_PATH" -pointsize $CAPTION_SIZE \
        -gravity center "label:$CAPTION" \
        "/tmp/clipkitty_caption.png" 2>/dev/null; then
        $MAGICK "$GRADIENT_BG" \
            "/tmp/clipkitty_resized.png" -gravity center -geometry +0-40 -composite \
            "/tmp/clipkitty_caption.png" -gravity north -geometry +0+$CAPTION_Y_OFFSET -composite \
            "$OUTPUT"
        rm -f "/tmp/clipkitty_caption.png"
    else
        echo "  Warning: Font rendering unavailable, skipping caption"
        $MAGICK "$GRADIENT_BG" \
            "/tmp/clipkitty_resized.png" -gravity center -geometry +0-40 -composite \
            "$OUTPUT"
    fi

    # Clean up temp files
    rm -f "/tmp/clipkitty_resized.png"

    echo "  Output: $OUTPUT"
    echo ""
}

# Check if raw screenshots exist
RAW_1="/tmp/clipkitty_marketing_1_history.png"
RAW_2="/tmp/clipkitty_marketing_2_search.png"
RAW_3="/tmp/clipkitty_marketing_3_filter.png"

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
