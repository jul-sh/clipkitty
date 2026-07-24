@testable import ClipKitty
@testable import ClipKittyBrowser
import ClipKittyCore
import ClipKittyRust
import XCTest

@MainActor
final class BrowserSearchLifecycleTests: XCTestCase {
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
            items: [makeMatch(id: "1", excerpt: "stale")],
            firstPreviewPayload: nil,
            totalCount: 1
        )
        let freshResponse = BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "2", excerpt: "fresh")],
            firstPreviewPayload: nil,
            totalCount: 1
        )

        viewModel.handleDisplayReset(initialSearchQuery: "")
        await flushMainActor()

        client.resumeSearch(with: staleResponse)
        await flushMainActor()
        XCTAssertTrue(viewModel.itemIds.isEmpty)

        client.resumeSearch(with: freshResponse)
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, ["2"])
        XCTAssertEqual(viewModel.selectedItemId, "2")
    }

    func testPrepareForSuspensionCancelsSearchWithoutStartingReplacement() async {
        let client = MockBrowserStoreClient()
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()
        XCTAssertEqual(client.startedSearchRequests.count, 1)

        viewModel.prepareForSuspension()
        await flushMainActor()

        try? await Task.sleep(for: .milliseconds(300))
        guard case .loading(_, _, .runningWaitingForSpinner) = viewModel.contentState else {
            return XCTFail("A cancelled search timer must not promote the suspended state")
        }

        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "late")],
            firstPreviewPayload: nil,
            totalCount: 1
        ))
        await flushMainActor()

        XCTAssertTrue(viewModel.itemIds.isEmpty)
        XCTAssertEqual(client.startedSearchRequests.count, 1)
    }

    func testExternallyCancelledInFlightSearchResubmitsCurrentRequest() async {
        let client = MockBrowserStoreClient()
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()
        XCTAssertEqual(client.startedSearchRequests.count, 1)

        // Deliver a .cancelled outcome to the CURRENT operation, simulating another
        // consumer of the shared Rust store cancelling the global search token.
        client.cancelNextSearch()
        await flushMainActor()

        XCTAssertEqual(client.startedSearchRequests.count, 2)

        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "recovered")],
            firstPreviewPayload: nil,
            totalCount: 1
        ))
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, ["1"])
        XCTAssertEqual(viewModel.selectedItemId, "1")
        guard case .loaded = viewModel.contentState else {
            return XCTFail("Expected recovered search to finish loading")
        }
    }

    func testSearchSpinnerTracksTheRunningSearchPhase() async {
        let client = MockBrowserStoreClient()
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()
        guard case .loading(_, _, .runningWaitingForSpinner) = viewModel.contentState else {
            return XCTFail("Expected running search to wait before showing its spinner")
        }

        try? await Task.sleep(for: .milliseconds(300))
        guard case .loading(_, _, .runningShowingSpinner) = viewModel.contentState else {
            return XCTFail("Expected delayed spinner to become part of the running phase")
        }

        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [],
            firstPreviewPayload: nil,
            totalCount: 0
        ))
        await flushMainActor()

        guard case .loaded = viewModel.contentState else {
            return XCTFail("Expected completed search to leave the spinner phases")
        }
    }

    func testVisiblePanelAfterSuspensionRestartsCancelledInitialSearch() async {
        let client = MockBrowserStoreClient()
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()
        XCTAssertEqual(client.startedSearchRequests.count, 1)

        viewModel.prepareForSuspension()
        await flushMainActor()

        viewModel.handlePanelVisibilityChange(true, contentRevision: 0)
        await flushMainActor()

        XCTAssertEqual(client.startedSearchRequests.count, 2)

        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "stale", excerpt: "stale")],
            firstPreviewPayload: nil,
            totalCount: 1
        ))
        await flushMainActor()
        XCTAssertTrue(viewModel.itemIds.isEmpty)

        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "fresh", excerpt: "fresh")],
            firstPreviewPayload: nil,
            totalCount: 1
        ))
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, ["fresh"])
        XCTAssertEqual(viewModel.selectedItemId, "fresh")
    }

    func testDisplayResetKeepsPreviousResultsVisible() async {
        let client = MockBrowserStoreClient()
        let firstItem = makeItem(id: "1", text: "first")
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "first")],
            firstItem: firstItem,
            totalCount: 1
        ))

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, ["1"])
        XCTAssertEqual(viewModel.selectedItemId, "1")

        viewModel.handleDisplayReset(initialSearchQuery: "")
        await flushMainActor()

        guard case let .loading(request, previous, _) = viewModel.contentState else {
            return XCTFail("Expected display reset to preserve stale results while refreshing")
        }
        XCTAssertEqual(request, SearchRequest(text: "", filter: .all))
        XCTAssertEqual(previous?.response.items.map(\.itemMetadata.itemId), ["1"])
        XCTAssertEqual(viewModel.itemIds, ["1"])
        // Selection clears immediately on display reset so the panel re-opens
        // at the top of the list rather than keeping the prior highlight.
        XCTAssertNil(viewModel.selectedItemId)

        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "first"), makeMatch(id: "2", excerpt: "second")],
            firstItem: firstItem,
            totalCount: 2
        ))
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, ["1", "2"])
        XCTAssertEqual(viewModel.selectedItemId, "1")
    }

    func testHiddenContentRevisionRefreshKeepsPreviousResultsVisible() async {
        let client = MockBrowserStoreClient()
        let firstItem = makeItem(id: "1", text: "first")
        let secondItem = makeItem(id: "2", text: "second")
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "first")],
            firstItem: firstItem,
            totalCount: 1
        ))

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, ["1"])
        XCTAssertEqual(viewModel.selectedItemId, "1")

        viewModel.handleContentRevisionChange(1, isPanelVisible: false)
        await flushMainActor()

        XCTAssertEqual(client.startedSearchRequests, [
            SearchRequest(text: "", filter: .all),
            SearchRequest(text: "", filter: .all),
        ])

        guard case let .loading(request, previous, _) = viewModel.contentState else {
            return XCTFail("Expected a background refresh while hidden")
        }
        XCTAssertEqual(request, SearchRequest(text: "", filter: .all))
        XCTAssertEqual(previous?.response.items.map(\.itemMetadata.itemId), ["1"])

        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "2", excerpt: "second"), makeMatch(id: "1", excerpt: "first")],
            firstItem: secondItem,
            totalCount: 2
        ))
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, ["2", "1"])
        XCTAssertEqual(viewModel.selectedItemId, "2")
    }

    func testVisibleContentRevisionWaitsUntilPanelIsShownAgain() async {
        let client = MockBrowserStoreClient()
        let firstItem = makeItem(id: "1", text: "first")
        let secondItem = makeItem(id: "2", text: "second")
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "first")],
            firstItem: firstItem,
            totalCount: 1
        ))

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        viewModel.handleContentRevisionChange(1, isPanelVisible: true)
        await flushMainActor()

        XCTAssertEqual(client.startedSearchRequests.count, 1)
        XCTAssertEqual(viewModel.itemIds, ["1"])

        viewModel.handlePanelVisibilityChange(false, contentRevision: 1)
        viewModel.handlePanelVisibilityChange(true, contentRevision: 1)
        await flushMainActor()

        XCTAssertEqual(client.startedSearchRequests.count, 2)
        guard case let .loading(request, previous, _) = viewModel.contentState else {
            return XCTFail("Expected reveal refresh to preserve stale results")
        }
        XCTAssertEqual(request, SearchRequest(text: "", filter: .all))
        XCTAssertEqual(previous?.response.items.map(\.itemMetadata.itemId), ["1"])

        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "2", excerpt: "second")],
            firstItem: secondItem,
            totalCount: 1
        ))
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, ["2"])
        XCTAssertEqual(viewModel.selectedItemId, "2")
    }

    func testPanelShowDoesNotDuplicateHiddenRefreshAlreadyInFlight() async {
        let client = MockBrowserStoreClient()
        let firstItem = makeItem(id: "1", text: "first")
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "first")],
            firstItem: firstItem,
            totalCount: 1
        ))

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        viewModel.handleContentRevisionChange(1, isPanelVisible: false)
        await flushMainActor()
        XCTAssertEqual(client.startedSearchRequests.count, 2)

        viewModel.handlePanelVisibilityChange(true, contentRevision: 1)
        await flushMainActor()

        XCTAssertEqual(client.startedSearchRequests.count, 2)
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
}
