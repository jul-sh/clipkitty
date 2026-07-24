@testable import ClipKitty
@testable import ClipKittyBrowser
import ClipKittyCore
import ClipKittyRust
import XCTest

@MainActor
final class BrowserTypedFilterTests: XCTestCase {
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

    private func awaitPendingFilterSurface() async {
        try? await Task.sleep(for: .milliseconds(60))
        await flushMainActor()
    }
}
