#!/bin/bash
# Records a video of ClipKitty via a UI test.
# Requires: ffmpeg (brew install ffmpeg)
#
# Usage:
#   ./record-preview-video.sh                                    # Default: search demo
#   ./record-preview-video.sh --test testRecordIntroVideo \
#       --db SyntheticData_video.sqlite --output intro_video.mov --duration 50
#
# NOTE: You must grant screen recording permission to Terminal/your shell:
#   System Settings > Privacy & Security > Screen Recording > [Enable Terminal]
# After enabling, restart your terminal.

set -e

# ── Argument parsing ─────────────────────────────────────────────────────────
TEST_NAME="testRecordSearchDemo"
DB_NAME=""
OUTPUT_NAME="app_preview.mov"
RECORD_DURATION=35

while [[ $# -gt 0 ]]; do
    case "$1" in
        --test)      TEST_NAME="$2";       shift 2 ;;
        --db)        DB_NAME="$2";         shift 2 ;;
        --output)    OUTPUT_NAME="$2";     shift 2 ;;
        --duration)  RECORD_DURATION="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_ROOT/marketing"
RAW_VIDEO="/tmp/clipkitty_raw_preview.mov"
FINAL_VIDEO="$OUTPUT_DIR/$OUTPUT_NAME"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Check for ffmpeg (optional — used for crop/scale post-processing)
HAS_FFMPEG=false
if command -v ffmpeg &> /dev/null; then
    HAS_FFMPEG=true
else
    echo "Note: ffmpeg not found. Will output raw recording (no crop/scale)."
    echo "  Install with: brew install ffmpeg"
    echo ""
fi

echo "=== ClipKitty Video Recording ==="
echo "  Test:     $TEST_NAME"
echo "  DB:       ${DB_NAME:-<default>}"
echo "  Output:   $OUTPUT_NAME"
echo "  Duration: ${RECORD_DURATION}s"
echo ""

# Set up code signing (needed for stable TCC permissions across builds)
"$SCRIPT_DIR/setup-dev-signing.sh"

# Get screen dimensions for recording
SCREEN_WIDTH=$(system_profiler SPDisplaysDataType | grep Resolution | head -1 | awk '{print $2}')
SCREEN_HEIGHT=$(system_profiler SPDisplaysDataType | grep Resolution | head -1 | awk '{print $4}')
echo "Screen resolution: ${SCREEN_WIDTH}x${SCREEN_HEIGHT}"


# Close ClipKitty if it's running to ensure a clean state
if pgrep -x "ClipKitty" > /dev/null; then
    echo "Closing ClipKitty..."
    osascript -e 'quit app "ClipKitty"'
    sleep 2
fi


# Clean up any existing raw video
rm -f "$RAW_VIDEO"

echo "Starting screen recording..."
echo ""
echo "NOTE: If this fails, ensure Terminal has Screen Recording permission:"
echo "  System Settings > Privacy & Security > Screen Recording"
echo ""

# Clean up any previous marker files
rm -f /tmp/clipkitty_demo_start.txt
rm -f /tmp/clipkitty_demo_stop.txt
rm -f /tmp/clipkitty_recording_started.txt

# Write DB selection file if a custom DB was specified
if [ -n "$DB_NAME" ]; then
    echo "$DB_NAME" > /tmp/clipkitty_screenshot_db.txt
else
    rm -f /tmp/clipkitty_screenshot_db.txt
fi

echo "Starting UI test (will signal when ready)..."
# Clean stale codesign temp files that cause "invalid or unsupported format for signature"
# errors. These .cstemp files are left behind when a previous codesign is interrupted, and
# xcodebuild's parallel CopySwiftLibs + CodeSign can race to produce them.
# Nuke the entire UITests runner to force a fresh copy of system frameworks.
rm -rf "$PROJECT_ROOT/DerivedData/Build/Products/Debug/ClipKittyUITests-Runner.app" 2>/dev/null || true
find "$PROJECT_ROOT/DerivedData" -name "*.cstemp" -delete 2>/dev/null || true

# Run the test in background - it will create a marker file when demo starts
cd "$PROJECT_ROOT"
xcodebuild test \
    -workspace ClipKitty.xcworkspace \
    -scheme ClipKittyUITests \
    -destination 'platform=macOS' \
    -derivedDataPath DerivedData \
    -only-testing:ClipKittyUITests/ClipKittyUITests/$TEST_NAME \
    2>&1 | grep -E "(Test Case|passed|failed)" &
TEST_PID=$!

# Wait for the demo start signal (written by UI test when ready)
echo "Waiting for demo to start..."
WAIT_COUNT=0
while [ ! -f /tmp/clipkitty_demo_start.txt ] && [ $WAIT_COUNT -lt 60 ]; do
    sleep 0.5
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [ ! -f /tmp/clipkitty_demo_start.txt ]; then
    echo "Error: Demo did not start within 30 seconds"
    kill $TEST_PID 2>/dev/null || true
    exit 1
fi
rm -f /tmp/clipkitty_demo_start.txt

# Use macOS screencapture for recording (non-interactive with timeout)
echo "Using macOS screencapture for recording (${RECORD_DURATION}s max)..."
# -V <seconds> records video for specified duration without requiring keyboard input
screencapture -V "$RECORD_DURATION" -D 1 "$RAW_VIDEO" &
RECORD_PID=$!
sleep 1

