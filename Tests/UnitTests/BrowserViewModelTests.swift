@testable import ClipKitty
import ClipKittyRust
@testable import ClipKittyShared
import XCTest

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
        XCTAssertFalse(viewModel.searchSpinnerVisible)
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

    func testStalePreviewCompletionDoesNotOverwriteNewerSelection() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
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

        XCTAssertEqual(viewModel.selectedItemId, "1")

        viewModel.select(itemId: "2", origin: .click)
        await flushMainActor()

        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await flushMainActor()
        XCTAssertNil(viewModel.selectedItem)

        client.resumeFetch(id: "2", with: makeItem(id: "2", text: "second"))
        await flushMainActor()

        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, "2")
    }

    func testDisplayResetKeepsPreviousResultsVisible() async {
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

    func testSelectedPreviewHighlightsRefreshWhenQueryChangesWithoutNavigation() async {
        let client = MockBrowserStoreClient()
        let item = makeItem(id: "1", text: "alpha beta")
        let firstDecoration = makePreviewDecoration(highlightStart: 0, highlightEnd: 1)
        let refinedDecoration = makePreviewDecoration(highlightStart: 0, highlightEnd: 2)
        client.previewPayloadsByQuery = [
            "a": ["1": makePreviewPayload(item: item, decoration: firstDecoration)],
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
            items: [makeDeferredMatch(id: "1", text: "alpha beta", query: "a")],
            firstItem: item,
            totalCount: 1
        ))
        await flushMainActor()
        await flushMainActor()

        XCTAssertEqual(viewModel.selectedItemId, "1")
        XCTAssertEqual(viewModel.previewDecoration, firstDecoration)

        viewModel.updateSearchText("al")
        try? await Task.sleep(for: .milliseconds(75))
        await flushMainActor()

        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "al", filter: .all),
            items: [makeDeferredMatch(id: "1", text: "alpha beta", query: "al")],
            firstItem: item,
            totalCount: 1
        ))
        await flushMainActor()
        await flushMainActor()

        guard case let .selected(selectedItemState) = viewModel.selection else {
            return XCTFail("Expected selected item to stay visible while fresh highlights load")
        }
        XCTAssertEqual(selectedItemState.item.itemMetadata.itemId, "1")
        guard case let .loadingDecoration(previous: .some(staleDecoration)) = selectedItemState.previewState else {
            return XCTFail("Expected stale highlights while updated preview payload is pending")
        }
        XCTAssertEqual(staleDecoration, firstDecoration)
        XCTAssertEqual(viewModel.previewDecoration, firstDecoration)

        client.resumePreviewPayload(
            itemId: "1",
            query: "al",
            with: makePreviewPayload(item: item, decoration: refinedDecoration)
        )
        await flushMainActor()
        await flushMainActor()

        XCTAssertEqual(viewModel.selectedItemId, "1")
        XCTAssertEqual(viewModel.previewDecoration, refinedDecoration)
        XCTAssertEqual(client.loadPreviewDecorationRequests.map(\.query), ["a", "al"])
    }

    func testActiveTextQueryKeepsSelectionVisibleWhilePreviewPayloadArrives() async {
        let client = MockBrowserStoreClient()
        let item = makeItem(id: "1", text: "alpha beta")
        let decoration = makePreviewDecoration(highlightStart: 0, highlightEnd: 1)

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.updateSearchText("a")
        // Queued on the mock until the debounced search starts, then applied.
        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "a", filter: .all),
            items: [makeDeferredMatch(id: "1", text: "alpha beta", query: "a")],
            firstItem: item,
            totalCount: 1
        ))
        let selectionSettled = await settle { viewModel.selectedItemState != nil }
        XCTAssertTrue(selectionSettled, "Selection should become visible once the search response lands")

        guard case let .selected(selectedItemState) = viewModel.selection else {
            return XCTFail("Expected selected item to stay visible before preview payload arrives")
        }
        XCTAssertEqual(selectedItemState.item.itemMetadata.itemId, "1")
        guard case .loadingDecoration(previous: nil) = selectedItemState.previewState else {
            return XCTFail("Expected plain content with highlights still loading")
        }
        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, "1")
        XCTAssertNil(viewModel.previewDecoration)

        client.resumePreviewPayload(
            itemId: "1",
            query: "a",
            with: makePreviewPayload(item: item, decoration: decoration)
        )
        let decorationSettled = await settle { viewModel.previewDecoration != nil }
        XCTAssertTrue(decorationSettled, "The decoration should arrive once the preview payload resumes")

        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, "1")
        XCTAssertEqual(viewModel.previewDecoration, decoration)
    }

    func testDecoratedFirstPreviewPayloadAvoidsFollowupPreviewLoad() async {
        let client = MockBrowserStoreClient()
        let item = makeItem(id: "1", text: "alpha beta")
        let decoration = makePreviewDecoration(highlightStart: 0, highlightEnd: 2)

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.updateSearchText("al")
        try? await Task.sleep(for: .milliseconds(75))
        await flushMainActor()

        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "al", filter: .all),
            items: [makeMatch(id: "1", excerpt: "alpha beta")],
            firstPreviewPayload: makePreviewPayload(item: item, decoration: decoration),
            totalCount: 1
        ))
        await flushMainActor()
        await flushMainActor()

        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, "1")
        XCTAssertEqual(viewModel.previewDecoration, decoration)
        XCTAssertTrue(client.loadPreviewDecorationRequests.isEmpty)
    }

    func testQueryChangeDoesNotReuseUndecoratedBrowsePreviewForHighlightedText() async {
        let client = MockBrowserStoreClient()
        let item = makeItem(id: "1", text: "alpha beta")
        let decoration = makePreviewDecoration(highlightStart: 0, highlightEnd: 2)
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "alpha beta")],
            firstItem: item,
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
        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, "1")
        XCTAssertNil(viewModel.previewDecoration)

        viewModel.updateSearchText("al")
        await flushMainActor()

        guard case let .selected(staleSelection) = viewModel.selection else {
            return XCTFail("Expected selected item to stay visible while search results are pending")
        }
        XCTAssertEqual(staleSelection.item.itemMetadata.itemId, "1")
        guard case .loadingDecoration(previous: nil) = staleSelection.previewState else {
            return XCTFail("Expected stale preview content to remain visible while fresh highlights load")
        }
        XCTAssertEqual(viewModel.selectedItemId, "1")
        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, "1")
        XCTAssertNil(viewModel.previewDecoration)

        try? await Task.sleep(for: .milliseconds(75))
        await flushMainActor()

        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "al", filter: .all),
            items: [makeMatch(id: "1", excerpt: "alpha beta")],
            firstItem: item,
            totalCount: 1
        ))
        await flushMainActor()

        guard case let .selected(selectedItemState) = viewModel.selection else {
            return XCTFail("Expected selected item to stay visible while highlighted preview payload is pending")
        }
        XCTAssertEqual(selectedItemState.item.itemMetadata.itemId, "1")
        guard case .loadingDecoration(previous: nil) = selectedItemState.previewState else {
            return XCTFail("Expected plain content with highlights still loading")
        }
        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, "1")
        XCTAssertNil(viewModel.previewDecoration)
        XCTAssertEqual(client.loadPreviewDecorationRequests.map(\.query), ["al"])

        client.resumePreviewPayload(
            itemId: "1",
            query: "al",
            with: makePreviewPayload(item: item, decoration: decoration)
        )
        await flushMainActor()
        await flushMainActor()

        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, "1")
        XCTAssertEqual(viewModel.previewDecoration, decoration)
    }

    func testStalePreviewDecorationCompletionDoesNotOverwriteNewQuery() async {
        let client = MockBrowserStoreClient()
        let item = makeItem(id: "1", text: "alpha beta")
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
            items: [makeMatch(id: "1", excerpt: "alpha beta")],
            firstItem: item,
            totalCount: 1
        ))
        await flushMainActor()

        viewModel.updateSearchText("be")
        try? await Task.sleep(for: .milliseconds(75))
        await flushMainActor()
        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "be", filter: .all),
            items: [makeMatch(id: "1", excerpt: "alpha beta")],
            firstItem: item,
            totalCount: 1
        ))
        await flushMainActor()

        client.resumePreviewPayload(
            itemId: "1",
            query: "a",
            with: makePreviewPayload(item: item, decoration: staleDecoration)
        )
        await flushMainActor()
        XCTAssertNil(viewModel.previewDecoration)

        client.resumePreviewPayload(
            itemId: "1",
            query: "be",
            with: makePreviewPayload(item: item, decoration: freshDecoration)
        )
        await flushMainActor()
        await flushMainActor()

        XCTAssertEqual(viewModel.previewDecoration, freshDecoration)
    }

    func testUndecoratedFreshPreviewClearsStaleHighlight() async {
        let client = MockBrowserStoreClient()
        let item = makeItem(id: "1", text: "hello_arrr")
        let staleDecoration = makePreviewDecoration(highlightStart: 0, highlightEnd: 6)

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.updateSearchText("hello")
        try? await Task.sleep(for: .milliseconds(75))
        await flushMainActor()
        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "hello", filter: .all),
            items: [makeMatch(id: "1", excerpt: "hello_arrr")],
            firstItem: item,
            totalCount: 1
        ))
        await flushMainActor()

        client.resumePreviewPayload(
            itemId: "1",
            query: "hello",
            with: makePreviewPayload(item: item, decoration: staleDecoration)
        )
        await flushMainActor()
        await flushMainActor()
        XCTAssertEqual(viewModel.previewDecoration, staleDecoration)

        viewModel.updateSearchText("hello_arr")
        await flushMainActor()

        guard case let .selected(staleSelection) = viewModel.selection else {
            return XCTFail("Expected stale selection while new search is pending")
        }
        XCTAssertEqual(staleSelection.item.itemMetadata.itemId, "1")
        XCTAssertEqual(viewModel.previewDecoration, staleDecoration)

        try? await Task.sleep(for: .milliseconds(75))
        await flushMainActor()
        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "hello_arr", filter: .all),
            items: [makeMatch(id: "1", excerpt: "hello_arrr")],
            firstItem: item,
            totalCount: 1
        ))
        await flushMainActor()

        client.resumePreviewPayload(
            itemId: "1",
            query: "hello_arr",
            with: makePreviewPayload(item: item, decoration: nil)
        )
        await flushMainActor()
        await flushMainActor()

        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, "1")
        XCTAssertNil(viewModel.previewDecoration)
        guard case let .selected(selectedItemState) = viewModel.selection else {
            return XCTFail("Expected selected item after fresh preview load")
        }
        guard case .plain = selectedItemState.previewState else {
            return XCTFail("Expected stale highlight to clear when fresh preview has no decoration")
        }
    }

    func testStaleRowDecorationCompletionDoesNotMutateCurrentQueryOrPreview() async {
        let client = MockBrowserStoreClient()
        let item = makeItem(id: "1", text: "alpha beta")
        client.previewPayloadsByQuery = [
            "al": ["1": makePreviewPayload(
                item: item,
                decoration: makePreviewDecoration(highlightStart: 0, highlightEnd: 2)
            )],
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
            items: [makeDeferredMatch(id: "1", text: "alpha beta", query: "a")],
            firstItem: item,
            totalCount: 1
        ))
        await flushMainActor()

        viewModel.loadMatchedExcerptsForItems(["1"])
        await flushMainActor()

        viewModel.updateSearchText("al")
        try? await Task.sleep(for: .milliseconds(75))
        await flushMainActor()
        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "al", filter: .all),
            items: [makeDeferredMatch(id: "1", text: "alpha beta", query: "al")],
            firstItem: item,
            totalCount: 1
        ))
        await flushMainActor()
        await flushMainActor()

        let staleMatchedExcerpt = MatchedExcerpt(
            text: "alpha beta",
            highlights: [Utf16HighlightRange(utf16Start: 0, utf16End: 1, kind: .exact)],
            lineNumber: 1
        )
        client.resumeMatchedExcerpts(
            itemIds: ["1"],
            query: "a",
            with: [.ready(itemId: "1", excerpt: staleMatchedExcerpt)]
        )
        await flushMainActor()

        XCTAssertNil(viewModel.resolvedMatchedExcerptsByItemId["1"])
        XCTAssertEqual(viewModel.previewDecoration?.highlights.first?.utf16End, 2)
    }

    func testMatchedExcerptLoadingDeduplicatesItemsAlreadyInFlight() async {
        let client = MockBrowserStoreClient()
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
            items: [
                makeDeferredMatch(id: "1", text: "alpha", query: "a"),
                makeDeferredMatch(id: "2", text: "beta", query: "a"),
                makeDeferredMatch(id: "3", text: "gamma", query: "a"),
            ],
            firstPreviewPayload: nil,
            totalCount: 3
        ))
        await flushMainActor()

        viewModel.loadMatchedExcerptsForItems(["1", "2"])
        viewModel.loadMatchedExcerptsForItems(["2", "3"])
        await flushMainActor()

        XCTAssertEqual(client.resolveMatchedExcerptRequests.count, 2)
        XCTAssertTrue(client.resolveMatchedExcerptRequests.contains(.init(itemIds: ["1", "2"], query: "a")))
        XCTAssertTrue(client.resolveMatchedExcerptRequests.contains(.init(itemIds: ["3"], query: "a")))
    }

    func testDeleteFailureRollsBackSearchAndSelection() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
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
            onDismiss: {},
            deleteCommitDelay: 0.05
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await flushMainActor()

        viewModel.deleteSelectedItem()
        await flushMainActor()
        try? await Task.sleep(for: .milliseconds(300))
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, ["1", "2"])
        XCTAssertEqual(viewModel.selectedItemId, "1")
        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, "1")

        guard case .failed = viewModel.mutationState else {
            return XCTFail("Expected failed mutation after delete rollback")
        }
    }

    func testClearFailureRestoresPreviousResults() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
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
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await flushMainActor()

        viewModel.clearAll()
        await flushMainActor()
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, ["1", "2"])
        XCTAssertEqual(viewModel.selectedItemId, "1")

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

    func testAddTagUpdatesPreviewOptimistically() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one")],
            firstPreviewPayload: nil,
            totalCount: 1
        ))

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.onAppear(initialSearchQuery: "")
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        let itemSettled = await settle { viewModel.selectedItem != nil }
        XCTAssertTrue(itemSettled, "The selected item should resolve once its fetch resumes")

        viewModel.addTagToSelectedItem(.bookmark)

        XCTAssertTrue(viewModel.selectedItem?.itemMetadata.tags.contains(.bookmark) == true)
        XCTAssertTrue(viewModel.contentState.items.first?.itemMetadata.tags.contains(.bookmark) == true)
    }

    func testTagMutationFailureRollsBackState() async {
        let client = MockBrowserStoreClient()
        client.addTagResult = .failure(.databaseOperationFailed(
            operation: "addTag",
            underlying: NSError(domain: "ClipKitty", code: 3)
        ))
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one")],
            firstPreviewPayload: nil,
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
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await flushMainActor()

        viewModel.addTagToSelectedItem(.bookmark)
        await flushMainActor()

        XCTAssertFalse(viewModel.selectedItem?.itemMetadata.tags.contains(.bookmark) ?? true)
        XCTAssertFalse(viewModel.contentState.items.first?.itemMetadata.tags.contains(.bookmark) ?? true)

        guard case .failed = viewModel.mutationState else {
            return XCTFail("Expected failed mutation after tag rollback")
        }
    }

    func testRemoveTagUnderFilterRemovesItemAndAdvancesSelection() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .tagged(tag: .bookmark)),
            items: [
                makeMatch(id: "1", excerpt: "one", tags: [.bookmark]),
                makeMatch(id: "2", excerpt: "two", tags: [.bookmark]),
            ],
            firstPreviewPayload: nil,
            totalCount: 2
        ))

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.applyFilter(.bookmarks)
        await flushMainActor()
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first", tags: [.bookmark]))
        await flushMainActor()

        viewModel.removeTagFromSelectedItem(.bookmark)
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, ["2"])
        XCTAssertEqual(viewModel.selectedItemId, "2")
        XCTAssertFalse(viewModel.itemIds.contains("1"))
    }

    func testDeleteOptimisticallyRemovesAndAdvancesSelection() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [
                makeMatch(id: "1", excerpt: "one"),
                makeMatch(id: "2", excerpt: "two"),
                makeMatch(id: "3", excerpt: "three"),
            ],
            firstPreviewPayload: nil,
            totalCount: 3
        ))

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await flushMainActor()

        viewModel.deleteSelectedItem()
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, ["2", "3"])
        XCTAssertEqual(viewModel.selectedItemId, "2")

        guard case .deleting(.pending(_)) = viewModel.mutationState else {
            return XCTFail("Expected pending delete mutation")
        }
    }

    func testUndoDeleteRestoresItemAndSelection() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
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
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await flushMainActor()

        viewModel.deleteSelectedItem()
        await flushMainActor()

        viewModel.undoPendingDelete()
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, ["1", "2"])
        XCTAssertEqual(viewModel.selectedItemId, "1")
        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, "1")

        guard case .idle = viewModel.mutationState else {
            return XCTFail("Expected idle mutation after undo")
        }
    }

    func testDeleteCommitDismissesUndoSnackbarWhenWindowEnds() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
            totalCount: 2
        ))

        var dismissCount = 0
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {},
            dismissSnackbarNotification: { dismissCount += 1 },
            deleteCommitDelay: 0.05
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await flushMainActor()

        viewModel.deleteSelectedItem()
        await flushMainActor()

        XCTAssertEqual(dismissCount, 0)

        try? await Task.sleep(for: .milliseconds(300))
        await flushMainActor()

        XCTAssertEqual(dismissCount, 1)
        XCTAssertEqual(client.deletedItemIds, ["1"])
        guard case .idle = viewModel.mutationState else {
            return XCTFail("Expected idle mutation after commit")
        }
    }

    func testHandleDisplayResetCommitsPendingDelete() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
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
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await flushMainActor()

        viewModel.deleteSelectedItem()
        await flushMainActor()
        guard case .deleting(.pending) = viewModel.mutationState else {
            return XCTFail("Expected pending delete before reset")
        }

        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
            totalCount: 1
        ))
        viewModel.handleDisplayReset(initialSearchQuery: "")
        await flushMainActor()

        XCTAssertEqual(client.deletedItemIds, ["1"])
        XCTAssertFalse(viewModel.itemIds.contains("1"))
    }

    func testPrepareForSuspensionCommitsPendingDelete() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
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
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await flushMainActor()

        viewModel.deleteSelectedItem()
        await flushMainActor()
        guard case .deleting(.pending) = viewModel.mutationState else {
            return XCTFail("Expected pending delete before suspension")
        }

        viewModel.prepareForSuspension()
        await flushMainActor()

        XCTAssertEqual(client.deletedItemIds, ["1"])
    }

    func testDeleteLastItemClearsSelection() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one")],
            firstPreviewPayload: nil,
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
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await flushMainActor()

        viewModel.deleteSelectedItem()
        await flushMainActor()

        XCTAssertTrue(viewModel.itemIds.isEmpty)
        XCTAssertNil(viewModel.selectedItemId)

        guard case .none = viewModel.selection else {
            return XCTFail("Expected no selection after deleting final item")
        }
    }

    func testCommitEditUpdatesPreviewOptimistically() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "original text")],
            firstPreviewPayload: nil,
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
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "original text"))
        await flushMainActor()

        viewModel.onTextEdit("edited text", for: "1", originalText: "original text")
        viewModel.commitCurrentEdit()
        await flushMainActor()

        guard case let .text(value)? = viewModel.selectedItem?.content else {
            return XCTFail("Expected selected item text content")
        }
        XCTAssertEqual(value, "edited text")
        guard case let .baseline(excerpt)? = viewModel.contentState.items.first?.presentation else {
            return XCTFail("Expected optimistic baseline excerpt")
        }
        XCTAssertTrue(excerpt.text.contains("edited"))
        XCTAssertEqual(client.updatedTexts.count, 1)
        XCTAssertEqual(client.updatedTexts.first?.itemId, "1")
        XCTAssertEqual(client.updatedTexts.first?.text, "edited text")
        XCTAssertEqual(viewModel.editSession, .inactive)
    }

    func testDiscardEditClearsPendingState() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "original text")],
            firstPreviewPayload: nil,
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
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "original text"))
        await flushMainActor()

        viewModel.onTextEdit("edited text", for: "1", originalText: "original text")
        viewModel.onEditingStateChange(true, for: "1")

        viewModel.discardCurrentEdit()
        await flushMainActor()

        XCTAssertEqual(viewModel.editSession, .inactive)
    }

    func testEditRevertedToOriginalClearsPendingEdit() {
        let client = MockBrowserStoreClient()
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.onTextEdit("edited", for: "1", originalText: "original")
        XCTAssertEqual(viewModel.editSession, .dirty(itemId: "1", draft: "edited"))

        viewModel.onTextEdit("original", for: "1", originalText: "original")

        XCTAssertEqual(viewModel.editSession, .focused(itemId: "1"))
    }

    // MARK: - Edit Session States

    func testEditSessionIsInactiveByDefault() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "hello")],
            firstPreviewPayload: nil,
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
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "hello"))
        await flushMainActor()

        XCTAssertEqual(viewModel.editSession, .inactive)
    }

    func testEditSessionIsFocusedWhenEditingWithoutChanges() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "hello")],
            firstPreviewPayload: nil,
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
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "hello"))
        await flushMainActor()

        viewModel.onEditingStateChange(true, for: "1")

        XCTAssertEqual(viewModel.editSession, .focused(itemId: "1"))
    }

    func testEditSessionIsDirtyWhenTextChanged() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "hello")],
            firstPreviewPayload: nil,
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
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "hello"))
        await flushMainActor()

        viewModel.onEditingStateChange(true, for: "1")
        viewModel.onTextEdit("hello world", for: "1", originalText: "hello")

        XCTAssertEqual(viewModel.editSession, .dirty(itemId: "1", draft: "hello world"))
    }

    func testDirtyEditSurvivesNavigationAwayAndBack() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [
                makeMatch(id: "1", excerpt: "first"),
                makeMatch(id: "2", excerpt: "second"),
            ],
            firstItem: makeItem(id: "1", text: "first"),
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
        viewModel.onTextEdit("first edited", for: "1", originalText: "first")

        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedItemId, "2")
        XCTAssertEqual(viewModel.editSession, .suspendedDirty(itemId: "1", draft: "first edited"))

        // Focusing or typing into another preview cannot silently replace the
        // one pending draft. The UI renders this second preview read-only.
        viewModel.onEditingStateChange(true, for: "2")
        viewModel.onTextEdit("second edited", for: "2", originalText: "second")
        XCTAssertEqual(viewModel.editSession, .suspendedDirty(itemId: "1", draft: "first edited"))

        viewModel.moveSelection(by: -1)
        XCTAssertEqual(viewModel.selectedItemId, "1")
        XCTAssertEqual(viewModel.editSession, .dirty(itemId: "1", draft: "first edited"))
    }

    func testDirtyEditSurvivesTemporarySearchFiltering() async {
        let client = MockBrowserStoreClient()
        let firstItem = makeItem(id: "1", text: "first")
        let secondItem = makeItem(id: "2", text: "second")
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [
                makeMatch(id: "1", excerpt: "first"),
                makeMatch(id: "2", excerpt: "second"),
            ],
            firstItem: firstItem,
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
        viewModel.onTextEdit("first edited", for: "1", originalText: "first")

        viewModel.updateSearchText("second")
        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "second", filter: .all),
            items: [makeMatch(id: "2", excerpt: "second")],
            firstItem: secondItem,
            totalCount: 1
        ))
        let filteredSearchSettled = await settle { viewModel.selectedItemId == "2" }
        XCTAssertTrue(filteredSearchSettled)
        XCTAssertEqual(viewModel.editSession, .suspendedDirty(itemId: "1", draft: "first edited"))

        viewModel.updateSearchText("")
        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [
                makeMatch(id: "1", excerpt: "first"),
                makeMatch(id: "2", excerpt: "second"),
            ],
            firstItem: firstItem,
            totalCount: 2
        ))
        let restoredSearchSettled = await settle { viewModel.selectedItemId == "1" }
        XCTAssertTrue(restoredSearchSettled)
        XCTAssertEqual(viewModel.editSession, .dirty(itemId: "1", draft: "first edited"))
    }

    func testEditSessionReturnsToInactiveAfterDiscard() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "hello")],
            firstPreviewPayload: nil,
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
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "hello"))
        await flushMainActor()

        viewModel.onEditingStateChange(true, for: "1")
        viewModel.onTextEdit("hello world", for: "1", originalText: "hello")
        XCTAssertEqual(viewModel.editSession, .dirty(itemId: "1", draft: "hello world"))

        viewModel.discardCurrentEdit()

        XCTAssertEqual(viewModel.editSession, .inactive)
    }

    func testMoveSelectionNavigatesList() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [
                makeMatch(id: "1", excerpt: "one"),
                makeMatch(id: "2", excerpt: "two"),
                makeMatch(id: "3", excerpt: "three"),
            ],
            firstPreviewPayload: nil,
            totalCount: 3
        ))

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        XCTAssertEqual(viewModel.selectedItemId, "1")

        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedItemId, "2")

        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedItemId, "3")

        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedItemId, "3")
    }

    func testClearSuccessEmptiesAllState() async {
        let client = MockBrowserStoreClient()
        client.clearResult = .success(())
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
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
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await flushMainActor()

        viewModel.clearAll()
        await flushMainActor()
        await flushMainActor()

        XCTAssertTrue(viewModel.itemIds.isEmpty)
        XCTAssertNil(viewModel.selectedItemId)

        guard case .none = viewModel.selection else {
            return XCTFail("Expected no selection after clear")
        }
        guard case .idle = viewModel.mutationState else {
            return XCTFail("Expected idle mutation after clear success")
        }
    }

    func testPreviewLoadsOnInitialSearchWithFirstItem() async {
        let client = MockBrowserStoreClient()
        let item = makeItem(id: "1", text: "selected text")
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "selected text")],
            firstItem: item,
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

        XCTAssertEqual(viewModel.selectedItemId, "1")
        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, "1")
    }

    func testSelectionChangeTriggersPreviewLoad() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
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
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await flushMainActor()

        viewModel.select(itemId: "2", origin: .click)
        await flushMainActor()
        client.resumeFetch(id: "2", with: makeItem(id: "2", text: "second"))
        await flushMainActor()

        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, "2")
    }

    func testConfirmSelectionFiresCallback() async {
        let client = MockBrowserStoreClient()
        let item = makeItem(id: "1", text: "selected text")
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "selected text")],
            firstItem: item,
            totalCount: 1
        ))

        var selectedId: String?
        var selectedContent: ClipboardContent?
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { id, content in
                selectedId = id
                selectedContent = content
            },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        viewModel.confirmSelection()

        XCTAssertEqual(selectedId, "1")
        guard case let .text(value)? = selectedContent else {
            return XCTFail("Expected text content in onSelect callback")
        }
        XCTAssertEqual(value, "selected text")
    }

    func testCopyOnlyFiresCallback() async {
        let client = MockBrowserStoreClient()
        let item = makeItem(id: "1", text: "selected text")
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "selected text")],
            firstItem: item,
            totalCount: 1
        ))

        var copiedId: String?
        var copiedContent: ClipboardContent?
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { id, content in
                copiedId = id
                copiedContent = content
            },
            onDismiss: {}
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        viewModel.copyOnlySelection()

        XCTAssertEqual(copiedId, "1")
        guard case let .text(value)? = copiedContent else {
            return XCTFail("Expected text content in onCopyOnly callback")
        }
        XCTAssertEqual(value, "selected text")
    }

    func testConsecutiveDeleteAccumulatesBatch() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
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
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await flushMainActor()

        viewModel.deleteSelectedItem()
        await flushMainActor()

        viewModel.select(itemId: "2", origin: .click)
        viewModel.deleteSelectedItem()
        await flushMainActor()

        // Both items should be deleted and accumulated in one pending batch
        XCTAssertEqual(viewModel.itemIds, [])

        guard case let .deleting(.pending(transaction)) = viewModel.mutationState else {
            return XCTFail("Expected batch delete to be pending")
        }
        XCTAssertEqual(transaction.deletedItemIds, ["1", "2"])
    }

    func testDismissMutationFailureClearsState() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
            totalCount: 2
        ))
        client.deleteResult = .failure(.databaseOperationFailed(
            operation: "deleteItem",
            underlying: NSError(domain: "ClipKitty", code: 4)
        ))

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {},
            deleteCommitDelay: 0.05
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await flushMainActor()

        viewModel.deleteSelectedItem()
        try? await Task.sleep(for: .milliseconds(300))
        await flushMainActor()

        XCTAssertNotNil(viewModel.mutationFailureMessage)

        viewModel.dismissMutationFailure()

        XCTAssertNil(viewModel.mutationFailureMessage)
        guard case .idle = viewModel.mutationState else {
            return XCTFail("Expected idle mutation after dismissing failure")
        }
    }

    // MARK: - Typed Filter Suggestions

    private func makeTypedFilterViewModel(
        client: MockBrowserStoreClient,
        includesFileItems: Bool = false,
        pendingFilterSurfaceDelay: TimeInterval = 0.01
    ) -> BrowserViewModel {
        BrowserViewModel(
            client: client,
            filterCatalog: BrowserFilterCatalog(includesFileItems: includesFileItems),
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {},
            pendingFilterSurfaceDelay: pendingFilterSurfaceDelay
        )
    }

    /// Waits out the (test-shortened) typing-pause delay before the chip
    /// surfaces.
    private func awaitPendingFilterSurface() async {
        try? await Task.sleep(for: .milliseconds(60))
        await flushMainActor()
    }

    func testTypingCategoryPrefixSurfacesChipWithResultsKeyboardTarget() async {
        let viewModel = makeTypedFilterViewModel(client: MockBrowserStoreClient())
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        viewModel.updateSearchText("image")
        await awaitPendingFilterSurface()

        guard case let .suggested(suggestion, keyboardTarget: .results) = viewModel.pendingFilterState else {
            return XCTFail("Expected results-targeted suggestion, got \(viewModel.pendingFilterState)")
        }
        XCTAssertEqual(suggestion.kind, .images)
        XCTAssertEqual(viewModel.keyboardTarget, .results)
    }

    func testChipSurfacesAsKeyboardTargetOverLoadedEmptyResults() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [],
            firstPreviewPayload: nil,
            totalCount: 0
        ))
        // The surface delay outlasts the search, so the empty result is
        // LOADED by the time the suggestion surfaces.
        let viewModel = makeTypedFilterViewModel(client: client, pendingFilterSurfaceDelay: 0.2)
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "links", filter: .all),
            items: [],
            firstPreviewPayload: nil,
            totalCount: 0
        ))
        viewModel.updateSearchText("links")
        try? await Task.sleep(for: .milliseconds(350))
        await flushMainActor()

        // With nothing to select, the chip is granted the keyboard, so a
        // plain Return applies the filter without an Up first.
        guard case .pendingFilterChip = viewModel.keyboardTarget else {
            return XCTFail("Expected chip to own the keyboard over empty results, got \(viewModel.keyboardTarget)")
        }
        XCTAssertFalse(viewModel.hasUserNavigated, "An automatic grant is not user navigation, so no accent")
        viewModel.confirmSelection()
        XCTAssertEqual(
            viewModel.contentState.request,
            SearchRequest(text: "", filter: .contentType(contentType: .links))
        )
    }

    func testEmptyResultsArrivingAfterSurfacePromoteChipToKeyboardTarget() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one")],
            firstPreviewPayload: nil,
            totalCount: 1
        ))
        let viewModel = makeTypedFilterViewModel(client: client)
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await flushMainActor()

        // The suggestion surfaces before the search resolves (the previous
        // non-empty list is still displayed), so the results keep the
        // keyboard at first.
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "links", filter: .all),
            items: [],
            firstPreviewPayload: nil,
            totalCount: 0
        ))
        viewModel.updateSearchText("links")
        try? await Task.sleep(for: .milliseconds(120))
        await flushMainActor()

        // Once the load comes up empty, the chip is promoted to the target.
        guard case .pendingFilterChip = viewModel.keyboardTarget else {
            return XCTFail("Expected chip to be promoted over empty results, got \(viewModel.keyboardTarget)")
        }
        XCTAssertNil(viewModel.selectedItemId)
    }

    func testPendingChipWaitsForTypingPause() async {
        let viewModel = makeTypedFilterViewModel(
            client: MockBrowserStoreClient(),
            pendingFilterSurfaceDelay: 0.2
        )
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        viewModel.updateSearchText("image")
        XCTAssertEqual(
            viewModel.pendingFilterState, .none,
            "The chip must not surface until the user pauses typing"
        )

        try? await Task.sleep(for: .milliseconds(350))
        await flushMainActor()
        XCTAssertEqual(viewModel.pendingFilterSuggestion?.kind, .images)
    }

    func testArrowKeysMoveBetweenChipAndResults() async {
        let client = MockBrowserStoreClient()
        // Resolve the initial empty search so no stale operation is parked on
        // the mock's response queue when the typed search begins.
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [],
            firstPreviewPayload: nil,
            totalCount: 0
        ))
        let viewModel = makeTypedFilterViewModel(client: client)
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "image", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
            totalCount: 2
        ))
        viewModel.updateSearchText("image")
        try? await Task.sleep(for: .milliseconds(120))
        await flushMainActor()
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await awaitPendingFilterSurface()

        // The chip surfaces with the results still owning the keyboard.
        XCTAssertEqual(viewModel.keyboardTarget, .results)
        XCTAssertEqual(viewModel.selectedIndex, 0)

        // Up from the first row hands the keyboard to the chip without
        // disturbing the selection.
        viewModel.moveSelection(by: -1)
        guard case .pendingFilterChip = viewModel.keyboardTarget else {
            return XCTFail("Expected chip to own the keyboard after Up, got \(viewModel.keyboardTarget)")
        }
        XCTAssertEqual(viewModel.selectedIndex, 0, "Moving to the chip must not disturb the selection")
        XCTAssertNotNil(viewModel.pendingFilterSuggestion, "Suggestion stays visible at the chip")
        XCTAssertTrue(viewModel.hasUserNavigated, "Up onto the chip is user navigation, which earns the accent")

        // Down: keyboard returns to the results without skipping the first row.
        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.keyboardTarget, .results)
        XCTAssertEqual(viewModel.selectedIndex, 0)

        // Down again: normal row navigation.
        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedIndex, 1)
    }

    func testQueryUpdateWhileChipTargetedReturnsKeyboardToResults() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [],
            firstPreviewPayload: nil,
            totalCount: 0
        ))
        let viewModel = makeTypedFilterViewModel(client: client)
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "image", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
            totalCount: 2
        ))
        viewModel.updateSearchText("image")
        try? await Task.sleep(for: .milliseconds(120))
        await flushMainActor()
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await awaitPendingFilterSurface()

        viewModel.moveSelection(by: -1)
        guard case .pendingFilterChip = viewModel.keyboardTarget else {
            return XCTFail("Expected chip to own the keyboard after Up, got \(viewModel.keyboardTarget)")
        }

        // Typing again hands the keyboard back to the first real result; the
        // chip stays visible but Enter must not apply the filter anymore.
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "images", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
            totalCount: 2
        ))
        viewModel.updateSearchText("images")
        try? await Task.sleep(for: .milliseconds(120))
        await awaitPendingFilterSurface()

        XCTAssertEqual(viewModel.keyboardTarget, .results)
        XCTAssertEqual(viewModel.pendingFilterSuggestion?.kind, .images, "The chip stays visible across the update")
        XCTAssertEqual(viewModel.selectedIndex, 0)
    }

    func testUpWalksRowsBeforeReachingChipFromPreservedSelection() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
            totalCount: 2
        ))
        let viewModel = makeTypedFilterViewModel(client: client)
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await flushMainActor()

        // Park the selection on the SECOND row before typing the trigger.
        viewModel.moveSelection(by: 1)
        await flushMainActor()
        client.resumeFetch(id: "2", with: makeItem(id: "2", text: "second"))
        await flushMainActor()
        XCTAssertEqual(viewModel.selectedIndex, 1)

        // Same items survive the query transition, so the row-2 selection is
        // intentionally preserved underneath the suggestion.
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "image", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
            totalCount: 2
        ))
        viewModel.updateSearchText("image")
        try? await Task.sleep(for: .milliseconds(120))
        await awaitPendingFilterSurface()
        XCTAssertEqual(viewModel.keyboardTarget, .results)

        // Up from the second row is normal row navigation; only Up from the
        // FIRST row reaches the chip.
        viewModel.moveSelection(by: -1)
        XCTAssertEqual(viewModel.keyboardTarget, .results)
        XCTAssertEqual(viewModel.selectedIndex, 0)

        viewModel.moveSelection(by: -1)
        guard case .pendingFilterChip = viewModel.keyboardTarget else {
            return XCTFail("Expected chip to own the keyboard, got \(viewModel.keyboardTarget)")
        }

        // Up at the chip stays put; the chip is the top of the keyboard path.
        viewModel.moveSelection(by: -1)
        guard case .pendingFilterChip = viewModel.keyboardTarget else {
            return XCTFail("Expected chip to keep the keyboard on repeated Up, got \(viewModel.keyboardTarget)")
        }
        XCTAssertEqual(viewModel.selectedIndex, 0)
    }

    func testUserRowSelectionWhileChipTargetedReturnsKeyboardToResults() async {
        let client = MockBrowserStoreClient()
        var selectedItemIds: [String] = []
        let viewModel = BrowserViewModel(
            client: client,
            filterCatalog: BrowserFilterCatalog(includesFileItems: false),
            onSelect: { itemId, _ in selectedItemIds.append(itemId) },
            onCopyOnly: { _, _ in },
            onDismiss: {},
            pendingFilterSurfaceDelay: 0.01
        )
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [],
            firstPreviewPayload: nil,
            totalCount: 0
        ))
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "image", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
            totalCount: 2
        ))
        viewModel.updateSearchText("image")
        try? await Task.sleep(for: .milliseconds(120))
        await flushMainActor()
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await awaitPendingFilterSurface()

        viewModel.moveSelection(by: -1)
        guard case .pendingFilterChip = viewModel.keyboardTarget else {
            return XCTFail("Expected chip to own the keyboard, got \(viewModel.keyboardTarget)")
        }

        // A direct row pick (Cmd+number, click) while the chip is targeted
        // hands the keyboard back, so the confirm activates the row.
        viewModel.select(itemId: "2", origin: .keyboard)
        await flushMainActor()
        client.resumeFetch(id: "2", with: makeItem(id: "2", text: "second"))
        await flushMainActor()

        XCTAssertEqual(viewModel.keyboardTarget, .results)
        viewModel.confirmSelection()
        XCTAssertEqual(selectedItemIds, ["2"])
        XCTAssertEqual(viewModel.contentState.request.filter, .all, "The row pick must not apply the filter")
    }

    func testSuspensionResetsChipKeyboardTargetToResults() async {
        let viewModel = makeTypedFilterViewModel(client: MockBrowserStoreClient())
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        viewModel.updateSearchText("image")
        await awaitPendingFilterSurface()
        viewModel.moveSelection(by: -1)
        guard case .pendingFilterChip = viewModel.keyboardTarget else {
            return XCTFail("Expected chip to own the keyboard, got \(viewModel.keyboardTarget)")
        }

        viewModel.prepareForSuspension()

        XCTAssertEqual(viewModel.keyboardTarget, .results, "A hide/show cycle must not resurrect the chip target")
        XCTAssertEqual(viewModel.pendingFilterSuggestion?.kind, .images, "The suggestion itself stays valid")
    }

    func testEnterOnChipAppliesFilterAndConsumesOnlyTriggerToken() async {
        let viewModel = makeTypedFilterViewModel(client: MockBrowserStoreClient())
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        viewModel.updateSearchText("docker image")
        await awaitPendingFilterSurface()
        XCTAssertEqual(viewModel.keyboardTarget, .results)

        // The chip is opt-in: Up addresses it, then Enter applies the filter.
        viewModel.moveSelection(by: -1)
        guard case .pendingFilterChip = viewModel.keyboardTarget else {
            return XCTFail("Expected chip to own the keyboard after Up, got \(viewModel.keyboardTarget)")
        }
        viewModel.confirmSelection()

        XCTAssertEqual(
            viewModel.contentState.request,
            SearchRequest(text: "docker", filter: .contentType(contentType: .images))
        )
        XCTAssertEqual(viewModel.pendingFilterState, .none)
        XCTAssertEqual(viewModel.appliedFilterDescriptor?.kind, .images)
        XCTAssertEqual(viewModel.activeFilterKind, .images)
    }

    func testEnterWhileResultsTargetedConfirmsItemNotFilter() async {
        let client = MockBrowserStoreClient()
        var selectedItemIds: [String] = []
        let viewModel = BrowserViewModel(
            client: client,
            filterCatalog: BrowserFilterCatalog(includesFileItems: false),
            onSelect: { itemId, _ in selectedItemIds.append(itemId) },
            onCopyOnly: { _, _ in },
            onDismiss: {},
            pendingFilterSurfaceDelay: 0.01
        )
        // Resolve the initial empty search so no stale operation is parked on
        // the mock's response queue when the typed search begins.
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [],
            firstPreviewPayload: nil,
            totalCount: 0
        ))
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "image", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one")],
            firstPreviewPayload: nil,
            totalCount: 1
        ))
        viewModel.updateSearchText("image")
        try? await Task.sleep(for: .milliseconds(120))
        await flushMainActor()
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await awaitPendingFilterSurface()

        // The results own the keyboard by default, so plain Enter activates
        // the selected row even though the suggestion is visible.
        XCTAssertEqual(viewModel.keyboardTarget, .results)
        XCTAssertNotNil(viewModel.pendingFilterSuggestion)

        viewModel.confirmSelection()

        XCTAssertEqual(selectedItemIds, ["1"])
        XCTAssertEqual(viewModel.contentState.request.filter, .all, "Enter on a row must not apply the filter")
    }

    func testClearAppliedFilterKeepsSearchText() async {
        let viewModel = makeTypedFilterViewModel(client: MockBrowserStoreClient())
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        viewModel.updateSearchText("docker image")
        await awaitPendingFilterSurface()
        viewModel.applyPendingFilterSuggestion()
        XCTAssertEqual(
            viewModel.contentState.request,
            SearchRequest(text: "docker", filter: .contentType(contentType: .images))
        )

        viewModel.clearAppliedFilter()

        XCTAssertEqual(viewModel.contentState.request, SearchRequest(text: "docker", filter: .all))
        XCTAssertNil(viewModel.appliedFilterDescriptor)
    }

    func testBookmarkTypedFilterMapsToBookmarkTag() async {
        let viewModel = makeTypedFilterViewModel(client: MockBrowserStoreClient())
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        viewModel.updateSearchText("book")
        await awaitPendingFilterSurface()
        XCTAssertEqual(viewModel.pendingFilterSuggestion?.kind, .bookmarks)

        viewModel.moveSelection(by: -1)
        viewModel.confirmSelection()

        XCTAssertEqual(
            viewModel.contentState.request,
            SearchRequest(text: "", filter: .tagged(tag: .bookmark))
        )
    }

    func testAppliedFilterIsNotResuggested() async {
        let viewModel = makeTypedFilterViewModel(client: MockBrowserStoreClient())
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        viewModel.updateSearchText("image")
        await awaitPendingFilterSurface()
        viewModel.applyPendingFilterSuggestion()

        viewModel.updateSearchText("image")
        await awaitPendingFilterSurface()
        XCTAssertEqual(
            viewModel.pendingFilterState, .none,
            "Typing the active filter's alias must not re-suggest it"
        )
    }

    func testFilesTypedFilterRequiresPlatformAvailability() async {
        let unavailable = makeTypedFilterViewModel(client: MockBrowserStoreClient(), includesFileItems: false)
        unavailable.onAppear(initialSearchQuery: "")
        await flushMainActor()
        unavailable.updateSearchText("files")
        await awaitPendingFilterSurface()
        XCTAssertEqual(unavailable.pendingFilterState, .none)

        let available = makeTypedFilterViewModel(client: MockBrowserStoreClient(), includesFileItems: true)
        available.onAppear(initialSearchQuery: "")
        await flushMainActor()
        available.updateSearchText("files")
        await awaitPendingFilterSurface()
        XCTAssertEqual(available.pendingFilterSuggestion?.kind, .files)
    }

    private func flushMainActor() async {
        for _ in 0 ..< 5 {
            await Task.yield()
        }
    }

    /// Polls the main actor until `condition` holds or the deadline passes.
    /// Fixed-count yield flushing loses the race when the test host's main
    /// actor is contended (e.g. SyncEngine startup work), so asserts that
    /// depend on async state wait on that state itself.
    @discardableResult
    private func settle(
        timeout: TimeInterval = 2,
        until condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    private func makeMatch(id: String, excerpt: String, tags: [ItemTag] = []) -> ItemMatch {
        ItemMatch(
            itemMetadata: ItemMetadata(
                itemId: id,
                icon: .symbol(iconType: .text),
                sourceApp: nil,
                sourceAppBundleId: nil,
                timestampUnix: 0,
                tags: tags
            ),
            presentation: .baseline(excerpt: BaselineExcerpt(text: excerpt))
        )
    }

    private func makeDeferredMatch(id: String, text: String, query: String, tags: [ItemTag] = []) -> ItemMatch {
        ItemMatch(
            itemMetadata: ItemMetadata(
                itemId: id,
                icon: .symbol(iconType: .text),
                sourceApp: nil,
                sourceAppBundleId: nil,
                timestampUnix: 0,
                tags: tags
            ),
            presentation: .deferred(
                request: MatchedExcerptRequest(
                    itemId: id,
                    query: query,
                    presentationProfile: .compactRow,
                    contentHash: "hash-\(id)-\(query)"
                ),
                placeholder: .baseline(excerpt: BaselineExcerpt(text: text))
            )
        )
    }

    private func makeItem(id: String, text: String, tags: [ItemTag] = []) -> ClipboardItem {
        ClipboardItem(
            itemMetadata: ItemMetadata(
                itemId: id,
                icon: .symbol(iconType: .text),
                sourceApp: nil,
                sourceAppBundleId: nil,
                timestampUnix: 0,
                tags: tags
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

    private func makePreviewPayload(
        item: ClipboardItem,
        decoration: PreviewDecoration? = nil
    ) -> PreviewPayload {
        PreviewPayload(item: item, decoration: decoration)
    }
}

private extension BrowserSearchResponse {
    init(
        request: SearchRequest,
        items: [ItemMatch],
        firstItem: ClipboardItem?,
        totalCount: Int
    ) {
        self.init(
            request: request,
            items: items,
            firstPreviewPayload: firstItem.map { PreviewPayload(item: $0, decoration: nil) },
            totalCount: totalCount
        )
    }
}

@MainActor
private final class MockBrowserStoreClient: BrowserStoreClient {
    struct MatchedExcerptRequestKey: Hashable {
        let itemIds: [String]
        let query: String
    }

    struct PreviewDecorationRequest: Hashable {
        let itemId: String
        let query: String
    }

    let listPresentationProfile: ListPresentationProfile = .compactRow

    private var pendingSearchResponses: [BrowserSearchResponse] = []
    private var searchContinuations: [CheckedContinuation<BrowserSearchOutcome, Never>] = []
    var addTagResult: Result<Void, ClipboardError> = .success(())
    var removeTagResult: Result<Void, ClipboardError> = .success(())
    var deleteResult: Result<Void, ClipboardError> = .success(())
    var deletedItemIds: [String] = []
    var clearResult: Result<Void, ClipboardError> = .success(())
    var updateTextResult: Result<Void, ClipboardError> = .success(())
    var updatedTexts: [(itemId: String, text: String)] = []
    var startedSearchRequests: [SearchRequest] = []
    var resolveMatchedExcerptRequests: [MatchedExcerptRequestKey] = []
    var loadPreviewDecorationRequests: [PreviewDecorationRequest] = []
    var matchedExcerptsByQuery: [String: [String: MatchedExcerpt]] = [:]
    var previewPayloadsByQuery: [String: [String: PreviewPayload]] = [:]
    private var fetchContinuations: [String: [CheckedContinuation<ClipboardItem?, Never>]] = [:]
    private var matchedExcerptContinuations: [MatchedExcerptRequestKey: [CheckedContinuation<[MatchedExcerptResolution], Never>]] = [:]
    private var previewPayloadContinuations: [PreviewDecorationRequest: [CheckedContinuation<PreviewPayload?, Never>]] = [:]
    // Results resumed before the view model parked the matching request.
    // Every resume either resolves a parked continuation or queues here — a
    // resume must never be silently dropped just because the test won the
    // race to the mock (the search path already queues; these mirror it).
    private var queuedFetchResults: [String: ClipboardItem?] = [:]
    private var queuedMatchedExcerpts: [MatchedExcerptRequestKey: [MatchedExcerptResolution]] = [:]
    private var queuedPreviewPayloads: [PreviewDecorationRequest: PreviewPayload?] = [:]

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

    func fetchItem(id: String) async -> ClipboardItem? {
        if let queued = queuedFetchResults.removeValue(forKey: id) {
            return queued
        }
        return await withTaskCancellationHandler {
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

    func resolveMatchedExcerpts(requests: [MatchedExcerptRequest]) async -> [MatchedExcerptResolution] {
        let itemIds = requests.map { $0.itemId }
        let query = requests.first?.query ?? ""
        let request = MatchedExcerptRequestKey(itemIds: itemIds, query: query)
        resolveMatchedExcerptRequests.append(request)

        if let excerptsByItemId = matchedExcerptsByQuery[query] {
            return itemIds.map { itemId in
                if let excerpt = excerptsByItemId[itemId] {
                    return .ready(itemId: itemId, excerpt: excerpt)
                }
                return .unavailable(itemId: itemId, reason: .itemMissing)
            }
        }

        if let queued = queuedMatchedExcerpts.removeValue(forKey: request) {
            return queued
        }

        return await withCheckedContinuation { continuation in
            matchedExcerptContinuations[request, default: []].append(continuation)
        }
    }

    func formatExcerpt(content: String) -> String {
        String(content.prefix(200))
    }

    func loadPreviewPayload(itemId: String, query: String) async -> PreviewPayload? {
        let request = PreviewDecorationRequest(itemId: itemId, query: query)
        loadPreviewDecorationRequests.append(request)

        if let payloadsByItemId = previewPayloadsByQuery[query] {
            return payloadsByItemId[itemId]
        }

        if let queued = queuedPreviewPayloads.removeValue(forKey: request) {
            return queued
        }

        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let item = await fetchItem(id: itemId)
        {
            return PreviewPayload(item: item, decoration: nil)
        }

        return await withCheckedContinuation { continuation in
            previewPayloadContinuations[request, default: []].append(continuation)
        }
    }

    func fetchLinkMetadata(url _: String, itemId _: String) async -> ClipboardItem? {
        nil
    }

    func addTag(itemId _: String, tag _: ItemTag) async -> Result<Void, ClipboardError> {
        addTagResult
    }

    func removeTag(itemId _: String, tag _: ItemTag) async -> Result<Void, ClipboardError> {
        removeTagResult
    }

    func delete(itemId: String) async -> Result<Void, ClipboardError> {
        deletedItemIds.append(itemId)
        return deleteResult
    }

    func clear() async -> Result<Void, ClipboardError> {
        clearResult
    }

    func updateTextItem(itemId: String, text: String) async -> Result<Void, ClipboardError> {
        updatedTexts.append((itemId: itemId, text: text))
        return updateTextResult
    }

    func resumeFetch(id: String, with item: ClipboardItem?) {
        if let continuations = fetchContinuations.removeValue(forKey: id) {
            continuations.forEach { $0.resume(returning: item) }
        } else {
            queuedFetchResults[id] = item
        }
    }

    func resumeMatchedExcerpts(itemIds: [String], query: String, with results: [MatchedExcerptResolution]) {
        let request = MatchedExcerptRequestKey(itemIds: itemIds, query: query)
        if let continuations = matchedExcerptContinuations.removeValue(forKey: request) {
            continuations.forEach { $0.resume(returning: results) }
        } else {
            queuedMatchedExcerpts[request] = results
        }
    }

    func resumePreviewPayload(itemId: String, query: String, with payload: PreviewPayload?) {
        let request = PreviewDecorationRequest(itemId: itemId, query: query)
        if let continuations = previewPayloadContinuations.removeValue(forKey: request) {
            continuations.forEach { $0.resume(returning: payload) }
        } else {
            queuedPreviewPayloads[request] = payload
        }
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
