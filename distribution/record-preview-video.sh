#!/bin/bash
# Records a video of ClipKitty via a UI test.
# Uses Xcode's built-in UI test screen recording (xcresult bundle) instead of
# screencapture, so no TCC Screen Recording permission is needed.
# ffmpeg is provided via the Nix dev shell (flake.nix).
#
# Usage:
#   ./record-preview-video.sh --db SyntheticData_video.sqlite --output intro_video.mov --duration 50

set -e

# ── Argument parsing ─────────────────────────────────────────────────────────
TEST_NAME="testRecordIntroVideo"
DB_NAME=""
OUTPUT_NAME="app_preview.mov"
MAX_DURATION=30

while [[ $# -gt 0 ]]; do
    case "$1" in
        --test)      TEST_NAME="$2";       shift 2 ;;
        --db)        DB_NAME="$2";         shift 2 ;;
        --output)    OUTPUT_NAME="$2";     shift 2 ;;
        --duration)  MAX_DURATION="$2";    shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_ROOT/marketing"
FINAL_VIDEO="$OUTPUT_DIR/$OUTPUT_NAME"
RESULT_BUNDLE="/tmp/clipkitty_video_result.xcresult"
ATTACHMENTS_DIR="/tmp/xcresult-attachments"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Resolve ffmpeg: direct, or via Nix dev shell
NIX_SHELL="$PROJECT_ROOT/Scripts/run-in-nix.sh"
HAS_FFMPEG=false
if command -v ffmpeg &> /dev/null; then
    HAS_FFMPEG=true
elif [ -x "$NIX_SHELL" ]; then
    HAS_FFMPEG=true
    # Wrap ffmpeg so bare invocations go through Nix
    ffmpeg() { "$NIX_SHELL" -c "ffmpeg $(printf '%q ' "$@")"; }
    echo "Using ffmpeg from Nix dev shell"
else
    echo "Note: ffmpeg not found. Will output raw recording (no crop/scale)."
    echo ""
fi

echo "=== ClipKitty Video Recording ==="
echo "  Test:         $TEST_NAME"
echo "  DB:           ${DB_NAME:-<default>}"
echo "  Output:       $OUTPUT_NAME"
echo "  Max duration: ${MAX_DURATION}s"
echo ""

# Set up code signing (needed for stable TCC permissions across builds)
"$SCRIPT_DIR/setup-dev-signing.sh"

# Log screen dimensions (informational only)
SCREEN_RES=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -i "Resolution" | head -1 | sed 's/.*: //' || echo "unknown")
echo "Screen resolution: ${SCREEN_RES:-unknown}"


# Close ClipKitty if it's running to ensure a clean state
if pgrep -x "ClipKitty" > /dev/null; then
    echo "Closing ClipKitty..."
    osascript -e 'quit app "ClipKitty"'
    sleep 2
fi


# Clean up stale state
rm -rf "$RESULT_BUNDLE"
rm -rf "$ATTACHMENTS_DIR"

# Write DB selection file if a custom DB was specified
if [ -n "$DB_NAME" ]; then
    echo "$DB_NAME" > /tmp/clipkitty_screenshot_db.txt
else
    rm -f /tmp/clipkitty_screenshot_db.txt
fi

echo "Running UI test (video will be captured in xcresult bundle)..."
# Clean stale codesign temp files that cause "invalid or unsupported format for signature"
# errors. These .cstemp files are left behind when a previous codesign is interrupted, and
# xcodebuild's parallel CopySwiftLibs + CodeSign can race to produce them.
# Nuke the entire UITests runner to force a fresh copy of system frameworks.
rm -rf "$PROJECT_ROOT/DerivedData/Build/Products/Debug/ClipKittyUITests-Runner.app" 2>/dev/null || true
find "$PROJECT_ROOT/DerivedData" -name "*.cstemp" -delete 2>/dev/null || true

# Run the test in foreground — Xcode automatically records the screen into the
# xcresult bundle, so no separate screencapture process is needed.
cd "$PROJECT_ROOT"
set +e
xcodebuild test \
    -workspace ClipKitty.xcworkspace \
    -scheme ClipKittyUITests \
    -testPlan ClipKittyVideoRecording \
    -destination 'platform=macOS' \
    -derivedDataPath DerivedData \
    -resultBundlePath "$RESULT_BUNDLE" \
    ${SKIP_SIGNING:+CODE_SIGNING_ALLOWED=NO} \
    -only-testing:ClipKittyUITests/ClipKittyUITests/$TEST_NAME \
    2>&1 | grep -E "(Test Case|passed|failed)"
XCODEBUILD_EXIT=$?
set -e

# Clean up DB selection file
rm -f /tmp/clipkitty_screenshot_db.txt

echo "Test complete (exit code: $XCODEBUILD_EXIT). Extracting video from xcresult bundle..."

# ── Extract screen recording from xcresult bundle ───────────────────────────
if [ ! -d "$RESULT_BUNDLE" ]; then
    echo "Error: xcresult bundle not found at $RESULT_BUNDLE"
    exit 1
fi

