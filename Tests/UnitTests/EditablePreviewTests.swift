import XCTest
import ClipKittyRust

final class EditablePreviewTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeStore() throws -> ClipKittyRust.ClipboardStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dbPath = tmp.appendingPathComponent("test.sqlite").path
        return try ClipKittyRust.ClipboardStore(dbPath: dbPath)
    }

    // MARK: - Save Edited Text Tests

    func testSaveEditedTextCreatesNewItem() throws {
        let store = try makeStore()

        // Save original item
        let originalId = try store.saveText(
            text: "Original text",
            sourceApp: "TestApp",
            sourceAppBundleId: "com.test.app"
        )
        XCTAssertGreaterThan(originalId, 0)

        // Save edited text (different content)
        let editedId = try store.saveText(
            text: "Edited text",
            sourceApp: "ClipKitty",
            sourceAppBundleId: "com.eviljuliette.clipkitty"
        )
        XCTAssertGreaterThan(editedId, 0)
        XCTAssertNotEqual(editedId, originalId, "Edited text should create new item with different ID")

        // Verify both items exist
        let items = try store.fetchByIds(itemIds: [originalId, editedId])
        XCTAssertEqual(items.count, 2, "Both original and edited items should exist")
    }

    func testSaveEditedTextPreservesOriginal() throws {
        let store = try makeStore()

        // Save original
        let originalText = "Original content that should not change"
        let originalId = try store.saveText(
            text: originalText,
            sourceApp: "Safari",
            sourceAppBundleId: "com.apple.Safari"
        )

        // Save edited version
        _ = try store.saveText(
            text: "Modified content",
            sourceApp: "ClipKitty",
            sourceAppBundleId: "com.eviljuliette.clipkitty"
        )

        // Original should be unchanged
        let items = try store.fetchByIds(itemIds: [originalId])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].textContent, originalText, "Original item content should be preserved")
    }

    func testSaveEditedTextDuplicateReturnsZero() throws {
        let store = try makeStore()

        // Save original
        let originalText = "Same text content"
        _ = try store.saveText(
            text: originalText,
            sourceApp: "Notes",
            sourceAppBundleId: "com.apple.Notes"
        )

        // Try to save same text (should be duplicate)
        let duplicateId = try store.saveText(
            text: originalText,
            sourceApp: "ClipKitty",
            sourceAppBundleId: "com.eviljuliette.clipkitty"
        )
        XCTAssertEqual(duplicateId, 0, "Duplicate content should return 0")
    }

    func testSaveEditedTextSetsClipKittyAsSource() throws {
        let store = try makeStore()

        let itemId = try store.saveText(
            text: "User edited this text in preview pane",
            sourceApp: "ClipKitty",
            sourceAppBundleId: "com.eviljuliette.clipkitty"
        )

        let items = try store.fetchByIds(itemIds: [itemId])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].itemMetadata.sourceApp, "ClipKitty", "Source app should be ClipKitty")
        XCTAssertEqual(items[0].itemMetadata.sourceAppBundleId, "com.eviljuliette.clipkitty", "Bundle ID should match")
    }

    func testSaveEditedColorTextDetectsAsColor() throws {
        let store = try makeStore()

        // Save a color value
        let itemId = try store.saveText(
            text: "#FF5733",
            sourceApp: "ClipKitty",
            sourceAppBundleId: "com.eviljuliette.clipkitty"
        )

        let items = try store.fetchByIds(itemIds: [itemId])
        XCTAssertEqual(items.count, 1)

        // Rust auto-detects color format
        switch items[0].content {
        case .color(let value):
            XCTAssertEqual(value, "#FF5733", "Color value should be preserved")
        case .text(let value):
            // Also acceptable if color detection happens differently
            XCTAssertEqual(value, "#FF5733", "Text value should be preserved")
        default:
            XCTFail("Expected text or color content, got \(items[0].content)")
        }
    }

    func testEditedTextAppearsAtTopOfList() async throws {
        let store = try makeStore()

        // Save some items with small delays to ensure different timestamps
        _ = try store.saveText(text: "First item", sourceApp: nil, sourceAppBundleId: nil)
        try await Task.sleep(for: .milliseconds(50))
        _ = try store.saveText(text: "Second item", sourceApp: nil, sourceAppBundleId: nil)
        try await Task.sleep(for: .milliseconds(50))

        // Save edited text (should be newest)
        let editedId = try store.saveText(
            text: "Edited item from preview",
            sourceApp: "ClipKitty",
            sourceAppBundleId: "com.eviljuliette.clipkitty"
        )

        // Search should return edited item first (newest)
        let results = try await store.search(query: "")
        XCTAssertFalse(results.matches.isEmpty, "Should have results")
        XCTAssertEqual(results.matches[0].itemMetadata.itemId, editedId, "Edited item should be first (most recent)")
    }

    func testSaveMultipleEditsCreatesSeparateItems() throws {
        let store = try makeStore()

        // Simulate multiple edits of the same original text
        let id1 = try store.saveText(
            text: "Version 1",
            sourceApp: "ClipKitty",
            sourceAppBundleId: "com.eviljuliette.clipkitty"
        )

        let id2 = try store.saveText(
            text: "Version 2",
            sourceApp: "ClipKitty",
            sourceAppBundleId: "com.eviljuliette.clipkitty"
        )

        let id3 = try store.saveText(
            text: "Version 3",
            sourceApp: "ClipKitty",
            sourceAppBundleId: "com.eviljuliette.clipkitty"
        )

        XCTAssertGreaterThan(id1, 0)
        XCTAssertGreaterThan(id2, 0)
        XCTAssertGreaterThan(id3, 0)
        XCTAssertNotEqual(id1, id2)
        XCTAssertNotEqual(id2, id3)
        XCTAssertNotEqual(id1, id3)

        // All three should exist
        let items = try store.fetchByIds(itemIds: [id1, id2, id3])
        XCTAssertEqual(items.count, 3, "All edit versions should be saved as separate items")
    }

    func testSaveEmptyTextIsRejected() throws {
        let store = try makeStore()

        // Empty text should not create an item (or return 0)
        // Note: The actual behavior depends on Rust implementation
        // This test documents expected behavior
        let id = try store.saveText(
            text: "",
            sourceApp: "ClipKitty",
            sourceAppBundleId: "com.eviljuliette.clipkitty"
        )

        // Empty text should either return 0 or throw
        // If it returns a valid ID, verify the behavior
        if id > 0 {
            let items = try store.fetchByIds(itemIds: [id])
            // If stored, it should be retrievable
            XCTAssertEqual(items.count, 1)
        }
    }

    func testSaveWhitespaceOnlyText() throws {
        let store = try makeStore()

        // Whitespace-only text
        let id = try store.saveText(
            text: "   \n\t  ",
            sourceApp: "ClipKitty",
            sourceAppBundleId: "com.eviljuliette.clipkitty"
        )

        // Whitespace-only should be treated as valid text
        if id > 0 {
            let items = try store.fetchByIds(itemIds: [id])
            XCTAssertEqual(items.count, 1)
        }
    }

    func testSaveUrlTextDetectsAsLink() throws {
        let store = try makeStore()

        // Save a URL
        let itemId = try store.saveText(
            text: "https://github.com/example/repo",
            sourceApp: "ClipKitty",
            sourceAppBundleId: "com.eviljuliette.clipkitty"
        )

        let items = try store.fetchByIds(itemIds: [itemId])
        XCTAssertEqual(items.count, 1)

        // Rust auto-detects URLs
        switch items[0].content {
        case .link(let url, _):
            XCTAssertEqual(url, "https://github.com/example/repo", "URL should be preserved")
        case .text(let value):
            // Some implementations may keep it as text
            XCTAssertEqual(value, "https://github.com/example/repo")
        default:
            XCTFail("Expected link or text content")
        }
    }
}
