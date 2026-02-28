#!/bin/bash
#
# Run performance UI tests with Instruments tracing.
#
# This script:
# 1. Builds the app and test bundle
# 2. Generates a performance test database (if needed)
# 3. Launches the app
# 4. Starts xctrace recording
# 5. Runs the performance UI tests
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
#
# Examples:
#   ./Scripts/run-perf-test.sh
#   ./Scripts/run-perf-test.sh --skip-build --fail-on-hangs
#   ./Scripts/run-perf-test.sh --template "System Trace" --output /tmp/traces
#

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DERIVED_DATA="$PROJECT_ROOT/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/ClipKitty.app"

# Defaults
SKIP_BUILD=false
SKIP_DB_GEN=false
TRACE_ONLY=false
TEMPLATE="Time Profiler"
OUTPUT_DIR="$PROJECT_ROOT/perf_traces"
HANG_THRESHOLD=250
FAIL_ON_HANGS=false
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
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Step 1: Build
if [ "$SKIP_BUILD" = false ]; then
    echo ">>> Building app and tests..."
    cd "$PROJECT_ROOT"
    make all

    # Build test bundle
    xcodebuild build-for-testing \
        -scheme ClipKittyUITests \
        -destination "platform=macOS" \
        -derivedDataPath "$DERIVED_DATA" \
        -quiet

    echo "    Build complete."
else
    echo ">>> Skipping build (--skip-build)"
fi

# Step 2: Generate performance database
if [ "$SKIP_DB_GEN" = false ]; then
    PERF_DB="$PROJECT_ROOT/distribution/SyntheticData_perf.sqlite"
    if [ ! -f "$PERF_DB" ]; then
        echo ">>> Generating performance test database..."
        python3 "$SCRIPT_DIR/generate-perf-db.py"
    else
        echo ">>> Using existing performance database: $PERF_DB"
    fi
else
    echo ">>> Skipping database generation (--skip-db-gen)"
fi

# Step 3: Kill any existing instances
echo ">>> Terminating existing ClipKitty instances..."
pkill -9 ClipKitty 2>/dev/null || true
sleep 1

# Step 4: Launch app
echo ">>> Launching ClipKitty..."
open "$APP_PATH" --args --use-simulated-db
sleep 3

# Verify app is running
if ! pgrep -x ClipKitty > /dev/null; then
    echo "Error: ClipKitty failed to launch"
    exit 1
fi

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
sleep 2

# Step 6: Run performance tests
echo ">>> Running performance UI tests..."

TEST_RESULT=0
xcodebuild test-without-building \
    -scheme ClipKittyUITests \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    -only-testing:ClipKittyUITests/PerformanceTests \
    2>&1 | tee "$OUTPUT_DIR/test_output_${TIMESTAMP}.log" || TEST_RESULT=$?

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

    python3 "$SCRIPT_DIR/analyze-trace.py" "$TRACE_FILE" $ANALYSIS_ARGS
    ANALYSIS_RESULT=$?

    # Save JSON report
    python3 "$SCRIPT_DIR/analyze-trace.py" "$TRACE_FILE" $ANALYSIS_ARGS --json > "$OUTPUT_DIR/report_${TIMESTAMP}.json"

    echo ""
    echo ">>> Reports saved:"
    echo "    Trace: $TRACE_FILE"
    echo "    JSON:  $OUTPUT_DIR/report_${TIMESTAMP}.json"
    echo "    Log:   $OUTPUT_DIR/test_output_${TIMESTAMP}.log"

    # Return appropriate exit code
    if [ "$FAIL_ON_HANGS" = true ] && [ $ANALYSIS_RESULT -ne 0 ]; then
        echo ""
        echo "❌ Performance test FAILED: Hangs detected"
        exit 1
    fi
fi

if [ $TEST_RESULT -ne 0 ]; then
    echo ""
    echo "⚠️  UI tests reported failures (exit code: $TEST_RESULT)"
    echo "    Check test output for details."
fi

echo ""
echo "✅ Performance test complete"
