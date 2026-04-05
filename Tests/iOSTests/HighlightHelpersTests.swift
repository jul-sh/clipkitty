import ClipKittyRust
@testable import ClipKittyShared
import XCTest

/// Tests for the cross-platform highlight helpers used by both iOS and macOS.
final class HighlightHelpersTests: XCTestCase {
    // MARK: - UTF-16 Range Conversion

    func testStringRangeForASCII() {
        let text = "Hello World"
        let range = HighlightRangeConverter.stringRange(utf16Start: 6, utf16End: 11, in: text)
        XCTAssertNotNil(range)
        XCTAssertEqual(String(text[range!]), "World")
    }

    func testStringRangeForEmoji() {
        // 👋 is U+1F44B, encoded as 2 UTF-16 code units (surrogate pair)
        let text = "👋Hello"
        // 👋 occupies UTF-16 positions 0-1, "H" is at position 2
        let range = HighlightRangeConverter.stringRange(utf16Start: 0, utf16End: 2, in: text)
        XCTAssertNotNil(range)
        XCTAssertEqual(String(text[range!]), "👋")

        let helloRange = HighlightRangeConverter.stringRange(utf16Start: 2, utf16End: 7, in: text)
        XCTAssertNotNil(helloRange)
        XCTAssertEqual(String(text[helloRange!]), "Hello")
    }

    func testStringRangeForCombiningCharacter() {
        // é can be composed as e + combining acute accent (2 UTF-16 code units for 1 character)
        let text = "e\u{0301}llo" // é decomposed + llo
        // e is position 0, combining accent is position 1, l is position 2
        let range = HighlightRangeConverter.stringRange(utf16Start: 0, utf16End: 2, in: text)
        XCTAssertNotNil(range)
        XCTAssertEqual(String(text[range!]), "e\u{0301}")
    }

    func testStringRangeOutOfBoundsReturnsNil() {
        let text = "Short"
        XCTAssertNil(HighlightRangeConverter.stringRange(utf16Start: 0, utf16End: 100, in: text))
        XCTAssertNil(HighlightRangeConverter.stringRange(utf16Start: -1, utf16End: 3, in: text))
    }

    func testStringRangeInvertedReturnsNil() {
        let text = "Hello"
        XCTAssertNil(HighlightRangeConverter.stringRange(utf16Start: 3, utf16End: 1, in: text))
    }

    // MARK: - AttributedString Builder

    func testAttributedTextWithNoHighlights() {
        let text = "No highlights here"
        let attributed = HighlightAttributedStringBuilder.attributedText(text, highlights: [])
        XCTAssertEqual(String(attributed.characters), text)
    }

    func testAttributedTextWithSingleHighlight() {
        let text = "Find me here"
        let highlights = [
            Utf16HighlightRange(utf16Start: 5, utf16End: 7, kind: .exact),
        ]
        let attributed = HighlightAttributedStringBuilder.attributedText(text, highlights: highlights)
        XCTAssertEqual(String(attributed.characters), text)

        // Verify the highlight range has a background color
        let range = attributed.characters.index(attributed.startIndex, offsetBy: 5) ..<
            attributed.characters.index(attributed.startIndex, offsetBy: 7)
        let bgColor = attributed[range].backgroundColor
        XCTAssertNotNil(bgColor)
    }

    func testAttributedTextWithEmojiHighlight() {
        let text = "🔍 Search"
        // Highlight the emoji (2 UTF-16 code units)
        let highlights = [
            Utf16HighlightRange(utf16Start: 0, utf16End: 2, kind: .exact),
        ]
        let attributed = HighlightAttributedStringBuilder.attributedText(text, highlights: highlights)
        XCTAssertEqual(String(attributed.characters), text)
    }

    func testAttributedTextWithMultipleHighlights() {
        let text = "one two three"
        let highlights = [
            Utf16HighlightRange(utf16Start: 0, utf16End: 3, kind: .exact),
            Utf16HighlightRange(utf16Start: 8, utf16End: 13, kind: .fuzzy),
        ]
        let attributed = HighlightAttributedStringBuilder.attributedText(text, highlights: highlights)
        XCTAssertEqual(String(attributed.characters), text)
    }

    // MARK: - Fragment Extraction

    func testFragmentsExtractionFromHighlights() {
        let text = "Hello World foo"
        let highlights = [
            Utf16HighlightRange(utf16Start: 0, utf16End: 5, kind: .exact),
            Utf16HighlightRange(utf16Start: 6, utf16End: 11, kind: .fuzzy),
        ]
        let fragments = HighlightAttributedStringBuilder.fragments(in: text, highlights: highlights)
        XCTAssertEqual(fragments, ["Hello", "World"])
    }

    func testFragmentsWithEmojiHighlights() {
        let text = "🔍 Search 🎯 Target"
        // Highlight "🔍" (UTF-16 positions 0-1)
        let highlights = [
            Utf16HighlightRange(utf16Start: 0, utf16End: 2, kind: .exact),
        ]
        let fragments = HighlightAttributedStringBuilder.fragments(in: text, highlights: highlights)
        XCTAssertEqual(fragments, ["🔍"])
    }

    func testFragmentsWithInvalidRangeReturnsEmpty() {
        let text = "Short"
        let highlights = [
            Utf16HighlightRange(utf16Start: 0, utf16End: 100, kind: .exact),
        ]
        let fragments = HighlightAttributedStringBuilder.fragments(in: text, highlights: highlights)
        XCTAssertTrue(fragments.isEmpty)
    }

    // MARK: - Highlight Appearance

    func testAppearanceForExactKind() {
        let style = HighlightAppearance.style(for: .exact)
        XCTAssertFalse(style.underlineStyle)
    }

    func testAppearanceForSubsequenceKind() {
        let style = HighlightAppearance.style(for: .subsequence)
        XCTAssertTrue(style.underlineStyle)
    }
}
