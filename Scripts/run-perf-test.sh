#!/bin/bash
#
# Run performance tests with Instruments tracing.
#
# This script:
# 1. Builds the app in Release mode
# 2. Sets up a performance test database with large items
# 3. Launches the app
# 4. Starts xctrace recording
# 5. Simulates rapid typing via AppleScript
# 6. Stops tracing and analyzes results
#
# Usage:
#   ./Scripts/run-perf-test.sh [options]
#
# Options:
#   --skip-build      Skip building (use existing build)
#   --skip-db-gen     Skip database generation
#   --trace-only      Only capture trace, don't run analysis
#   --template NAME   Instruments template (default: "Time Profiler")
#   --output DIR      Output directory for traces (default: perf_traces)
#   --hang-threshold  Hang threshold in ms (default: 250)
#   --fail-on-hangs   Exit with code 1 if hangs detected
#   --typing-delay    Delay between keystrokes in ms (default: 50)
#
# Examples:
#   ./Scripts/run-perf-test.sh
#   ./Scripts/run-perf-test.sh --skip-build --fail-on-hangs
#   ./Scripts/run-perf-test.sh --template "System Trace"
#

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DERIVED_DATA="$PROJECT_ROOT/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Release/ClipKitty.app"
BUNDLE_ID="com.eviljuliette.clipkitty"

# Defaults
SKIP_BUILD=false
SKIP_DB_GEN=false
TRACE_ONLY=false
TEMPLATE="Time Profiler"
OUTPUT_DIR="$PROJECT_ROOT/perf_traces"
HANG_THRESHOLD=250
FAIL_ON_HANGS=false
TYPING_DELAY=50
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-db-gen)
            SKIP_DB_GEN=true
            shift
            ;;
        --trace-only)
            TRACE_ONLY=true
            shift
            ;;
        --template)
            TEMPLATE="$2"
            shift 2
            ;;
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --hang-threshold)
            HANG_THRESHOLD="$2"
            shift 2
            ;;
        --fail-on-hangs)
            FAIL_ON_HANGS=true
            shift
            ;;
        --typing-delay)
            TYPING_DELAY="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

TRACE_FILE="$OUTPUT_DIR/perf_${TIMESTAMP}.trace"

echo "=== ClipKitty Performance Test ==="
echo "Template: $TEMPLATE"
echo "Output: $TRACE_FILE"
echo "Typing delay: ${TYPING_DELAY}ms"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Step 1: Build Release
if [ "$SKIP_BUILD" = false ]; then
    echo ">>> Building app (Release)..."
    cd "$PROJECT_ROOT"
    make all CONFIGURATION=Release
    echo "    Build complete."
else
    echo ">>> Skipping build (--skip-build)"
fi

# Verify app exists
if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at $APP_PATH"
    echo "Try running without --skip-build"
    exit 1
fi

# Step 2: Generate performance database
PERF_DB="$PROJECT_ROOT/distribution/SyntheticData_perf.sqlite"
if [ "$SKIP_DB_GEN" = false ]; then
    if [ ! -f "$PERF_DB" ]; then
        echo ">>> Generating performance test database..."
        # Use native Rust code to ensure schema compatibility
        "$PROJECT_ROOT/Scripts/run-in-nix.sh" -c "cd purr && cargo run --release --bin generate-perf-db"
    else
        echo ">>> Using existing performance database"
    fi
else
    echo ">>> Skipping database generation (--skip-db-gen)"
fi

# Step 3: Set up database in app container
echo ">>> Setting up test database..."
APP_SUPPORT_DIR="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Application Support/ClipKitty"
mkdir -p "$APP_SUPPORT_DIR"

# Kill any existing instance
pkill -9 ClipKitty 2>/dev/null || true
sleep 1

# Clean up existing data
rm -f "$APP_SUPPORT_DIR/clipboard-screenshot.sqlite"*
rm -rf "$APP_SUPPORT_DIR/tantivy_index_v3"

# Copy performance database
if [ -f "$PERF_DB" ]; then
    cp "$PERF_DB" "$APP_SUPPORT_DIR/clipboard-screenshot.sqlite"
    echo "    Database copied to app container"
else
    echo "Warning: Performance database not found, using empty database"
fi

# Step 4: Launch app
echo ">>> Launching ClipKitty..."
open "$APP_PATH" --args --use-simulated-db
sleep 3

# Verify app is running
if ! pgrep -x ClipKitty > /dev/null; then
    echo "Error: ClipKitty failed to launch"
    exit 1
fi
echo "    App running (PID: $(pgrep -x ClipKitty))"

# Step 5: Start xctrace recording
echo ">>> Starting Instruments trace (template: $TEMPLATE)..."
xcrun xctrace record \
    --template "$TEMPLATE" \
    --attach "ClipKitty" \
    --output "$TRACE_FILE" \
    --time-limit 120s &

XCTRACE_PID=$!
echo "    xctrace PID: $XCTRACE_PID"

# Give xctrace time to attach
sleep 3

# Step 6: Run typing simulation
echo ">>> Running typing simulation..."
"$SCRIPT_DIR/simulate-typing.sh" --delay "$TYPING_DELAY" 2>&1 | tee "$OUTPUT_DIR/typing_log_${TIMESTAMP}.txt"

# Step 7: Stop trace
echo ">>> Stopping trace..."
sleep 2
kill -SIGINT "$XCTRACE_PID" 2>/dev/null || true

# Wait for xctrace to finish writing
WAIT_COUNT=0
while kill -0 "$XCTRACE_PID" 2>/dev/null && [ $WAIT_COUNT -lt 30 ]; do
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

# Force kill if still running
kill -9 "$XCTRACE_PID" 2>/dev/null || true

# Terminate app
echo ">>> Terminating ClipKitty..."
pkill -9 ClipKitty 2>/dev/null || true

echo ""
echo ">>> Trace saved: $TRACE_FILE"
ls -lh "$TRACE_FILE"

# Step 8: Analyze trace
if [ "$TRACE_ONLY" = false ]; then
    echo ""
    echo ">>> Analyzing trace..."

    ANALYSIS_ARGS="--hang-threshold $HANG_THRESHOLD"
    if [ "$FAIL_ON_HANGS" = true ]; then
        ANALYSIS_ARGS="$ANALYSIS_ARGS --fail-on-hangs"
    fi

    python3 "$SCRIPT_DIR/analyze-trace.py" "$TRACE_FILE" $ANALYSIS_ARGS || ANALYSIS_RESULT=$?

    # Save JSON report
    python3 "$SCRIPT_DIR/analyze-trace.py" "$TRACE_FILE" --json > "$OUTPUT_DIR/report_${TIMESTAMP}.json" 2>/dev/null || true

    echo ""
    echo ">>> Reports saved:"
    echo "    Trace: $TRACE_FILE"
    echo "    JSON:  $OUTPUT_DIR/report_${TIMESTAMP}.json"
    echo "    Log:   $OUTPUT_DIR/typing_log_${TIMESTAMP}.txt"

    # Return appropriate exit code
    if [ "$FAIL_ON_HANGS" = true ] && [ "${ANALYSIS_RESULT:-0}" -ne 0 ]; then
        echo ""
        echo "Performance test FAILED: Hangs detected"
        exit 1
    fi
fi

echo ""
echo "Performance test complete"
