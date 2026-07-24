@testable import ClipKitty
@testable import ClipKittyBrowser
import ClipKittyCore
import ClipKittyRust
import XCTest

@MainActor
final class BrowserPreviewBehaviorTests: XCTestCase {
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

    func testItemFetchSpinnerPhaseMovesFromWaitingToShowing() async {
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

        guard case let .loading(itemId, .automatic, .waitingForSpinner) = viewModel.selectionState else {
            return XCTFail("Expected item fetch to begin in the waiting phase")
        }
        XCTAssertEqual(itemId, "1")

        try? await Task.sleep(for: .milliseconds(300))

        guard case .loading("1", .automatic, .showingSpinner) = viewModel.selectionState else {
            return XCTFail("Expected item fetch to enter the showing phase after the delay")
        }

        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "one"))
        await flushMainActor()
        guard case let .selected(selectedItemState) = viewModel.selectionState,
              case .plain = selectedItemState.previewState
        else {
            return XCTFail("Expected completed item fetch to leave preview spinner phases")
        }
    }

    func testShowingItemFetchSpinnerCarriesIntoDecorationLoad() async {
        let client = MockBrowserStoreClient()
        let item = makeItem(id: "1", text: "alpha beta")
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.updateSearchText("a")
        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "a", filter: .all),
            items: [makeMatch(id: "1", excerpt: "alpha beta")],
            firstPreviewPayload: nil,
            totalCount: 1
        ))
        let fetchSettled = await settle {
            if case .loading("1", .automatic, .waitingForSpinner) = viewModel.selectionState {
                return true
            }
            return false
        }
        XCTAssertTrue(fetchSettled)

        try? await Task.sleep(for: .milliseconds(300))
        guard case .loading("1", .automatic, .showingSpinner) = viewModel.selectionState else {
            return XCTFail("Expected item fetch spinner to be showing before the item arrives")
        }

        client.resumeFetch(id: "1", with: item)
        await flushMainActor()

        guard case let .selected(selectedItemState) = viewModel.selectionState,
              case .loadingDecoration(
                  previous: nil,
                  phase: .showingSpinner
              ) = selectedItemState.previewState
        else {
            return XCTFail("Expected the showing phase to carry into decoration loading")
        }

        client.resumePreviewPayload(itemId: "1", query: "a", with: nil)
        await flushMainActor()
    }

    func testDecorationSpinnerPhaseMovesFromWaitingToShowing() async {
        let client = MockBrowserStoreClient()
        let item = makeItem(id: "1", text: "alpha beta")
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.updateSearchText("a")
        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "a", filter: .all),
            items: [makeMatch(id: "1", excerpt: "alpha beta")],
            firstItem: item,
            totalCount: 1
        ))
        let selectionSettled = await settle { viewModel.selectedItemState != nil }
        XCTAssertTrue(selectionSettled)

        guard case let .selected(waitingSelection) = viewModel.selectionState,
              case .loadingDecoration(previous: nil, phase: .waitingForSpinner) = waitingSelection.previewState
        else {
            return XCTFail("Expected decoration load to begin in the waiting phase")
        }

        try? await Task.sleep(for: .milliseconds(300))

        guard case let .selected(showingSelection) = viewModel.selectionState,
              case .loadingDecoration(previous: nil, phase: .showingSpinner) = showingSelection.previewState
        else {
            return XCTFail("Expected decoration load to enter the showing phase after the delay")
        }

        client.resumePreviewPayload(itemId: "1", query: "a", with: nil)
        await flushMainActor()
    }

    func testStalePreviewSpinnerTimerCannotPromoteNewerQueryState() async {
        let client = MockBrowserStoreClient()
        let item = makeItem(id: "1", text: "alpha beta")
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.updateSearchText("a")
        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "a", filter: .all),
            items: [makeMatch(id: "1", excerpt: "alpha beta")],
            firstItem: item,
            totalCount: 1
        ))
        let selectionSettled = await settle { viewModel.selectedItemState != nil }
        XCTAssertTrue(selectionSettled)

        viewModel.updateSearchText("al")
        await flushMainActor()
        guard case let .selected(waitingSelection) = viewModel.selectionState,
              case .loadingDecoration(previous: nil, phase: .waitingForSpinner) = waitingSelection.previewState
        else {
            return XCTFail("Expected the newer query to reset the preview delay")
        }

        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(viewModel.contentState.request.text, "al")
        guard case let .selected(stillWaitingSelection) = viewModel.selectionState,
              case .loadingDecoration(
                  previous: nil,
                  phase: .waitingForSpinner
              ) = stillWaitingSelection.previewState
        else {
            return XCTFail("A stale preview timer must not promote the newer query state")
        }

        client.resumePreviewPayload(itemId: "1", query: "a", with: nil)
        client.resumeSearch(with: BrowserSearchResponse(
            request: SearchRequest(text: "al", filter: .all),
            items: [],
            firstPreviewPayload: nil,
            totalCount: 0
        ))
        await flushMainActor()
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
        guard case let .loadingDecoration(
            previous: .some(staleDecoration),
            phase: .waitingForSpinner
        ) = selectedItemState.previewState else {
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
        guard case .loadingDecoration(previous: nil, phase: .waitingForSpinner) = selectedItemState.previewState else {
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
        guard case .loadingDecoration(previous: nil, phase: .waitingForSpinner) = staleSelection.previewState else {
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
        guard case .loadingDecoration(previous: nil, phase: .waitingForSpinner) = selectedItemState.previewState else {
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

    func testSelectedPreviewStateExtractsOnlyDisplayableDecoration() {
        let decoration = makePreviewDecoration(highlightStart: 1, highlightEnd: 4)

        XCTAssertNil(SelectedPreviewState.plain.decoration)
        XCTAssertNil(SelectedPreviewState.loadingDecoration(
            previous: nil,
            phase: .waitingForSpinner
        ).decoration)
        XCTAssertNil(SelectedPreviewState.loadingDecoration(
            previous: nil,
            phase: .showingSpinner
        ).decoration)
        XCTAssertEqual(SelectedPreviewState.loadingDecoration(
            previous: decoration,
            phase: .waitingForSpinner
        ).decoration, decoration)
        XCTAssertEqual(SelectedPreviewState.loadingDecoration(
            previous: decoration,
            phase: .showingSpinner
        ).decoration, decoration)
        XCTAssertEqual(SelectedPreviewState.highlighted(decoration).decoration, decoration)
    }

    func testDraftBearingEditStatesSuppressPersistedDecoration() {
        let decoration = makePreviewDecoration(highlightStart: 0, highlightEnd: 4)
        let selected = SelectedItemState(
            item: makeItem(id: "1", text: "persisted"),
            origin: .click,
            previewState: .highlighted(decoration)
        )

        XCTAssertNil(selected.displayDecoration(for: .dirty(itemId: "1", draft: "draft")))
        XCTAssertNil(selected.displayDecoration(for: .suspendedDirty(itemId: "1", draft: "draft")))
        XCTAssertEqual(
            selected.displayDecoration(for: .suspendedDirty(itemId: "2", draft: "other")),
            decoration
        )
    }

    func testPreviewDebugLabelUsesTheSharedStateContract() {
        let decoration = makePreviewDecoration(highlightStart: 6, highlightEnd: 11)

        XCTAssertEqual(
            PreviewDebugLabelFormatter.label(
                text: "hello world",
                itemId: "item-1",
                previewState: .highlighted(decoration)
            ),
            "item=item-1;state=highlighted;highlights=world"
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
