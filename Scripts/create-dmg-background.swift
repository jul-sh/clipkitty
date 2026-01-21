#!/usr/bin/env swift
// Creates a DMG background image with installation instructions
// Usage: swift create-dmg-background.swift <output-path>

import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "dmg-background.png"

// DMG window dimensions (will be set in create-dmg)
let width: CGFloat = 660
let height: CGFloat = 500

// Create the image
let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

// Background gradient - light enough for Finder's black icon labels
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.85, green: 0.85, blue: 0.87, alpha: 1.0),
    NSColor(calibratedRed: 0.75, green: 0.75, blue: 0.78, alpha: 1.0)
])!
gradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

// Arrow from app icon position to Applications folder position
let arrowPath = NSBezierPath()
let arrowStartX: CGFloat = 200  // App icon center
let arrowEndX: CGFloat = 460    // Applications folder center
let arrowY: CGFloat = 280       // Vertical center of icons area

// Draw dashed arrow line
arrowPath.move(to: NSPoint(x: arrowStartX + 60, y: arrowY))
arrowPath.line(to: NSPoint(x: arrowEndX - 60, y: arrowY))

NSColor(calibratedWhite: 0.4, alpha: 0.8).setStroke()
arrowPath.lineWidth = 3
arrowPath.setLineDash([12, 8], count: 2, phase: 0)
arrowPath.stroke()

// Arrow head
let arrowHead = NSBezierPath()
arrowHead.move(to: NSPoint(x: arrowEndX - 75, y: arrowY + 15))
arrowHead.line(to: NSPoint(x: arrowEndX - 55, y: arrowY))
arrowHead.line(to: NSPoint(x: arrowEndX - 75, y: arrowY - 15))
arrowHead.lineWidth = 3
arrowHead.lineCapStyle = .round
arrowHead.lineJoinStyle = .round
arrowHead.stroke()

// Title text
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1.0)
]
let title = "Drag ClipKitty to Applications"
let titleSize = title.size(withAttributes: titleAttrs)
title.draw(at: NSPoint(x: (width - titleSize.width) / 2, y: height - 60), withAttributes: titleAttrs)

// Instructions section - positioned below the icons area
let instructionY: CGFloat = 100
let lineHeight: CGFloat = 28
let centerX: CGFloat = width / 2

let headerAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1.0)
]

let stepAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14, weight: .regular),
    .foregroundColor: NSColor(calibratedWhite: 0.3, alpha: 1.0)
]

// First Launch Instructions (centered)
func drawCentered(_ text: String, y: CGFloat, attrs: [NSAttributedString.Key: Any]) {
    let size = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: centerX - size.width / 2, y: y), withAttributes: attrs)
}

drawCentered("First Launch", y: instructionY, attrs: headerAttrs)
drawCentered("Right-click app > Open > Done > System Settings > Privacy & Security > Open Anyway", y: instructionY - lineHeight, attrs: stepAttrs)

image.unlockFocus()

// Save as PNG
guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Error: Failed to create PNG data\n", stderr)
    exit(1)
}

let url = URL(fileURLWithPath: outputPath)
do {
    try pngData.write(to: url)
    print("Created DMG background: \(outputPath)")
} catch {
    fputs("Error: Failed to write file: \(error)\n", stderr)
    exit(1)
}
