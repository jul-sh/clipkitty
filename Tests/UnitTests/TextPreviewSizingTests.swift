@testable import ClipKitty
import AppKit
import XCTest

final class TextPreviewSizingTests: XCTestCase {
    private let fontName = "Menlo"
    private let baseFontSize: CGFloat = 15
    private let containerWidth: CGFloat = 400

    /// Regression: a single very long line used to drive the scale toward zero,
    /// shrinking preview text to an unreadable size. The scaled font size must
    /// never drop below the configured base size.
    func testSingleLongLineDoesNotShrinkBelowBaseFontSize() {
        let longLine = String(repeating: "abcdefghijklmnop ", count: 50)

        let scaled = TextPreviewView.scaledFontSize(
            text: longLine,
            fontName: fontName,
            fontSize: baseFontSize,
            containerWidth: containerWidth
        )

        XCTAssertGreaterThanOrEqual(
            scaled,
            baseFontSize * 0.95,
            "Long single lines must not shrink below the base font size (modulo the 5% safety margin)."
        )
        XCTAssertLessThanOrEqual(scaled, baseFontSize * 1.5, "Scaling up is still capped.")
    }

    func testMultiLineLongContentDoesNotShrinkBelowBaseFontSize() {
        let longLine = String(repeating: "abcdefghijklmnop ", count: 50)
        let text = Array(repeating: longLine, count: 6).joined(separator: "\n")

        let scaled = TextPreviewView.scaledFontSize(
            text: text,
            fontName: fontName,
            fontSize: baseFontSize,
            containerWidth: containerWidth
        )

        XCTAssertGreaterThanOrEqual(
            scaled,
            baseFontSize * 0.95,
            "Multi-line content with long lines must also respect the minimum scale."
        )
    }

    func testShortContentCanScaleUp() {
        let scaled = TextPreviewView.scaledFontSize(
            text: "hi",
            fontName: fontName,
            fontSize: baseFontSize,
            containerWidth: containerWidth
        )

        XCTAssertGreaterThan(scaled, baseFontSize, "Short content should scale up beyond the base size.")
        XCTAssertLessThanOrEqual(scaled, baseFontSize * 1.5, "Upscale is capped at 1.5×.")
    }

    func testEmptyTextReturnsBaseSize() {
        let scaled = TextPreviewView.scaledFontSize(
            text: "",
            fontName: fontName,
            fontSize: baseFontSize,
            containerWidth: containerWidth
        )

        XCTAssertEqual(scaled, baseFontSize)
    }
}
