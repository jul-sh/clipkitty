#!/bin/bash
# Records an App Store preview video of ClipKitty's search functionality
# Uses cliclick for UI automation (no XCUITest "Automation Running" overlay)
# Requires: ffmpeg (brew install ffmpeg), cliclick (brew install cliclick)
# Output: marketing/app_preview.mov (H.264, 30fps, ready for App Store)
#
# NOTE: You must grant permissions:
#   1. Terminal needs Screen Recording: System Settings > Privacy & Security > Screen Recording
#   2. Terminal needs Accessibility: System Settings > Privacy & Security > Accessibility

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_ROOT/marketing"
RAW_VIDEO="/tmp/clipkitty_raw_preview.mov"
FINAL_VIDEO="$OUTPUT_DIR/app_preview.mov"
APP_PATH="$PROJECT_ROOT/ClipKitty.app"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Check for required tools
if ! command -v ffmpeg &> /dev/null; then
    echo "Error: ffmpeg is required. Install with: brew install ffmpeg"
    exit 1
fi

if ! command -v cliclick &> /dev/null; then
    echo "Error: cliclick is required. Install with: brew install cliclick"
    exit 1
fi

# Check app exists
if [ ! -d "$APP_PATH" ]; then
    echo "Error: ClipKitty.app not found. Run 'make' first."
    exit 1
fi

echo "=== ClipKitty App Store Preview Video Recording ==="
echo "(Using cliclick - no automation overlay)"
echo ""

# Get screen dimensions for recording
SCREEN_WIDTH=$(system_profiler SPDisplaysDataType | grep Resolution | head -1 | awk '{print $2}')
SCREEN_HEIGHT=$(system_profiler SPDisplaysDataType | grep Resolution | head -1 | awk '{print $4}')
echo "Screen resolution: ${SCREEN_WIDTH}x${SCREEN_HEIGHT}"

# Clean up
rm -f "$RAW_VIDEO"
echo "Cleaning up previous app instances..."
pkill -9 ClipKitty 2>/dev/null || true
sleep 0.5

echo ""
echo "NOTE: If this fails, ensure Terminal has:"
echo "  - Screen Recording permission"
echo "  - Accessibility permission (for cliclick)"
echo ""

# Launch the app with simulated database
echo "Launching ClipKitty..."
open -a "$APP_PATH" --args --use-simulated-db
sleep 3

# Make sure the app is frontmost
osascript -e 'tell application "ClipKitty" to activate' 2>/dev/null || true
sleep 0.5

# Get window bounds for cropping (using AppleScript)
echo "Getting window bounds..."
BOUNDS_FILE="/tmp/clipkitty_window_bounds.txt"
rm -f "$BOUNDS_FILE"
if system_profiler SPDisplaysDataType | grep -q "Retina"; then
    echo "Detected Retina display. Using 2x scale factor."
    SCALE_FACTOR=2
else
    echo "Detected non-Retina display. Using 1x scale factor."
    SCALE_FACTOR=1
fi

if [ -n "$CI" ]; then
    echo "Detected CI environment. Forcing 1x scale."
    SCALE_FACTOR=1
fi

osascript -e 'tell application "System Events"
    tell process "ClipKitty"
        set win to first window
        set {x, y} to position of win
        set {w, h} to size of win

        -- Use dynamic scale factor passed from bash
        set scaleFactor to '$SCALE_FACTOR'

        -- Scale padding logic
        set padding to 40

        -- Calculate pixel coordinates
        set px to (x * scaleFactor) - padding
        set py to (y * scaleFactor) - padding
        set pw to (w * scaleFactor) + (padding * 2)
        set ph to (h * scaleFactor) + (padding * 2)

        if px < 0 then set px to 0
        if py < 0 then set py to 0

        return (px as integer as text) & "," & (py as integer as text) & "," & (pw as integer as text) & "," & (ph as integer as text)
    end tell
