import XCTest
import ClipKittyRust
@testable import ClipKitty

@MainActor
final class BrowserViewModelTests: XCTestCase {
    func testStaleSearchCompletionDoesNotOverwriteNewerSearchWithSameRequest() async {
        let client = MockBrowserStoreClient()
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        let staleResponse = BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: 1, snippet: "stale")],
            firstItem: nil,
            totalCount: 1
        )
        let freshResponse = BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: 2, snippet: "fresh")],
            firstItem: nil,
            totalCount: 1
        )

        viewModel.handleDisplayReset(initialSearchQuery: "")
        await flushMainActor()

        client.resumeSearch(with: staleResponse)
        await flushMainActor()
        XCTAssertTrue(viewModel.itemIds.isEmpty)

        client.resumeSearch(with: freshResponse)
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, [2])
        XCTAssertEqual(viewModel.selectedItemId, 2)
    }

    func testStalePreviewCompletionDoesNotOverwriteNewerSelection() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: 1, snippet: "one"), makeMatch(id: 2, snippet: "two")],
            firstItem: nil,
            totalCount: 2
        ))

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        XCTAssertEqual(viewModel.selectedItemId, 1)

        viewModel.select(itemId: 2, origin: .user)
        await flushMainActor()

        client.resumeFetch(id: 1, with: makeItem(id: 1, text: "first"))
        await flushMainActor()
        XCTAssertNil(viewModel.selectedItem)

        client.resumeFetch(id: 2, with: makeItem(id: 2, text: "second"))
        await flushMainActor()

        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, 2)
    }

    func testDeleteFailureRollsBackSearchAndSelection() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: 1, snippet: "one"), makeMatch(id: 2, snippet: "two")],
            firstItem: nil,
            totalCount: 2
        ))
        client.deleteResult = .failure(.databaseOperationFailed(
            operation: "deleteItem",
            underlying: NSError(domain: "ClipKitty", code: 1)
        ))

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()
        client.resumeFetch(id: 1, with: makeItem(id: 1, text: "first"))
        await flushMainActor()

        viewModel.deleteSelectedItem()
        await flushMainActor()
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, [1, 2])
        XCTAssertEqual(viewModel.selectedItemId, 1)
        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, 1)

        guard case .failed = viewModel.session.mutation else {
            return XCTFail("Expected failed mutation after delete rollback")
        }
    }

    func testClearFailureRestoresPreviousResults() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: 1, snippet: "one"), makeMatch(id: 2, snippet: "two")],
            firstItem: nil,
            totalCount: 2
        ))
        client.clearResult = .failure(.databaseOperationFailed(
            operation: "clear",
            underlying: NSError(domain: "ClipKitty", code: 2)
        ))

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()
        client.resumeFetch(id: 1, with: makeItem(id: 1, text: "first"))
        await flushMainActor()

        viewModel.clearAll()
        await flushMainActor()
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, [1, 2])
        XCTAssertEqual(viewModel.selectedItemId, 1)
        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, 1)

        guard case .failed = viewModel.session.mutation else {
            return XCTFail("Expected failed mutation after clear rollback")
        }
    }

    private func flushMainActor() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    private func makeMatch(id: Int64, snippet: String) -> ItemMatch {
        ItemMatch(
            itemMetadata: ItemMetadata(
                itemId: id,
                icon: .symbol(iconType: .text),
                snippet: snippet,
                sourceApp: nil,
                sourceAppBundleId: nil,
                timestampUnix: 0,
                tags: []
            ),
            matchData: nil
        )
    }

    private func makeItem(id: Int64, text: String) -> ClipboardItem {
        ClipboardItem(
            itemMetadata: ItemMetadata(
                itemId: id,
                icon: .symbol(iconType: .text),
                snippet: text,
                sourceApp: nil,
                sourceAppBundleId: nil,
                timestampUnix: 0,
                tags: []
            ),
            content: .text(value: text)
        )
    }
}

@MainActor
private final class MockBrowserStoreClient: BrowserStoreClient {
    private var pendingSearchResponses: [BrowserSearchResponse] = []
    private var searchContinuations: [CheckedContinuation<BrowserSearchOutcome, Never>] = []
    var deleteResult: Result<Void, ClipboardError> = .success(())
    var clearResult: Result<Void, ClipboardError> = .success(())
    private var fetchContinuations: [Int64: [CheckedContinuation<ClipboardItem?, Never>]] = [:]

    func startSearch(request: SearchRequest) -> BrowserSearchOperation {
        return MockBrowserSearchOperation(request: request) { [weak self] in
            guard let self else { return .cancelled }
            return await self.nextSearchOutcome()
        }
    }

    func nextSearchOutcome() async -> BrowserSearchOutcome {
        if !pendingSearchResponses.isEmpty {
            return .success(pendingSearchResponses.removeFirst())
        }
        return await withCheckedContinuation { continuation in
            searchContinuations.append(continuation)
        }
    }

    func fetchItem(id: Int64) async -> ClipboardItem? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                fetchContinuations[id, default: []].append(continuation)
            }
        } onCancel: {
            Task { @MainActor in
                fetchContinuations[id]?.forEach { $0.resume(returning: nil) }
                fetchContinuations.removeValue(forKey: id)
            }
        }
    }

    func loadMatchData(itemIds: [Int64], query: String) async -> [MatchData] {
        []
    }

    func fetchLinkMetadata(url: String, itemId: Int64) async -> ClipboardItem? {
        nil
    }

    func addTag(itemId: Int64, tag: ItemTag) async -> Result<Void, ClipboardError> {
        .success(())
    }

    func removeTag(itemId: Int64, tag: ItemTag) async -> Result<Void, ClipboardError> {
        .success(())
    }

    func delete(itemId: Int64) async -> Result<Void, ClipboardError> {
        deleteResult
    }

    func clear() async -> Result<Void, ClipboardError> {
        clearResult
    }

    func resumeFetch(id: Int64, with item: ClipboardItem?) {
        fetchContinuations.removeValue(forKey: id)?.forEach { $0.resume(returning: item) }
    }

    func enqueueSearchResponse(_ response: BrowserSearchResponse) {
        if searchContinuations.isEmpty {
            pendingSearchResponses.append(response)
        } else {
            resumeSearch(with: response)
        }
    }

    func resumeSearch(with response: BrowserSearchResponse) {
        guard !searchContinuations.isEmpty else {
            pendingSearchResponses.append(response)
            return
        }
        searchContinuations.removeFirst().resume(returning: .success(response))
    }

    func cancelNextSearch() {
        guard !searchContinuations.isEmpty else { return }
        searchContinuations.removeFirst().resume(returning: .cancelled)
    }
}

private final class MockBrowserSearchOperation: BrowserSearchOperation {
    let request: SearchRequest
    private let loader: @Sendable () async -> BrowserSearchOutcome
    private let lock = NSLock()
    private var isCancelled = false

    init(request: SearchRequest, loader: @escaping @Sendable () async -> BrowserSearchOutcome) {
        self.request = request
        self.loader = loader
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func awaitOutcome() async -> BrowserSearchOutcome {
        if cancelled {
            return .cancelled
        }
        let outcome = await loader()
        if cancelled {
            return .cancelled
        }
        return outcome
    }

    private var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }
}
