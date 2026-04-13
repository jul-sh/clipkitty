#!/usr/bin/env bash
#
# Materialise the Tuist-generated workspace/xcodeproj into the repo root so
# any follow-up xcodebuild invocation (CI's iOS smoke build, UI tests,
# screenshot tests, Xcode.app itself) finds the project files on disk.
#
# The generation runs inside the `clipkitty-generated` nix derivation, so CI
# and dev share the same Tuist invocation. This script only copies the
# outputs back into the working tree.

set -euo pipefail

APP_NAME="ClipKitty"

echo "Materialising generated Xcode project via nix..."
nix build .#clipkitty-generated --out-link result-generated

rm -rf "$APP_NAME.xcworkspace" "$APP_NAME.xcodeproj" Tuist/.build
cp -R "result-generated/$APP_NAME.xcworkspace" ./
cp -R "result-generated/$APP_NAME.xcodeproj" ./
if [ -d result-generated/Tuist/.build ]; then
  mkdir -p Tuist
  cp -R result-generated/Tuist/.build Tuist/.build
fi

chmod -R u+w "$APP_NAME.xcworkspace" "$APP_NAME.xcodeproj" Tuist/.build 2>/dev/null || true