# Signal to the UI test that recording has started
touch /tmp/clipkitty_recording_started.txt

# Wait for the demo stop signal (written by UI test when demo finished)
echo "Recording $TEST_NAME..."
STOP_WAIT_COUNT=0
DEMO_START_TIME=$(date +%s)
# Loop until stop file exists or timeout (60s)
# Note: Don't check TEST_PID - xcodebuild exits early, spawning test runner as subprocess
while [ ! -f /tmp/clipkitty_demo_stop.txt ] && [ $STOP_WAIT_COUNT -lt 120 ]; do
    sleep 0.5
    STOP_WAIT_COUNT=$((STOP_WAIT_COUNT + 1))
done
DEMO_END_TIME=$(date +%s)
DEMO_DURATION=$((DEMO_END_TIME - DEMO_START_TIME + 2))  # Add 2s buffer
echo "Demo completed in approximately ${DEMO_DURATION}s"

# Signal to stop recording (screencapture -V may not respond, but we'll trim in post)
echo ""
echo "Demo finished, waiting for recording to complete..."
# Try INT signal, but screencapture -V often ignores it and runs full duration
kill -INT $RECORD_PID 2>/dev/null || true

# Clean up marker files
rm -f /tmp/clipkitty_demo_stop.txt
rm -f /tmp/clipkitty_screenshot_db.txt

# Finish waiting for test process if still running
wait $TEST_PID 2>/dev/null || true

# Give screencapture a moment to flush the file
sleep 0.1
wait $RECORD_PID 2>/dev/null || true

# Check if recording was captured
if [ ! -f "$RAW_VIDEO" ]; then
    echo "Error: Failed to capture video"
    exit 1
fi

if $HAS_FFMPEG; then
    echo "Post-processing video..."

    # Get raw video duration
    DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$RAW_VIDEO" 2>/dev/null | cut -d. -f1)
    echo "Raw video duration: ${DURATION}s"

    # Note: App Store allows 15-30s videos
    echo "Video duration: ${DURATION}s (App Store limit: 30s)"

    # Check for window bounds file (written by the UI test)
    BOUNDS_FILE="/tmp/clipkitty_window_bounds.txt"
    CROP_FILTER=""
    if [ -f "$BOUNDS_FILE" ]; then
        BOUNDS=$(cat "$BOUNDS_FILE")
        echo "Window bounds: $BOUNDS"
        # Parse x,y,width,height
        CROP_X=$(echo "$BOUNDS" | cut -d, -f1)
        CROP_Y=$(echo "$BOUNDS" | cut -d, -f2)
        CROP_W=$(echo "$BOUNDS" | cut -d, -f3)
        CROP_H=$(echo "$BOUNDS" | cut -d, -f4)
        # Create crop filter (note: ffmpeg crop is crop=w:h:x:y)
        CROP_FILTER="crop=${CROP_W}:${CROP_H}:${CROP_X}:${CROP_Y},"
        echo "Cropping to window: ${CROP_W}x${CROP_H}+${CROP_X}+${CROP_Y}"
        rm -f "$BOUNDS_FILE"
    else
        echo "No window bounds file found, using full screen"
    fi

    # Post-process:
    # - Crop to window bounds (if available)
    # - Use demo duration (not full recording), capped at 30s for App Store
    # - Ensure proper encoding for App Store (H.264, AAC)
    # - Scale to App Store dimensions (2880x1800 or 1280x800)
    # Use the shorter of: demo duration, raw video duration, or 30s App Store limit
    TRIM_DURATION=$DEMO_DURATION
    [ "$DURATION" -lt "$TRIM_DURATION" ] 2>/dev/null && TRIM_DURATION=$DURATION
    [ "$TRIM_DURATION" -gt 30 ] && TRIM_DURATION=30
    echo "Trimming to ${TRIM_DURATION}s (demo: ${DEMO_DURATION}s, raw: ${DURATION}s, limit: 30s)"
    ffmpeg -y -i "$RAW_VIDEO" \
        -t $TRIM_DURATION \
        -vf "${CROP_FILTER}scale=2880:1800:force_original_aspect_ratio=decrease,pad=2880:1800:(ow-iw)/2:(oh-ih)/2:color=gray" \
        -c:v libx264 -preset slow -crf 18 -profile:v high -level 4.0 \
        -pix_fmt yuv420p \
        -movflags +faststart \
        -an \
        "$FINAL_VIDEO"

    # Clean up raw video
    rm -f "$RAW_VIDEO"

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
else
    # No ffmpeg — just move the raw recording as-is
    mv "$RAW_VIDEO" "$FINAL_VIDEO"
    FILE_SIZE=$(ls -lh "$FINAL_VIDEO" | awk '{print $5}')

    echo ""
    echo "=== Video Recording Complete (raw, no post-processing) ==="
    echo "Output: $FINAL_VIDEO"
    echo "Size: $FILE_SIZE"
    echo ""
    echo "Install ffmpeg for crop/scale/trim: brew install ffmpeg"
fi

echo "Closing ClipKitty..."
osascript -e 'quit app "ClipKitty"'
sleep 2
