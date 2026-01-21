#!/usr/bin/env swift
import Foundation
import CoreGraphics

// MARK: - Private API Declarations
// These are undocumented CoreGraphics APIs used to create virtual displays
// They work on both Intel and Apple Silicon but may break in future macOS versions

@_silgen_name("CGSCreateVirtualDisplay")
func CGSCreateVirtualDisplay(_ config: UnsafeMutableRawPointer, _ displayID: UnsafeMutablePointer<CGDirectDisplayID>) -> CGError

@_silgen_name("CGSSetVirtualDisplayMode")
func CGSSetVirtualDisplayMode(_ config: UnsafeMutableRawPointer, _ displayID: CGDirectDisplayID, _ width: Int, _ height: Int, _ refresh: Double, _ scale: Int) -> CGError

@_silgen_name("CGSRemoveVirtualDisplay")
func CGSRemoveVirtualDisplay(_ displayID: CGDirectDisplayID) -> CGError

// MARK: - Configuration
// 4K HiDPI: 3840x2160 at 2x scale = 1920x1080 logical @ Retina
let width = 3840
let height = 2160
let refreshRate = 60.0
let hiDPIScale = 2  // 1 = standard, 2 = Retina/HiDPI

// MARK: - Signal Handling for Cleanup
var displayID: CGDirectDisplayID = 0

func cleanup() {
    if displayID != 0 {
        fputs("Cleaning up virtual display \(displayID)...\n", stderr)
        _ = CGSRemoveVirtualDisplay(displayID)
    }
}

signal(SIGINT) { _ in
    cleanup()
    exit(0)
}

signal(SIGTERM) { _ in
    cleanup()
    exit(0)
}

// MARK: - Create Virtual Display
let config = UnsafeMutableRawPointer.allocate(byteCount: 1024, alignment: 8)
defer { config.deallocate() }

fputs("Creating virtual HiDPI display (\(width)x\(height) @ \(hiDPIScale)x)...\n", stderr)

let error = CGSCreateVirtualDisplay(config, &displayID)

guard error == .success else {
    fputs("Failed to create virtual display. CGError: \(error.rawValue)\n", stderr)
    fputs("This may require running on a macOS system with GUI capabilities.\n", stderr)
    exit(1)
}

fputs("Virtual display created with ID: \(displayID)\n", stderr)

// Set the display mode to HiDPI
let modeError = CGSSetVirtualDisplayMode(config, displayID, width, height, refreshRate, hiDPIScale)
if modeError != .success {
    fputs("Warning: Failed to set display mode. CGError: \(modeError.rawValue)\n", stderr)
}

// Output the display ID to stdout for scripts to capture
print(displayID)
fflush(stdout)

fputs("Virtual display is live. Send SIGTERM or SIGINT to terminate.\n", stderr)

// Keep the process alive - the display only exists while this process runs
RunLoop.current.run()
