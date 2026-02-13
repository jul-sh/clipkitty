#!/usr/bin/env swift
// Generates Info.plist for ClipKitty app bundle
//
// Usage: swift GenInfoPlist.swift [output-path] [--version X.Y.Z] [--build N]

import Foundation

let appName = "ClipKitty"
let bundleId = "com.eviljuliette.clipkitty"

// Parse arguments
var outputPath = "ClipKitty.app/Contents/Info.plist"
var version = "1.0.0"
var build = "1"

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--version":
        if !args.isEmpty { version = args.removeFirst() }
    case "--build":
        if !args.isEmpty { build = args.removeFirst() }
    default:
        if !arg.hasPrefix("-") { outputPath = arg }
    }
}

let plist: [String: Any] = [
    "CFBundleExecutable": appName,
    "CFBundleIdentifier": bundleId,
    "CFBundleName": appName,
    "CFBundleDisplayName": appName,
    "CFBundleIconName": "AppIcon",
    "CFBundleIconFile": "AppIcon",
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": build,
    "CFBundleShortVersionString": version,
    "LSMinimumSystemVersion": "15.0",
    "LSUIElement": true,
    "NSHumanReadableCopyright": "Copyright © 2025 ClipKitty. All rights reserved."
]

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

print("Generated \(outputPath) (version: \(version), build: \(build))")
