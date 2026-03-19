import ClipKittyRust
import XCTest

/// Tests for UTF-16 highlight ranges produced by the Rust search/preview pipeline.
final class HighlightRangeTests: XCTestCase {
    private func makeStore() throws -> ClipKittyRust.ClipboardStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dbPath = tmp.appendingPathComponent("test.sqlite").path
        return try ClipKittyRust.ClipboardStore(dbPath: dbPath)
    }

    private func extractedText(from range: Utf16HighlightRange, in text: String) -> String {
        (text as NSString).substring(with: range.nsRange)
    }

    func testUtf16RangeAsciiText() {
        let text = "hello world"
        let range = Utf16HighlightRange(utf16Start: 6, utf16End: 11, kind: .exact)

        XCTAssertEqual(range.nsRange.location, 6)
        XCTAssertEqual(range.nsRange.length, 5)
        XCTAssertEqual(extractedText(from: range, in: text), "world")
    }

    func testUtf16RangeWithEmoji() {
        let text = "Hello 👋 World"
        let range = Utf16HighlightRange(utf16Start: 9, utf16End: 14, kind: .exact)

        XCTAssertEqual(range.nsRange.location, 9)
        XCTAssertEqual(range.nsRange.length, 5)
        XCTAssertEqual(extractedText(from: range, in: text), "World")
    }

    func testUtf16RangeWithNFDCombiningCharacters() {
        let text = "caf\u{0065}\u{0301} r\u{0065}\u{0301}sum\u{0065}\u{0301} hello world"
        let range = Utf16HighlightRange(utf16Start: 15, utf16End: 20, kind: .exact)

        XCTAssertEqual(range.nsRange.location, 15)
        XCTAssertEqual(range.nsRange.length, 5)
        XCTAssertEqual(extractedText(from: range, in: text), "hello")
    }

    func testPreviewDecorationHighlightsWithEmojiContent() async throws {
        let store = try makeStore()
        let text = "🎉 Celebrate! 🎊 This is a party 🎈 with Files everywhere"
        _ = try store.saveText(text: text, sourceApp: "Test", sourceAppBundleId: "com.test")

        let results = try await store.search(query: "Files")
        guard let itemId = results.matches.first?.itemMetadata.itemId else {
            return XCTFail("Expected search result")
        }

        guard let decoration = try store.computePreviewDecoration(itemId: itemId, query: "Files") else {
            return XCTFail("Expected preview decoration")
        }

        XCTAssertTrue(decoration.highlights.contains { extractedText(from: $0, in: text) == "Files" })
    }

    func testPreviewDecorationHighlightsDoNotDriftWithManyEmojis() async throws {
        let store = try makeStore()
        var text = ""
        for index in 0..<50 {
            text += "🔥 Item \(index) "
        }
        text += "Finding Large Files in the system"

        _ = try store.saveText(text: text, sourceApp: "Test", sourceAppBundleId: "com.test")

        let results = try await store.search(query: "Files")
        guard let itemId = results.matches.first?.itemMetadata.itemId else {
            return XCTFail("Expected search result")
        }

        guard let decoration = try store.computePreviewDecoration(itemId: itemId, query: "Files") else {
            return XCTFail("Expected preview decoration")
        }

        XCTAssertFalse(decoration.highlights.isEmpty)
        for highlight in decoration.highlights {
            XCTAssertEqual(extractedText(from: highlight, in: text).lowercased(), "files")
        }
    }

    func testPreviewDecorationHighlightsWithNFDContent() async throws {
        let store = try makeStore()
        let text = "caf\u{0065}\u{0301} r\u{0065}\u{0301}sum\u{0065}\u{0301} hello world"
        _ = try store.saveText(text: text, sourceApp: "Test", sourceAppBundleId: "com.test")

        let results = try await store.search(query: "hello")
        guard let itemId = results.matches.first?.itemMetadata.itemId else {
            return XCTFail("Expected search result")
        }

        guard let decoration = try store.computePreviewDecoration(itemId: itemId, query: "hello") else {
            return XCTFail("Expected preview decoration")
        }

        XCTAssertTrue(decoration.highlights.contains { extractedText(from: $0, in: text) == "hello" })
    }

    func testPreviewDecorationInitialScrollIndexIsValid() async throws {
        let store = try makeStore()
        let text = "alpha beta gamma beta delta"
        _ = try store.saveText(text: text, sourceApp: "Test", sourceAppBundleId: "com.test")

        let results = try await store.search(query: "beta")
        guard let itemId = results.matches.first?.itemMetadata.itemId else {
            return XCTFail("Expected search result")
        }

        guard let decoration = try store.computePreviewDecoration(itemId: itemId, query: "beta") else {
            return XCTFail("Expected preview decoration")
        }

        XCTAssertFalse(decoration.highlights.isEmpty)
        guard let index = decoration.initialScrollHighlightIndex else {
            return XCTFail("Expected initial scroll highlight index")
        }
        XCTAssertTrue(decoration.highlights.indices.contains(Int(index)))
    }
}