end tell' > "$BOUNDS_FILE" 2>/dev/null || true

if [ -s "$BOUNDS_FILE" ]; then
    echo "Window bounds: $(cat $BOUNDS_FILE)"
else
    echo "Warning: Could not get window bounds"
fi

# Calculate demo duration for recording
# Initial: 1s, "meeting": 7*0.2=1.4s, pause: 1.5s, arrows: 1.8s,
# select: 0.3s, "http": 4*0.2=0.8s, final: 2s = ~9s + 3s buffer
DEMO_DURATION=15

# Use macOS screencapture for recording (timed mode, starts immediately)
echo "Starting screen recording (${DEMO_DURATION}s)..."
screencapture -V $DEMO_DURATION "$RAW_VIDEO" &
RECORD_PID=$!
sleep 1

# Initial pause to show the app
sleep 1

# Run the demo using cliclick
echo "Running demo..."

# Type "meeting" character by character with delays
for char in m e e t i n g; do
    cliclick -w 50 "t:$char"
    sleep 0.2
done

# Pause to show results
sleep 1.5

# Navigate with arrow keys
cliclick -w 50 kp:arrow-down
sleep 0.5
cliclick -w 50 kp:arrow-down
sleep 0.5
cliclick -w 50 kp:arrow-up
sleep 0.8

# Select all and type new search
cliclick -w 50 kd:cmd t:a ku:cmd
sleep 0.3

# Type "http" character by character
for char in h t t p; do
    cliclick -w 50 "t:$char"
    sleep 0.2
done

# Final pause
sleep 2

# Stop recording (screencapture will auto-stop at DEMO_DURATION)
echo ""
echo "Stopping recording..."
kill -INT $RECORD_PID 2>/dev/null || true
wait $RECORD_PID 2>/dev/null || true

# Close the app
pkill ClipKitty 2>/dev/null || true

# Check if recording was captured
if [ ! -f "$RAW_VIDEO" ]; then
    echo "Error: Failed to capture video"
    exit 1
fi

echo "Post-processing video..."

# Get raw video duration
DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$RAW_VIDEO" 2>/dev/null | cut -d. -f1)
echo "Raw video duration: ${DURATION}s"

# Check for window bounds file
CROP_FILTER=""
if [ -f "$BOUNDS_FILE" ] && [ -s "$BOUNDS_FILE" ]; then
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
# - Use actual video duration (capped at 30s for App Store)
# - Ensure proper encoding for App Store (H.264)
# - Scale to App Store dimensions (2880x1800)
MAX_DURATION=$((DURATION > 30 ? 30 : DURATION))
ffmpeg -y -i "$RAW_VIDEO" \
    -t $MAX_DURATION \
    -vf "${CROP_FILTER}scale=2880:1800:force_original_aspect_ratio=decrease,pad=2880:1800:(ow-iw)/2:(oh-ih)/2:color=gray" \
    -c:v libx264 -preset slow -crf 18 -profile:v high -level 4.0 \
    -pix_fmt yuv420p \
    -movflags +faststart \
    -an \
    "$FINAL_VIDEO"

# Clean up raw video
rm -f "$RAW_VIDEO"

# Get final video info
FINAL_DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$FINAL_VIDEO" 2>/dev/null | cut -d. -f1)
FILE_SIZE=$(ls -lh "$FINAL_VIDEO" | awk '{print $5}')

echo ""
echo "=== Video Recording Complete ==="
echo "Output: $FINAL_VIDEO"
echo "Duration: ${FINAL_DURATION}s"
echo "Size: $FILE_SIZE"
echo ""
echo "App Store Requirements:"
echo "  - Duration: 15-30 seconds (yours: ${FINAL_DURATION}s)"
echo "  - Format: H.264 .mov ✓"
echo "  - Resolution: 2880x1800 ✓"
echo "  - Max size: 500MB (yours: $FILE_SIZE)"
