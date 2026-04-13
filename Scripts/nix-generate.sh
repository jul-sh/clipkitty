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

# Materialise the Rust Xcode overlay files that `purrXcodeOverlay`
# produces inside the derivation: purrFFI.h, the swift wrapper,
# libpurr.a, and the ios-device/ios-simulator staging trees. Xcode
# references these by on-disk path, so they must exist in the checkout
# for bare-xcodebuild steps (iOS AppStore build, UI tests, screenshot
# tests) to resolve them. The repo also tracks some hand-written files
# (ClipKittyRustFFI.c, ClipKittyRust.swift) in the same dirs, so overlay
# file-by-file rather than replacing the whole tree.
overlay_files=(
  Sources/ClipKittyRust/purrFFI.h
  Sources/ClipKittyRust/module.modulemap
  Sources/ClipKittyRust/libpurr.a
  Sources/ClipKittyRust/ios-device/libpurr.a
  Sources/ClipKittyRust/ios-simulator/libpurr.a
  Sources/ClipKittyRustWrapper/purr.swift
)
for rel in "${overlay_files[@]}"; do
  src="result-generated/$rel"
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "$rel")"
    cp "$src" "$rel"
    chmod u+w "$rel"
  fi
done

chmod -R u+w "$APP_NAME.xcworkspace" "$APP_NAME.xcodeproj" Tuist/.build 2>/dev/null || true
