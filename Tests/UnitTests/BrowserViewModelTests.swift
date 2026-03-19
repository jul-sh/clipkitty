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

    func testSelectedPreviewHighlightsRefreshWhenQueryChangesWithoutNavigation() async {
        let client = MockBrowserStoreClient()
        let item = makeItem(id: 1, text: "alpha beta")
        let firstDecoration = makePreviewDecoration(highlightStart: 0, highlightEnd: 1)
        let refinedDecoration = makePreviewDecoration(highlightStart: 0, highlightEnd: 2)
        client.previewDecorationsByQuery = [
            "a": [1: firstDecoration],
            "al": [1: refinedDecoration],
        ]

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.updateSearchText("a")
        try? await Task.sleep(for: .milliseconds(75))
        await flushMainActor()

        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "a", filter: .all),
            items: [makeMatch(id: 1, snippet: "alpha beta")],
            firstItem: item,
            totalCount: 1
        ))
        await flushMainActor()
        await flushMainActor()

        XCTAssertEqual(viewModel.selectedItemId, 1)
        XCTAssertEqual(viewModel.previewDecoration, firstDecoration)

        viewModel.updateSearchText("al")
        try? await Task.sleep(for: .milliseconds(75))
        await flushMainActor()

        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "al", filter: .all),
            items: [makeMatch(id: 1, snippet: "alpha beta")],
            firstItem: item,
            totalCount: 1
        ))
        await flushMainActor()
        await flushMainActor()

        XCTAssertEqual(viewModel.selectedItemId, 1)
        XCTAssertEqual(viewModel.previewDecoration, refinedDecoration)
        XCTAssertEqual(client.loadPreviewDecorationRequests.map(\.query), ["a", "al"])
    }

    func testStalePreviewDecorationCompletionDoesNotOverwriteNewQuery() async {
        let client = MockBrowserStoreClient()
        let item = makeItem(id: 1, text: "alpha beta")
        let staleDecoration = makePreviewDecoration(highlightStart: 0, highlightEnd: 1)
        let freshDecoration = makePreviewDecoration(highlightStart: 6, highlightEnd: 10)

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.updateSearchText("a")
        try? await Task.sleep(for: .milliseconds(75))
        await flushMainActor()
        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "a", filter: .all),
            items: [makeMatch(id: 1, snippet: "alpha beta")],
            firstItem: item,
            totalCount: 1
        ))
        await flushMainActor()

        viewModel.updateSearchText("be")
        try? await Task.sleep(for: .milliseconds(75))
        await flushMainActor()
        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "be", filter: .all),
            items: [makeMatch(id: 1, snippet: "alpha beta")],
            firstItem: item,
            totalCount: 1
        ))
        await flushMainActor()

        client.resumePreviewDecoration(itemId: 1, query: "a", with: staleDecoration)
        await flushMainActor()
        XCTAssertNil(viewModel.previewDecoration)

        client.resumePreviewDecoration(itemId: 1, query: "be", with: freshDecoration)
        await flushMainActor()
        await flushMainActor()

        XCTAssertEqual(viewModel.previewDecoration, freshDecoration)
    }

    func testStaleRowDecorationCompletionDoesNotMutateCurrentQueryOrPreview() async {
        let client = MockBrowserStoreClient()
        let item = makeItem(id: 1, text: "alpha beta")
        client.previewDecorationsByQuery = [
            "al": [1: makePreviewDecoration(highlightStart: 0, highlightEnd: 2)],
        ]

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.updateSearchText("a")
        try? await Task.sleep(for: .milliseconds(75))
        await flushMainActor()
        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "a", filter: .all),
            items: [makeMatch(id: 1, snippet: "alpha beta")],
            firstItem: item,
            totalCount: 1
        ))
        await flushMainActor()

        viewModel.loadRowDecorationsForItems([1])
        await flushMainActor()

        viewModel.updateSearchText("al")
        try? await Task.sleep(for: .milliseconds(75))
        await flushMainActor()
        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "al", filter: .all),
            items: [makeMatch(id: 1, snippet: "alpha beta")],
            firstItem: item,
            totalCount: 1
        ))
        await flushMainActor()
        await flushMainActor()

        let staleRowDecoration = RowDecoration(
            text: "alpha beta",
            highlights: [Utf16HighlightRange(utf16Start: 0, utf16End: 1, kind: .exact)],
            lineNumber: 1
        )
        client.resumeRowDecorations(
            itemIds: [1],
            query: "a",
            with: [RowDecorationResult(itemId: 1, decoration: staleRowDecoration)]
        )
        await flushMainActor()

        XCTAssertNil(viewModel.rowDecorationsByItemId[1])
        XCTAssertEqual(viewModel.previewDecoration?.highlights.first?.utf16End, 2)
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
        try? await Task.sleep(for: .milliseconds(3100))
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, [1, 2])
        XCTAssertEqual(viewModel.selectedItemId, 1)
        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, 1)

        guard case .failed = viewModel.mutationState else {
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

        guard case .failed = viewModel.mutationState else {
            return XCTFail("Expected failed mutation after clear rollback")
        }
    }

    func testUpdateSearchTextPreservesTrailingWhitespace() async {
        let client = MockBrowserStoreClient()
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.updateSearchText("report ")

        XCTAssertEqual(viewModel.searchText, "report ")

        try? await Task.sleep(for: .milliseconds(75))
        await flushMainActor()

        XCTAssertEqual(client.startedSearchRequests.last?.text, "report ")
    }

    func testWhitespaceOnlySearchPreservesRawInput() async {
        let client = MockBrowserStoreClient()
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.updateSearchText("   ")

        XCTAssertEqual(viewModel.searchText, "   ")

        try? await Task.sleep(for: .milliseconds(75))
        await flushMainActor()

        XCTAssertEqual(client.startedSearchRequests.last?.text, "   ")
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
            rowDecoration: nil
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

    private func makePreviewDecoration(
        highlightStart: UInt64,
        highlightEnd: UInt64
    ) -> PreviewDecoration {
        let highlight = Utf16HighlightRange(
            utf16Start: highlightStart,
            utf16End: highlightEnd,
            kind: .exact
        )
        return PreviewDecoration(
            highlights: [highlight],
            initialScrollHighlightIndex: 0
        )
    }
}