mkdir -p "$ATTACHMENTS_DIR"
xcrun xcresulttool export attachments \
    --path "$RESULT_BUNDLE" \
    --output-path "$ATTACHMENTS_DIR"

# Find the screen recording video (.mov or .mp4) in the exported attachments
RAW_VIDEO=""
if [ -f "$ATTACHMENTS_DIR/manifest.json" ]; then
    RAW_VIDEO=$(python3 -c "
import json, sys, os
manifest = json.load(open('$ATTACHMENTS_DIR/manifest.json'))
for test in manifest:
    for att in test.get('attachments', []):
        fname = att.get('exportedFileName', '')
        if fname.endswith('.mov') or fname.endswith('.mp4'):
            print(os.path.join('$ATTACHMENTS_DIR', fname))
            sys.exit(0)
print('')
")
fi

# Fallback: find any video file in the directory
if [ -z "$RAW_VIDEO" ] || [ ! -f "$RAW_VIDEO" ]; then
    RAW_VIDEO=$(find "$ATTACHMENTS_DIR" \( -name "*.mov" -o -name "*.mp4" \) -type f | head -1)
fi

if [ -z "$RAW_VIDEO" ] || [ ! -f "$RAW_VIDEO" ]; then
    echo "Error: No screen recording video found in xcresult attachments"
    echo "Attachments directory contents:"
    ls -la "$ATTACHMENTS_DIR" 2>/dev/null || echo "  (empty)"
    if [ -f "$ATTACHMENTS_DIR/manifest.json" ]; then
        echo "manifest.json:"
        cat "$ATTACHMENTS_DIR/manifest.json"
    fi
    exit 1
fi

echo "Found screen recording: $RAW_VIDEO"

# ── Post-process with ffmpeg ────────────────────────────────────────────────
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

    # Check for start-offset file (written by the UI test when setup finishes
    # and demo scenes begin). This lets us skip the setup portion of the recording.
    OFFSET_FILE="/tmp/clipkitty_video_start_offset.txt"
    START_OFFSET="0"
    if [ -f "$OFFSET_FILE" ]; then
        START_OFFSET=$(cat "$OFFSET_FILE")
        echo "Skipping ${START_OFFSET}s of setup (offset from UI test)"
        rm -f "$OFFSET_FILE"
    fi

    # Post-process:
    # - Skip setup portion (-ss)
    # - Crop to window bounds (if available)
    # - Cap duration at App Store limit (30s max after skipping setup)
    # - Ensure proper encoding for App Store (H.264)
    # - Scale to 1920x1080
    CONTENT_DURATION=$(echo "$DURATION - $START_OFFSET" | bc)
    TRIM_DURATION=$CONTENT_DURATION
    [ "$(echo "$TRIM_DURATION > $MAX_DURATION" | bc)" -eq 1 ] 2>/dev/null && TRIM_DURATION=$MAX_DURATION
    [ "$(echo "$TRIM_DURATION > 30" | bc)" -eq 1 ] && TRIM_DURATION=30
    echo "Trimming to ${TRIM_DURATION}s (raw: ${DURATION}s, offset: ${START_OFFSET}s, limit: 30s)"
    # App Store Connect rejects previews without an audio track, so mux in silence.
    ffmpeg -y -ss "$START_OFFSET" -i "$RAW_VIDEO" \
        -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
        -t $TRIM_DURATION \
        -vf "${CROP_FILTER}scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=0xC0C0C0" \
        -c:v libx264 -preset slow -crf 18 -profile:v high -level 4.0 \
        -pix_fmt yuv420p \
        -c:a aac -b:a 128k -ar 44100 -ac 2 \
        -shortest \
        -movflags +faststart \
        "$FINAL_VIDEO"

    # Clean up
    rm -rf "$ATTACHMENTS_DIR" "$RESULT_BUNDLE"

    FILE_SIZE=$(ls -lh "$FINAL_VIDEO" | awk '{print $5}')

    echo ""
    echo "=== Video Recording Complete ==="
    echo "Output: $FINAL_VIDEO"
    echo "Size: $FILE_SIZE"
    echo ""
    echo "App Store Requirements:"
    echo "  - Duration: 15-30 seconds"
    echo "  - Format: H.264 .mov"
    echo "  - Resolution: 1920x1080"
    echo "  - Max size: 500MB (yours: $FILE_SIZE)"
else
    # No ffmpeg — just copy the raw recording as-is
    cp "$RAW_VIDEO" "$FINAL_VIDEO"
    rm -rf "$ATTACHMENTS_DIR" "$RESULT_BUNDLE"

    FILE_SIZE=$(ls -lh "$FINAL_VIDEO" | awk '{print $5}')

    echo ""
    echo "=== Video Recording Complete (raw, no post-processing) ==="
    echo "Output: $FINAL_VIDEO"
    echo "Size: $FILE_SIZE"
    echo ""
    echo "Install ffmpeg or use Nix dev shell for crop/scale/trim"
fi

echo "Closing ClipKitty..."
osascript -e 'quit app "ClipKitty"'
sleep 2
