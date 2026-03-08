import XCTest
import ClipKittyRust

/// Tests for rollback semantics in delete and clear operations
/// These tests verify the Rust store operations that support rollback behavior
final class ClipboardStoreRollbackTests: XCTestCase {

    // MARK: - Test Infrastructure

    private func makeStore() throws -> ClipKittyRust.ClipboardStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dbPath = tmp.appendingPathComponent("test.sqlite").path
        return try ClipKittyRust.ClipboardStore(dbPath: dbPath)
    }

    // MARK: - Delete Operation Tests

    @MainActor
    func testDeleteRemovesItemFromDatabase() async throws {
        let store = try makeStore()

        // Save a test item
        let itemId = try store.saveText(
            text: "Test item for deletion",
            sourceApp: "Test",
            sourceAppBundleId: "com.test"
        )
        XCTAssertGreaterThan(itemId, 0, "Item should be created")

        // Verify item exists
        let items = try store.fetchByIds(itemIds: [itemId])
        XCTAssertEqual(items.count, 1, "Item should exist before deletion")

        // Delete the item
        try store.deleteItem(itemId: itemId)

        // Verify item is deleted
        let deletedItems = try store.fetchByIds(itemIds: [itemId])
        XCTAssertTrue(deletedItems.isEmpty, "Item should be deleted")
    }

    @MainActor
    func testDeleteNonExistentItemDoesNotThrow() throws {
        let store = try makeStore()

        // Delete a non-existent item should not throw
        XCTAssertNoThrow(try store.deleteItem(itemId: 99999), "Deleting non-existent item should not throw")
    }

    @MainActor
    func testDeletePreservesOtherItems() async throws {
        let store = try makeStore()

        // Save multiple test items
        let id1 = try store.saveText(text: "Item 1", sourceApp: nil, sourceAppBundleId: nil)
        let id2 = try store.saveText(text: "Item 2", sourceApp: nil, sourceAppBundleId: nil)
        let id3 = try store.saveText(text: "Item 3", sourceApp: nil, sourceAppBundleId: nil)

        XCTAssertGreaterThan(id1, 0)
        XCTAssertGreaterThan(id2, 0)
        XCTAssertGreaterThan(id3, 0)

        // Delete middle item
        try store.deleteItem(itemId: id2)

        // Verify other items still exist
        let items = try store.fetchByIds(itemIds: [id1, id3])
        XCTAssertEqual(items.count, 2, "Other items should not be affected")

        let deletedItem = try store.fetchByIds(itemIds: [id2])
        XCTAssertTrue(deletedItem.isEmpty, "Deleted item should be gone")
    }

    // MARK: - Clear Operation Tests

    @MainActor
    func testClearRemovesAllItems() async throws {
        let store = try makeStore()

        // Save multiple test items
        let id1 = try store.saveText(text: "Item 1", sourceApp: nil, sourceAppBundleId: nil)
        let id2 = try store.saveText(text: "Item 2", sourceApp: nil, sourceAppBundleId: nil)
        let id3 = try store.saveText(text: "Item 3", sourceApp: nil, sourceAppBundleId: nil)

        XCTAssertGreaterThan(id1, 0)
        XCTAssertGreaterThan(id2, 0)
        XCTAssertGreaterThan(id3, 0)

        // Verify items exist
        let searchResult = try await store.search(query: "")
        XCTAssertGreaterThanOrEqual(searchResult.matches.count, 3, "Should have at least 3 items")

        // Clear all items
        try store.clear()

        // Verify all items are cleared
        let clearedResult = try await store.search(query: "")
        XCTAssertEqual(clearedResult.matches.count, 0, "All items should be cleared")
    }

    @MainActor
    func testClearEmptyDatabaseDoesNotThrow() async throws {
        let store = try makeStore()

        // Clear an empty database should not throw
        XCTAssertNoThrow(try store.clear(), "Clearing empty database should not throw")

        // Verify database is still empty
        let result = try await store.search(query: "")
        XCTAssertEqual(result.matches.count, 0, "Database should still be empty")
    }

    @MainActor
    func testClearFollowedByInsert() async throws {
        let store = try makeStore()

        // Save initial item
        let id1 = try store.saveText(text: "Initial item", sourceApp: nil, sourceAppBundleId: nil)
        XCTAssertGreaterThan(id1, 0)

        // Clear database
        try store.clear()

        // Save new item after clear
        let id2 = try store.saveText(text: "New item after clear", sourceApp: nil, sourceAppBundleId: nil)
        XCTAssertGreaterThan(id2, 0)

        // Verify only new item exists
        let result = try await store.search(query: "")
        XCTAssertEqual(result.matches.count, 1, "Should have exactly 1 item")

        // Fetch the full item to check content
        let items = try store.fetchByIds(itemIds: [id2])
        XCTAssertEqual(items.count, 1)
        if case .text(let text) = items[0].content {
            XCTAssertEqual(text, "New item after clear", "Should be the new item")
        } else {
            XCTFail("Expected text content")
        }
    }

    // MARK: - Integration Tests

    @MainActor
    func testMultipleDeletesInSequence() async throws {
        let store = try makeStore()

        // Save multiple items
        var itemIds: [Int64] = []
        for i in 1...5 {
            let id = try store.saveText(text: "Item \(i)", sourceApp: nil, sourceAppBundleId: nil)
            itemIds.append(id)
        }

        // Verify all items exist
        let initialResult = try await store.search(query: "")
        XCTAssertEqual(initialResult.matches.count, 5)

        // Delete items one by one
        for id in itemIds {
            try store.deleteItem(itemId: id)
        }

        // Verify all items are deleted
        let finalResult = try await store.search(query: "")
        XCTAssertEqual(finalResult.matches.count, 0, "All items should be deleted")
    }

    @MainActor
    func testDeleteAndClearMixed() async throws {
        let store = try makeStore()

        // Save items
        _ = try store.saveText(text: "Item 1", sourceApp: nil, sourceAppBundleId: nil)
        let id2 = try store.saveText(text: "Item 2", sourceApp: nil, sourceAppBundleId: nil)
        _ = try store.saveText(text: "Item 3", sourceApp: nil, sourceAppBundleId: nil)

        // Delete one item
        try store.deleteItem(itemId: id2)

        // Verify two items remain
        var result = try await store.search(query: "")
        XCTAssertEqual(result.matches.count, 2)

        // Clear all
        try store.clear()

        // Verify all gone
        result = try await store.search(query: "")
        XCTAssertEqual(result.matches.count, 0)
    }
}
