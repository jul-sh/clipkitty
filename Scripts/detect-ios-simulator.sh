#!/usr/bin/env bash
# Detect the latest available iOS simulator device and OS version.
# Usage:
#   ./detect-ios-simulator.sh device   # prints device type, e.g. "iPhone 17 Pro"
#   ./detect-ios-simulator.sh os       # prints OS version, e.g. "26.4"
#
# Used by bazel/runners/BUILD.bazel via a genrule to avoid hardcoding
# simulator versions that break on Xcode updates.

set -euo pipefail

case "${1:-}" in
  device)
    # Pick the latest Pro iPhone model available
    xcrun simctl list devicetypes -j \
      | python3 -c "
import json, sys, re
types = json.load(sys.stdin)['devicetypes']
iphones = [t for t in types if re.match(r'iPhone \d+ Pro$', t['name'])]
if iphones:
    print(iphones[-1]['name'])
else:
    # Fallback: any iPhone
    phones = [t for t in types if t['name'].startswith('iPhone')]
    print(phones[-1]['name'] if phones else 'iPhone 17 Pro')
"
    ;;
  os)
    xcrun simctl list runtimes -j \
      | python3 -c "
import json, sys
runtimes = json.load(sys.stdin)['runtimes']
ios = [r for r in runtimes if r['platform'] == 'iOS' and r['isAvailable']]
if ios:
    print(ios[-1]['version'])
else:
    print('26.4')
"
    ;;
  *)
    echo "Usage: $0 {device|os}" >&2
    exit 1
    ;;
esac