@MainActor
private final class MockBrowserStoreClient: BrowserStoreClient {
    struct RowDecorationRequest: Hashable {
        let itemIds: [Int64]
        let query: String
    }

    struct PreviewDecorationRequest: Hashable {
        let itemId: Int64
        let query: String
    }

    private var pendingSearchResponses: [BrowserSearchResponse] = []
    private var searchContinuations: [CheckedContinuation<BrowserSearchOutcome, Never>] = []
    var deleteResult: Result<Void, ClipboardError> = .success(())
    var clearResult: Result<Void, ClipboardError> = .success(())
    var startedSearchRequests: [SearchRequest] = []
    var loadRowDecorationRequests: [RowDecorationRequest] = []
    var loadPreviewDecorationRequests: [PreviewDecorationRequest] = []
    var rowDecorationsByQuery: [String: [Int64: RowDecoration]] = [:]
    var previewDecorationsByQuery: [String: [Int64: PreviewDecoration]] = [:]
    private var fetchContinuations: [Int64: [CheckedContinuation<ClipboardItem?, Never>]] = [:]
    private var rowDecorationContinuations: [RowDecorationRequest: [CheckedContinuation<[RowDecorationResult], Never>]] = [:]
    private var previewDecorationContinuations: [PreviewDecorationRequest: [CheckedContinuation<PreviewDecoration?, Never>]] = [:]

    func startSearch(request: SearchRequest) -> BrowserSearchOperation {
        startedSearchRequests.append(request)
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

    func loadRowDecorations(itemIds: [Int64], query: String) async -> [RowDecorationResult] {
        let request = RowDecorationRequest(itemIds: itemIds, query: query)
        loadRowDecorationRequests.append(request)

        if let decorationsByItemId = rowDecorationsByQuery[query] {
            return itemIds.map { itemId in
                RowDecorationResult(itemId: itemId, decoration: decorationsByItemId[itemId])
            }
        }

        return await withCheckedContinuation { continuation in
            rowDecorationContinuations[request, default: []].append(continuation)
        }
    }

    func loadPreviewDecoration(itemId: Int64, query: String) async -> PreviewDecoration? {
        let request = PreviewDecorationRequest(itemId: itemId, query: query)
        loadPreviewDecorationRequests.append(request)

        if let decorationsByItemId = previewDecorationsByQuery[query] {
            return decorationsByItemId[itemId]
        }

        return await withCheckedContinuation { continuation in
            previewDecorationContinuations[request, default: []].append(continuation)
        }
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

    func updateTextItem(itemId _: Int64, text _: String) async -> Result<Void, ClipboardError> {
        .success(())
    }

    func resumeFetch(id: Int64, with item: ClipboardItem?) {
        fetchContinuations.removeValue(forKey: id)?.forEach { $0.resume(returning: item) }
    }

    func resumeRowDecorations(itemIds: [Int64], query: String, with results: [RowDecorationResult]) {
        let request = RowDecorationRequest(itemIds: itemIds, query: query)
        rowDecorationContinuations.removeValue(forKey: request)?.forEach { $0.resume(returning: results) }
    }

    func resumePreviewDecoration(itemId: Int64, query: String, with decoration: PreviewDecoration?) {
        let request = PreviewDecorationRequest(itemId: itemId, query: query)
        previewDecorationContinuations.removeValue(forKey: request)?.forEach { $0.resume(returning: decoration) }
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
