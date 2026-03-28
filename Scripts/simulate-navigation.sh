#!/bin/bash
# Simulate selection navigation in ClipKitty using AppleScript.

set -e

# Defaults
DELAY_MS=100
COUNT=20

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --delay)
            DELAY_MS="$2"
            shift 2
            ;;
        --count)
            COUNT="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

DELAY_SECONDS=$(echo "scale=3; $DELAY_MS / 1000" | bc)

echo "=== ClipKitty Navigation Simulation ==="
echo "Navigation delay: ${DELAY_MS}ms"
echo "Navigation count: ${COUNT}"
echo ""

if ! pgrep -x ClipKitty > /dev/null; then
    echo "Error: ClipKitty is not running"
    exit 1
fi

osascript <<EOF
tell application "System Events"
    tell application process "ClipKitty"
        set frontmost to true
    end tell

    delay 1.0

    -- Navigate Down
    repeat $COUNT times
        key code 125 -- Arrow Down
        delay $DELAY_SECONDS
    end repeat

    -- Navigate Up
    repeat $COUNT times
        key code 126 -- Arrow Up
        delay $DELAY_SECONDS
    end repeat
end tell
EOF

echo ""
echo "=== Navigation simulation complete ==="
