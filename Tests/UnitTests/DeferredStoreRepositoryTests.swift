import ClipKittyRust
import ClipKittyStore
import XCTest

final class DeferredStoreRepositoryTests: XCTestCase {
    private func makeStore() throws -> ClipKittyRust.ClipboardStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-deferred-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let path = directory.appendingPathComponent("clipboard.sqlite").path
        return try StoreOpener.open(path: path, repairStrategy: .rebuildImmediately).store
    }

    // MARK: - DeferredStoreHandle

    func testHandlePeeksNilWhilePendingAndStoreAfterFulfill() throws {
        let handle = DeferredStoreHandle()
        XCTAssertNil(handle.availableStore)

        let store = try makeStore()
        handle.fulfill(store)
        XCTAssertTrue(handle.availableStore === store)
    }

    func testAwaitStoreResolvesWaitersOnFulfill() async throws {
        let handle = DeferredStoreHandle()
        let waiter = Task {
            await handle.awaitStore()
        }

        let store = try makeStore()
        handle.fulfill(store)
        let resolved = await waiter.value
        XCTAssertTrue(resolved === store)
    }

    func testAwaitStoreResolvesNilOnRevoke() async {
        let handle = DeferredStoreHandle()
        let waiter = Task {
            await handle.awaitStore()
        }

        handle.revoke()
        let resolved = await waiter.value
        XCTAssertNil(resolved)

        let lateAwait = await handle.awaitStore()
        XCTAssertNil(lateAwait)
    }

    func testFulfillAfterRevokeStaysUnavailable() async throws {
        let handle = DeferredStoreHandle()
        handle.revoke()
        try handle.fulfill(makeStore())

        XCTAssertNil(handle.availableStore)
        let resolved = await handle.awaitStore()
        XCTAssertNil(resolved)
    }

    // MARK: - Deferred repository operations

    func testOperationStartedWhilePendingCompletesAfterFulfill() async throws {
        let handle = DeferredStoreHandle()
        let repository = ClipboardRepository(deferredStore: handle)
        XCTAssertNil(repository.store)

        let save = Task {
            await repository.saveText(text: "warm boot", sourceApp: nil, sourceAppBundleId: nil)
        }
        try handle.fulfill(makeStore())

        let result = await save.value
        guard case .success = result else {
            return XCTFail("expected save to succeed after fulfill, got \(result)")
        }
        XCTAssertNotNil(repository.store)
    }

    func testOperationFailsWithStoreUnavailableAfterRevoke() async {
        let handle = DeferredStoreHandle()
        let repository = ClipboardRepository(deferredStore: handle)
        handle.revoke()

        let result = await repository.saveText(text: "orphaned", sourceApp: nil, sourceAppBundleId: nil)
        guard case let .failure(.databaseOperationFailed(_, underlying)) = result else {
            return XCTFail("expected unavailable failure, got \(result)")
        }
        XCTAssertTrue(underlying is StoreUnavailableError)
    }

    // MARK: - Deferred search

    func testSearchStartedWhilePendingCompletesAfterFulfill() async throws {
        let handle = DeferredStoreHandle()
        let repository = ClipboardRepository(deferredStore: handle)
        let store = try makeStore()
        _ = try store.saveText(text: "warm search target", sourceApp: nil, sourceAppBundleId: nil)

        let operation = repository.startSearch(query: "", filter: .all, presentation: .card)
        let outcomeTask = Task {
            await operation.awaitOutcome()
        }
        handle.fulfill(store)

        guard case let .success(result) = await outcomeTask.value else {
            return XCTFail("expected deferred search to succeed after fulfill")
        }
        XCTAssertEqual(result.matches.count, 1)
    }

    func testSearchCancelledWhilePendingReportsCancelled() async {
        let handle = DeferredStoreHandle()
        let repository = ClipboardRepository(deferredStore: handle)

        let operation = repository.startSearch(query: "", filter: .all, presentation: .card)
        operation.cancel()
        handle.revoke()

        guard case .cancelled = await operation.awaitOutcome() else {
            return XCTFail("expected cancelled outcome for a cancelled pending search")
        }
    }

    func testSearchReportsCancelledWhenOpenIsRevoked() async {
        let handle = DeferredStoreHandle()
        let repository = ClipboardRepository(deferredStore: handle)

        let operation = repository.startSearch(query: "", filter: .all, presentation: .card)
        let outcomeTask = Task {
            await operation.awaitOutcome()
        }
        handle.revoke()

        guard case .cancelled = await outcomeTask.value else {
            return XCTFail("expected cancelled outcome once the open was revoked")
        }
    }
}
