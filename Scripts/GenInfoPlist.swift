#!/usr/bin/env swift
// Generates Info.plist for ClipKitty app bundle

import Foundation

let appName = "ClipKitty"
let bundleId = "com.eviljuliette.clipkitty"

let plist: [String: Any] = [
    "CFBundleExecutable": appName,
    "CFBundleIdentifier": bundleId,
    "CFBundleName": appName,
    "CFBundleDisplayName": appName,
    "CFBundleIconName": "AppIcon",
    "CFBundleIconFile": "AppIcon",
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": "1.0",
    "CFBundleShortVersionString": "1.0",
    "LSMinimumSystemVersion": "15.0",
    "LSUIElement": true,
    "NSHumanReadableCopyright": "Copyright © 2024 ClipKitty. All rights reserved."
]

// Get output path from args or use default
let outputPath: String
if CommandLine.arguments.count > 1 {
    outputPath = CommandLine.arguments[1]
} else {
    outputPath = "ClipKitty.app/Contents/Info.plist"
}

// Create directory if needed
let outputURL = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

// Write plist
let data = try PropertyListSerialization.data(
    fromPropertyList: plist,
    format: .xml,
    options: 0
)
try data.write(to: outputURL)

print("Generated \(outputPath)")
