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

        // Compute match data (lazy on this branch)
        let matchDataArray = try store.computeMatchData(itemIds: [match.itemMetadata.itemId], query: "Files")
        guard let matchData = matchDataArray.first else {
            XCTFail("No match data computed")
            return
        }

        // Get the full content highlights from Rust (not snippet highlights)
        let highlights = matchData.fullContentHighlights

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

        // Compute match data (lazy on this branch)
        let matchDataArray = try store.computeMatchData(itemIds: [match.itemMetadata.itemId], query: "Files")
        guard let matchData = matchDataArray.first else {
            XCTFail("No match data computed")
            return
        }

        // Verify ALL highlights extract the correct text using nsRange(in:)
        let nsString = content as NSString
        for highlight in matchData.fullContentHighlights {
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

    // MARK: - NFD Combining Character Tests

    /// Test nsRange(in:) with NFD combining characters (e.g. é = e + \u{0301}).
    /// Rust's .chars() counts each Unicode scalar separately, so NFD é is 2 scalars.
    /// Swift's String.count treats é as 1 grapheme cluster. Using unicodeScalars fixes the mismatch.
    func testNsRangeWithNFDCombiningCharacters() {
        // NFD "café résumé hello world"
        // c=0 a=1 f=2 e=3 \u{0301}=4 ' '=5 r=6 e=7 \u{0301}=8 s=9 u=10 m=11 e=12 \u{0301}=13 ' '=14 h=15 e=16 l=17 l=18 o=19 ' '=20 w=21 o=22 r=23 l=24 d=25
        let text = "caf\u{0065}\u{0301} r\u{0065}\u{0301}sum\u{0065}\u{0301} hello world"
        XCTAssertEqual(text.unicodeScalars.count, 26, "NFD text should have 26 Unicode scalars")
        XCTAssertEqual(text.count, 23, "NFD text should have 23 grapheme clusters")

        // Rust would report "hello" at scalar indices 15-20 (after "café résumé " = 15 scalars)
        let range = HighlightRange(start: 15, end: 20, kind: .exact)
        let nsRange = range.nsRange(in: text)

        let nsString = text as NSString
        guard nsRange.location != NSNotFound, nsRange.location + nsRange.length <= nsString.length else {
            XCTFail("nsRange out of bounds: \(nsRange)")
            return
        }
        let extracted = nsString.substring(with: nsRange)
        XCTAssertEqual(extracted, "hello", "Should extract 'hello' from NFD text, not shifted characters")
    }

    /// Integration test: search NFD content with query "he" returns correct highlight.
    func testSearchHighlightsWithNFDContent() async throws {
        let store = try makeStore()

        // NFD "café résumé hello world" — combining accents cause scalar/grapheme mismatch
        let text = "caf\u{0065}\u{0301} r\u{0065}\u{0301}sum\u{0065}\u{0301} hello world"

        _ = try store.saveText(
            text: text,
            sourceApp: "Test",
            sourceAppBundleId: "com.test"
        )

        let results = try await store.search(query: "he")
        XCTAssertFalse(results.matches.isEmpty, "Should find 'he' in NFD content")

        guard let match = results.matches.first else {
            XCTFail("No match found")
            return
        }

        // Compute match data (lazy on this branch)
        let matchDataArray = try store.computeMatchData(itemIds: [match.itemMetadata.itemId], query: "he")
        guard let matchData = matchDataArray.first else {
            XCTFail("No match data computed")
            return
        }

        // Verify highlights extract "hello" (the word containing "he"), not shifted text
        let nsString = text as NSString
        for highlight in matchData.fullContentHighlights {
            let nsRange = highlight.nsRange(in: text)
            guard nsRange.location != NSNotFound, nsRange.location + nsRange.length <= nsString.length else { continue }
            let extracted = nsString.substring(with: nsRange)
            XCTAssertEqual(extracted, "hello",
                "NFD highlight extracted '\(extracted)' but should be 'hello'. Grapheme/scalar mismatch bug!")
        }
    }

    /// Regression test: real clipboard content that triggered highlight drift.
    /// The text contains special Unicode characters (curly quotes, em dash, ellipsis)
    /// that may be represented as combining sequences depending on normalization.
    func testSearchHighlightsWithRealClipContent() async throws {
        let store = try makeStore()

        let clipContent = """
        Bash(gh pr edit 173 --title "Re-add editable preview feature" --body "## Summary\u{2026})
          \u{23EE}  Error: Exit code 1
             GraphQL: Projects (classic) is being deprecated in favor of the new Projects experience, see:
             https://github.blog/changelog/2024-05-23-sunset-notice-projects-classic/. (repository.pullRequest.projectCards)

        > same for re-add-smart-search, revert on main pr to re add

        \u{23EE} The edit went through despite the warning. Now let me do the same for smart search - revert on main and update the PR:
        """

        _ = try store.saveText(
            text: clipContent,
            sourceApp: "Test",
            sourceAppBundleId: "com.test"
        )

        let results = try await store.search(query: "he")
        XCTAssertFalse(results.matches.isEmpty, "Should find 'he' in clip content")

        guard let match = results.matches.first else {
            XCTFail("No match found")
            return
        }

        let matchDataArray = try store.computeMatchData(itemIds: [match.itemMetadata.itemId], query: "he")
        guard let matchData = matchDataArray.first else {
            XCTFail("No match data computed")
            return
        }

        // Every highlight should extract valid text that actually contains "he"
        let nsString = clipContent as NSString
        for highlight in matchData.fullContentHighlights {
            let nsRange = highlight.nsRange(in: clipContent)
            guard nsRange.location != NSNotFound else {
                XCTFail("Highlight produced NSNotFound range")
                continue
            }
            guard nsRange.location + nsRange.length <= nsString.length else {
                XCTFail("Highlight range \(nsRange) out of bounds (length \(nsString.length))")
                continue
            }
            let extracted = nsString.substring(with: nsRange)
            XCTAssertTrue(extracted.lowercased().contains("he"),
                "Highlight extracted '\(extracted)' which doesn't contain 'he' — position drift bug!")
        }
    }
}
