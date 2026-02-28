#!/bin/bash
#
# Simulate rapid typing in ClipKitty's search field using AppleScript.
#
# This simulates realistic user typing without XCUITest overhead,
# allowing accurate measurement of UI responsiveness via Instruments.
#
# Usage:
#   ./Scripts/simulate-typing.sh [--delay MS] [--queries "q1,q2,q3"]
#
# Options:
#   --delay MS     Delay between keystrokes in milliseconds (default: 50)
#   --queries STR  Comma-separated list of queries (default: built-in set)
#
# Requirements:
#   - ClipKitty must be running and have accessibility permissions
#   - System Preferences > Privacy & Security > Accessibility must include Terminal
#

set -e

# Defaults
KEYSTROKE_DELAY_MS=50
QUERIES="function,import,return value,error handling,async await,class struct,for loop"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --delay)
            KEYSTROKE_DELAY_MS="$2"
            shift 2
            ;;
        --queries)
            QUERIES="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Convert ms to seconds for AppleScript
DELAY_SECONDS=$(echo "scale=3; $KEYSTROKE_DELAY_MS / 1000" | bc)

echo "=== ClipKitty Typing Simulation ==="
echo "Keystroke delay: ${KEYSTROKE_DELAY_MS}ms"
echo "Queries: $QUERIES"
echo ""

# Check if ClipKitty is running
if ! pgrep -x ClipKitty > /dev/null; then
    echo "Error: ClipKitty is not running"
    exit 1
fi

# Activate ClipKitty and simulate typing
osascript <<EOF
tell application "System Events"
    -- Activate ClipKitty
    tell application process "ClipKitty"
        set frontmost to true
    end tell

    delay 0.5

    -- Split queries by comma
    set queryList to {"function", "import", "return value", "error handling", "async await", "class struct", "for loop"}

    repeat with query in queryList
        -- Clear search field (Cmd+A, Delete)
        keystroke "a" using command down
        delay 0.05
        key code 51 -- Delete
        delay 0.1

        -- Type each character with delay
        set queryChars to characters of query
        repeat with c in queryChars
            keystroke c
            delay $DELAY_SECONDS
        end repeat

        -- Pause between queries
        delay 0.3
    end repeat

    -- Final clear
    keystroke "a" using command down
    delay 0.05
    key code 51
end tell
EOF

echo ""
echo "=== Typing simulation complete ==="
