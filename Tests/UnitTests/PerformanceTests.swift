import XCTest
import ClipKittyRust

/// Performance benchmarks for ClipKitty operations.
/// Run with: xcodebuild test -scheme ClipKitty -only-testing:UnitTests/PerformanceTests
final class PerformanceTests: XCTestCase {

    // MARK: - Unicode Performance

    /// Benchmark: nsRange conversion with emoji-heavy text
    func testNsRangeUnicodePerformance() {
        // Create text with many emojis (each causing UTF-16/scalar drift)
        var emojiText = ""
        for i in 0..<100 {
            emojiText += "🔥 Item \(i) "
        }
        emojiText += "FindThisWord"

        let range = HighlightRange(start: UInt64(emojiText.unicodeScalars.count - 12), end: UInt64(emojiText.unicodeScalars.count), utf16Start: 0, utf16End: 0, kind: .exact)

        measure {
            for _ in 0..<1000 {
                _ = range.nsRange(in: emojiText)
            }
        }
    }

    /// Benchmark: nsRange conversion with ASCII text (baseline)
    func testNsRangeAsciiPerformance() {
        let asciiText = String(repeating: "a", count: 1000) + "FindThisWord"
        let range = HighlightRange(start: 1000, end: 1012, utf16Start: 0, utf16End: 0, kind: .exact)

        measure {
            for _ in 0..<1000 {
                _ = range.nsRange(in: asciiText)
            }
        }
    }
}
