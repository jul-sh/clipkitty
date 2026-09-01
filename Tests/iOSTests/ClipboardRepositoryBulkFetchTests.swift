@testable import ClipKittyiOS
import ClipKittyRust
import ClipKittyStore
import XCTest

final class ClipboardRepositoryBulkFetchTests: TemporaryDirectoryTestCase {
    func testFetchItemsPreservesRequestedOrder() async throws {
        let store = try ClipboardStore(dbPath: databasePath("bulk-fetch.db"))
        let repository = ClipboardRepository(store: store)
        let firstID = try await savedText("first", repository: repository)
        let secondID = try await savedText("second", repository: repository)

        let result = await repository.fetchItems(ids: [secondID, firstID])
        guard case let .success(items) = result else {
            return XCTFail("Expected bulk fetch to succeed")
        }

        XCTAssertEqual(items.map(\.itemMetadata.itemId), [secondID, firstID])
        XCTAssertEqual(items.map(\.content.textContent), ["second", "first"])
    }

    func testFetchItemsReturnsEmptySuccessForEmptyRequest() async throws {
        let store = try ClipboardStore(dbPath: databasePath("empty-bulk-fetch.db"))
        let repository = ClipboardRepository(store: store)

        let result = await repository.fetchItems(ids: [])
        guard case let .success(items) = result else {
            return XCTFail("An empty bulk fetch should not fail")
        }
        XCTAssertTrue(items.isEmpty)
    }

    func testTransferFetchPreservesRequestedOrder() async throws {
        let store = try ClipboardStore(dbPath: databasePath("transfer-fetch.db"))
        let repository = ClipboardRepository(store: store)
        let firstID = try await savedText("first", repository: repository)
        let secondID = try await savedText("second", repository: repository)

        let result = await repository.fetchTransferItems(ids: [secondID, firstID])
        guard case let .success(items) = result else {
            return XCTFail("Expected bounded transfer fetch to succeed")
        }

        XCTAssertEqual(items.map(\.itemMetadata.itemId), [secondID, firstID])
        XCTAssertEqual(items.map(\.content.textContent), ["second", "first"])
    }

    func testTransferFetchRejectsDuplicateMissingAndExcessIDsAtomically() async throws {
        let store = try ClipboardStore(dbPath: databasePath("invalid-transfer-fetch.db"))
        let repository = ClipboardRepository(store: store)
        let itemID = try await savedText("present", repository: repository)

        let duplicate = await repository.fetchTransferItems(ids: [itemID, itemID])
        guard case let .rejected(.duplicateItemId(rejectedID)) = duplicate else {
            return XCTFail("Expected a typed duplicate-ID rejection")
        }
        XCTAssertEqual(rejectedID, itemID)

        let missing = await repository.fetchTransferItems(ids: [itemID, "missing"])
        guard case let .rejected(.missingItem(rejectedID)) = missing else {
            return XCTFail("Expected a typed missing-item rejection")
        }
        XCTAssertEqual(rejectedID, "missing")

        let tooMany = await repository.fetchTransferItems(
            ids: (0 ... 50).map { "missing-\($0)" }
        )
        guard case .rejected(.tooManyItems) = tooMany else {
            return XCTFail("Expected a typed item-count rejection")
        }
    }

    func testCancelledRepositoryOperationJoinsDetachedWork() async throws {
        let store = try ClipboardStore(dbPath: databasePath("cancelled-transfer-fetch.db"))
        let started = expectation(description: "detached operation started")
        let finished = expectation(description: "detached operation finished")
        let release = DispatchSemaphore(value: 0)

        let operation = Task {
            await runCancellableRepositoryOperation("testCancellation", on: store) { _ in
                started.fulfill()
                release.wait()
                finished.fulfill()
                return 1
            }
        }

        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        release.signal()

        let result = await operation.value
        guard case let .failure(.databaseOperationFailed(name, underlying)) = result else {
            return XCTFail("A cancelled operation should fail after joining its detached work")
        }
        XCTAssertEqual(name, "testCancellation")
        XCTAssertTrue(underlying is CancellationError)
        await fulfillment(of: [finished], timeout: 2)
    }

    private func savedText(_ text: String, repository: ClipboardRepository) async throws -> String {
        let result = await repository.saveText(
            text: text,
            sourceApp: nil,
            sourceAppBundleId: nil
        )
        switch result {
        case let .success(itemID):
            return itemID
        case let .failure(error):
            throw error
        }
    }
}
