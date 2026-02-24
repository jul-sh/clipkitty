import XCTest
import ClipKittyRust

/// Tests for HighlightRange Unicode conversion.
/// Verifies that Rust char indices are correctly converted to Swift UTF-16 indices.
///
/// This is a real integration test: Rust computes highlight ranges (char indices),
/// Swift converts them to UTF-16 indices via nsRange(in:), and we verify the
/// extracted text matches what Rust intended to highlight.
final class HighlightRangeTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeStore() throws -> ClipKittyRust.ClipboardStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dbPath = tmp.appendingPathComponent("test.sqlite").path
        return try ClipKittyRust.ClipboardStore(dbPath: dbPath)
    }

    // MARK: - nsRange Conversion Tests (Unit Tests)

    /// Test that nsRange(in:) correctly handles ASCII text (no conversion needed)
    func testNsRangeAsciiText() {
        // Create a highlight range for "world" in "hello world"
        // Char indices: 6-11
        let range = HighlightRange(start: 6, end: 11, kind: .exact)
        let text = "hello world"

        let nsRange = range.nsRange(in: text)

        XCTAssertEqual(nsRange.location, 6)
        XCTAssertEqual(nsRange.length, 5)

        // Verify extraction
        let nsString = text as NSString
        let extracted = nsString.substring(with: nsRange)
        XCTAssertEqual(extracted, "world")
    }

    /// Test that nsRange(in:) correctly converts char indices to UTF-16 for emoji text
    func testNsRangeWithEmoji() {
        // Text: "Hello 👋 World"
        // Char indices: H=0, e=1, l=2, l=3, o=4, ' '=5, 👋=6, ' '=7, W=8, o=9, r=10, l=11, d=12
        // UTF-16:       H=0, e=1, l=2, l=3, o=4, ' '=5, 👋=6,7, ' '=8, W=9, o=10, r=11, l=12, d=13
        //
        // "World" is at char indices 8-13, but UTF-16 indices 9-14
        let text = "Hello 👋 World"
        let range = HighlightRange(start: 8, end: 13, kind: .exact)

        let nsRange = range.nsRange(in: text)

        // UTF-16 location should be 9 (emoji takes 2 UTF-16 units)
        XCTAssertEqual(nsRange.location, 9, "UTF-16 start should account for emoji")
        XCTAssertEqual(nsRange.length, 5, "Length should still be 5 UTF-16 units for ASCII")

        // Verify extraction gives correct text
        let nsString = text as NSString
        let extracted = nsString.substring(with: nsRange)
        XCTAssertEqual(extracted, "World", "Should extract 'World' not wrong characters")
    }

    /// Test multiple emojis causing larger drift
    func testNsRangeWithMultipleEmojis() {
        // Text: "🎉🎊🎁 Gift"
        // Char: 🎉=0, 🎊=1, 🎁=2, ' '=3, G=4, i=5, f=6, t=7
        // UTF-16: 🎉=0,1, 🎊=2,3, 🎁=4,5, ' '=6, G=7, i=8, f=9, t=10
        //
        // "Gift" is at char indices 4-8, but UTF-16 indices 7-11
        let text = "🎉🎊🎁 Gift"
        let range = HighlightRange(start: 4, end: 8, kind: .exact)

        let nsRange = range.nsRange(in: text)

        XCTAssertEqual(nsRange.location, 7, "UTF-16 start should be 7 (3 emojis * 2 = 6 extra)")
        XCTAssertEqual(nsRange.length, 4)

        let nsString = text as NSString
        let extracted = nsString.substring(with: nsRange)
        XCTAssertEqual(extracted, "Gift")
    }

    /// Test edge case: highlight at the beginning
    func testNsRangeAtBeginning() {
        let text = "Hello 👋 World"
        let range = HighlightRange(start: 0, end: 5, kind: .exact)

        let nsRange = range.nsRange(in: text)

        XCTAssertEqual(nsRange.location, 0)
        XCTAssertEqual(nsRange.length, 5)

        let nsString = text as NSString
        let extracted = nsString.substring(with: nsRange)
        XCTAssertEqual(extracted, "Hello")
    }

    /// Test edge case: highlight of emoji itself
    func testNsRangeOfEmoji() {
        let text = "Hello 👋 World"
        // 👋 is at char index 6
        let range = HighlightRange(start: 6, end: 7, kind: .exact)

        let nsRange = range.nsRange(in: text)

        XCTAssertEqual(nsRange.location, 6)
        XCTAssertEqual(nsRange.length, 2, "Emoji takes 2 UTF-16 code units")

        let nsString = text as NSString
        let extracted = nsString.substring(with: nsRange)
        XCTAssertEqual(extracted, "👋")
    }

    /// Test bounds checking returns NSNotFound for invalid ranges
    func testNsRangeInvalidRange() {
        let text = "short"
        let range = HighlightRange(start: 10, end: 15, kind: .exact)

        let nsRange = range.nsRange(in: text)

        XCTAssertEqual(nsRange.location, NSNotFound)
    }

    // MARK: - Integration Tests: Rust Search -> Swift Display

    /// Integration test: search with emoji content returns correct highlight positions.
    /// This tests the full pipeline: Rust computes char indices, Swift converts to UTF-16.
    func testSearchHighlightsWithEmojiContent() async throws {
        let store = try makeStore()

        // Save content with emojis before the search term
        let textWithEmojis = "🎉 Celebrate! 🎊 This is a party 🎈 with Files everywhere"
        _ = try store.saveText(
            text: textWithEmojis,
            sourceApp: "Test",
            sourceAppBundleId: "com.test"
        )

        // Search for "Files" - Rust will compute highlight ranges
        let results = try await store.search(query: "Files")
        XCTAssertFalse(results.matches.isEmpty, "Should find 'Files' in content")

        guard let match = results.matches.first else {
            XCTFail("No match found")
            return
        }

        // Get the full content highlights from Rust (not snippet highlights)
        let highlights = match.matchData.fullContentHighlights

        // Find the highlight for "Files"
        guard let filesHighlight = highlights.first(where: { highlight in
            let range = highlight.nsRange(in: textWithEmojis)
            if range.location == NSNotFound { return false }
            let nsString = textWithEmojis as NSString
            guard range.location + range.length <= nsString.length else { return false }
            return nsString.substring(with: range).lowercased() == "files"
        }) else {
            XCTFail("Should have highlight for 'Files'")
            return
        }

        // Verify the converted range extracts "Files" correctly
        let nsRange = filesHighlight.nsRange(in: textWithEmojis)
        let nsString = textWithEmojis as NSString
        let extracted = nsString.substring(with: nsRange)

        XCTAssertEqual(extracted, "Files", "Highlight should extract 'Files', not wrong characters like 'iles' or 'fy re'")
    }

    /// Test that highlights work with the exact bug case: many emojis causing position drift.
    /// Before the fix, searching "Files" in content with 50 emojis would highlight "fy re" or similar.
    func testSearchHighlightsDoNotDrift() async throws {
        let store = try makeStore()

        // Content with many emojis before "Files" (simulating the bug case)
        // Each emoji causes 1 position drift between char indices and UTF-16 indices
        var content = ""
        for i in 0..<50 {
            content += "🔥 Item \(i) "
        }
        content += "Finding Large Files in the system"

        _ = try store.saveText(
            text: content,
            sourceApp: "Test",
            sourceAppBundleId: "com.test"
        )

        let results = try await store.search(query: "Files")
        XCTAssertFalse(results.matches.isEmpty)

        guard let match = results.matches.first else {
            XCTFail("No match found")
            return
        }

        // Verify ALL highlights extract the correct text using nsRange(in:)
        let nsString = content as NSString
        for highlight in match.matchData.fullContentHighlights {
            let nsRange = highlight.nsRange(in: content)
            guard nsRange.location != NSNotFound else { continue }
            guard nsRange.location + nsRange.length <= nsString.length else { continue }

            let extracted = nsString.substring(with: nsRange)

            // The extracted text should match "files" (case-insensitive)
            // It should NOT be random text like "iles", "fy re", etc.
            XCTAssertEqual(extracted.lowercased(), "files",
                "Highlight extracted '\(extracted)' but should be 'Files'. Position drift bug detected!")
        }
    }
}
