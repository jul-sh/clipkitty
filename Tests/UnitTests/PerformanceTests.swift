import AppKit
import ClipKittyRust
import XCTest

/// Performance benchmarks for UI-side text range resolution with precomputed UTF-16 ranges.
final class PerformanceTests: XCTestCase {
    private func makeTextView(text: String) -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        textView.isRichText = false
        textView.textStorage?.setAttributedString(NSAttributedString(string: text))
        return textView
    }

    private func resolveTextRanges(highlights: [Utf16HighlightRange], in textView: NSTextView) -> Int {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager
        else {
            return 0
        }

        var resolvedCount = 0
        for highlight in highlights {
            let nsRange = highlight.nsRange
            guard let start = contentManager.location(contentManager.documentRange.location, offsetBy: nsRange.location),
                  let end = contentManager.location(start, offsetBy: nsRange.length)
            else {
                continue
            }
            if NSTextRange(location: start, end: end) != nil {
                resolvedCount += 1
            }
        }
        return resolvedCount
    }

    func testResolveTextRangesUnicodePerformance() {
        var emojiText = ""
        for index in 0..<100 {
            emojiText += "🔥 Item \(index) "
        }
        emojiText += "FindThisWord"

        let nsText = emojiText as NSString
        let match = nsText.range(of: "FindThisWord")
        let highlights = (0..<200).map { _ in
            Utf16HighlightRange(
                utf16Start: UInt64(match.location),
                utf16End: UInt64(match.location + match.length),
                kind: .exact
            )
        }
        let textView = makeTextView(text: emojiText)

        measure {
            XCTAssertEqual(resolveTextRanges(highlights: highlights, in: textView), highlights.count)
        }
    }

    func testResolveTextRangesAsciiPerformance() {
        let asciiText = String(repeating: "a", count: 1000) + "FindThisWord"
        let nsText = asciiText as NSString
        let match = nsText.range(of: "FindThisWord")
        let highlights = (0..<200).map { _ in
            Utf16HighlightRange(
                utf16Start: UInt64(match.location),
                utf16End: UInt64(match.location + match.length),
                kind: .exact
            )
        }
        let textView = makeTextView(text: asciiText)

        measure {
            XCTAssertEqual(resolveTextRanges(highlights: highlights, in: textView), highlights.count)
        }
    }
}
