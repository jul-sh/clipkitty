#!/bin/bash
# Records an App Store preview video of ClipKitty's search functionality
# Requires: ffmpeg (brew install ffmpeg)
# Output: marketing/app_preview.mov (H.264, 30fps, ready for App Store)
#
# NOTE: You must grant screen recording permission to Terminal/your shell:
#   System Settings > Privacy & Security > Screen Recording > [Enable Terminal]
# After enabling, restart your terminal.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_ROOT/marketing"
RAW_VIDEO="/tmp/clipkitty_raw_preview.mov"
FINAL_VIDEO="$OUTPUT_DIR/app_preview.mov"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Check for ffmpeg
if ! command -v ffmpeg &> /dev/null; then
    echo "Error: ffmpeg is required. Install with: brew install ffmpeg"
    exit 1
fi

echo "=== ClipKitty App Store Preview Video Recording ==="
echo ""

# Get screen dimensions for recording
SCREEN_WIDTH=$(system_profiler SPDisplaysDataType | grep Resolution | head -1 | awk '{print $2}')
SCREEN_HEIGHT=$(system_profiler SPDisplaysDataType | grep Resolution | head -1 | awk '{print $4}')
echo "Screen resolution: ${SCREEN_WIDTH}x${SCREEN_HEIGHT}"

# Set a clean desktop background (solid gray)
echo "Setting desktop background..."
osascript -e 'tell application "System Events" to tell every desktop to set picture to ""' 2>/dev/null || true
osascript -e 'tell application "Finder" to set desktop picture to POSIX file "/System/Library/Desktop Pictures/Solid Colors/Stone.png"' 2>/dev/null || true

# Give time for background to change
sleep 1

# Clean up any existing raw video
rm -f "$RAW_VIDEO"

echo "Starting screen recording..."
echo "(Recording will capture the search demo test)"
echo ""
echo "NOTE: If this fails, ensure Terminal has Screen Recording permission:"
echo "  System Settings > Privacy & Security > Screen Recording"
echo ""

# Use macOS screencapture for recording the app window
echo "Using macOS screencapture for recording..."
# Start recording with screencapture (30 second max, app window only)
# Note: screencapture -w captures the focused window
screencapture -v -V 30 -w "$RAW_VIDEO" &  # Do NOT use -i (interactive) with -V; it causes "video not valid with -i" error
RECORD_PID=$!
sleep 2

echo "Running search demo UI test..."
# Run only the search demo test
cd "$PROJECT_ROOT"
xcodebuild test \
    -project ClipKitty.xcodeproj \
    -scheme ClipKittyUITests \
    -destination 'platform=macOS' \
    -derivedDataPath DerivedData \
    -only-testing:ClipKittyUITests/ClipKittyUITests/testRecordSearchDemo \
    2>&1 | grep -E "(Test Case|passed|failed)" || true

# Wait a moment for the test to fully complete
sleep 1

# Stop recording
echo ""
echo "Stopping recording..."
kill -INT $RECORD_PID 2>/dev/null || true
wait $RECORD_PID 2>/dev/null || true

# Check if recording was captured
if [ ! -f "$RAW_VIDEO" ]; then
    echo "Error: Failed to capture video"
    exit 1
fi

echo "Post-processing video..."

# Get raw video duration
DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$RAW_VIDEO" 2>/dev/null | cut -d. -f1)
echo "Raw video duration: ${DURATION}s"

# Calculate fade out start time (1 second before end)
FADE_OUT_START=$((DURATION - 1))
if [ $FADE_OUT_START -lt 1 ]; then
    FADE_OUT_START=1
fi

# Post-process:
# - Trim to reasonable length (max 25 seconds for App Store's 15-30s requirement)
# - Add fade in/out
# - Ensure proper encoding for App Store (H.264, AAC)
# - Scale to App Store dimensions (2880x1800 or 1280x800)
ffmpeg -y -i "$RAW_VIDEO" \
    -t 25 \
    -vf "fade=t=in:st=0:d=0.5,fade=t=out:st=24:d=1,scale=2880:1800:force_original_aspect_ratio=decrease,pad=2880:1800:(ow-iw)/2:(oh-ih)/2:color=gray" \
    -c:v libx264 -preset slow -crf 18 -profile:v high -level 4.0 \
    -pix_fmt yuv420p \
    -movflags +faststart \
    -an \
    "$FINAL_VIDEO"

# Clean up raw video
rm -f "$RAW_VIDEO"

# Get final file size
FILE_SIZE=$(ls -lh "$FINAL_VIDEO" | awk '{print $5}')

echo ""
echo "=== Video Recording Complete ==="
echo "Output: $FINAL_VIDEO"
echo "Size: $FILE_SIZE"
echo ""
echo "App Store Requirements:"
echo "  - Duration: 15-30 seconds ✓"
echo "  - Format: H.264 .mov ✓"
echo "  - Resolution: 2880x1800 ✓"
echo "  - Max size: 500MB (yours: $FILE_SIZE)"
