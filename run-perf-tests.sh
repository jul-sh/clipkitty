#!/bin/bash

# ClippySwift Performance Test Runner
# Usage: ./run-perf-tests.sh [size_in_GB]
# Example: ./run-perf-tests.sh 0.1   # 100MB test
#          ./run-perf-tests.sh 3     # 3GB test (default)

set -e

SIZE_GB="${1:-3}"

echo "Running performance tests (target: ${SIZE_GB}GB database)..."
echo ""

swift run -c release PerformanceTests "$SIZE_GB"

echo ""
echo "Done!"
