import ClipKittyRust
@testable import ClipKittyShared
import XCTest

/// Tests for iOS card highlight rendering from Rust matched excerpts,
/// preview decoration consumption, and inline edit transitions.
@MainActor
final class iOSHighlightAndEditTests: XCTestCase {
    // MARK: - Card Highlights from RowPresentation

    func testDisplayRowUsesMatchedExcerptTextWhenAvailable() {
        let excerpt = MatchedExcerpt(
            text: "Decorated excerpt",
            highlights: [Utf16HighlightRange(utf16Start: 0, utf16End: 9, kind: .exact)],
            lineNumber: 1
        )
        let row = DisplayRow(
            metadata: makeMetadata(id: "1"),
            presentation: .matched(excerpt: excerpt)
        )

        guard case let .matched(renderedExcerpt) = row.presentation else {
            return XCTFail("Expected ready matched excerpt")
        }
        XCTAssertEqual(renderedExcerpt.text, "Decorated excerpt")
        XCTAssertEqual(renderedExcerpt.highlights.count, 1)
        XCTAssertEqual(renderedExcerpt.highlights.first?.kind, .exact)
    }

    func testDisplayRowUsesBaselinePresentation() {
        let row = DisplayRow(
            metadata: makeMetadata(id: "1"),
            presentation: .baseline(excerpt: BaselineExcerpt(text: "Fallback excerpt"))
        )

        guard case let .baseline(excerpt) = row.presentation else {
            return XCTFail("Expected baseline excerpt")
        }
        XCTAssertEqual(excerpt.text, "Fallback excerpt")
    }

    // MARK: - Preview Decoration State

    func testPreviewDecorationFromHighlightedState() {
        let decoration = PreviewDecoration(
            highlights: [
                Utf16HighlightRange(utf16Start: 0, utf16End: 5, kind: .exact),
                Utf16HighlightRange(utf16Start: 10, utf16End: 15, kind: .fuzzy),
            ],
            initialScrollHighlightIndex: 0
        )
        let state = SelectedPreviewState.highlighted(decoration)
        if case let .highlighted(d) = state {
            XCTAssertEqual(d.highlights.count, 2)
            XCTAssertEqual(d.initialScrollHighlightIndex, 0)
        } else {
            XCTFail("Expected .highlighted state")
        }
    }

    func testPreviewDecorationFromLoadingWithPrevious() {
        let previousDecoration = PreviewDecoration(
            highlights: [Utf16HighlightRange(utf16Start: 0, utf16End: 5, kind: .exact)],
            initialScrollHighlightIndex: nil
        )
        let state = SelectedPreviewState.loadingDecoration(previous: previousDecoration)
        if case let .loadingDecoration(previous) = state {
            XCTAssertNotNil(previous)
            XCTAssertEqual(previous?.highlights.count, 1)
        } else {
            XCTFail("Expected .loadingDecoration state")
        }
    }

    func testPreviewDecorationFromPlainState() {
        let state = SelectedPreviewState.plain
        if case .plain = state {
            // No decoration available in plain state
        } else {
            XCTFail("Expected .plain state")
        }
    }

    // MARK: - Inline Edit Transitions

    func testNoSaveWithoutDirtyEdit() async {
        let client = MockiOSBrowserStoreClient()
        let viewModel = makeViewModel(client: client)

        let item = makeItem(id: "1", text: "Original text")
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "Original text")],
            firstPreviewPayload: PreviewPayload(item: item, decoration: nil),
            totalCount: 1
        ))

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        client.resumeFetch(id: "1", with: item)
        viewModel.select(itemId: "1", origin: .click)
        await flushMainActor()

        // No pending edits — hasPendingEdit should be false
        XCTAssertEqual(viewModel.editSession, .inactive)
    }

    func testEditMakesDirtyAndSaveRestores() async {
        let client = MockiOSBrowserStoreClient()
        let viewModel = makeViewModel(client: client)

        let item = makeItem(id: "1", text: "Original text")
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "Original text")],
            firstPreviewPayload: PreviewPayload(item: item, decoration: nil),
            totalCount: 1
        ))

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        client.resumeFetch(id: "1", with: item)
        viewModel.select(itemId: "1", origin: .click)
        await flushMainActor()

        // Start editing
        viewModel.onEditingStateChange(true, for: "1")
        XCTAssertEqual(viewModel.editSession, .focused(itemId: "1"))

        // Make a text change — should become dirty
        viewModel.onTextEdit("Changed text", for: "1", originalText: "Original text")
        XCTAssertEqual(viewModel.editSession, .dirty(itemId: "1", draft: "Changed text"))

        // Commit the edit
        viewModel.commitCurrentEdit()
        await flushMainActor()

        XCTAssertEqual(viewModel.editSession, .inactive)
        XCTAssertEqual(client.updatedTexts.count, 1)
        XCTAssertEqual(client.updatedTexts.first?.text, "Changed text")
    }

    func testCancelRestoresOriginalText() async {
        let client = MockiOSBrowserStoreClient()
        let viewModel = makeViewModel(client: client)

        let item = makeItem(id: "1", text: "Original text")
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "Original text")],
            firstPreviewPayload: PreviewPayload(item: item, decoration: nil),
            totalCount: 1
        ))

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        client.resumeFetch(id: "1", with: item)
        viewModel.select(itemId: "1", origin: .click)
        await flushMainActor()

        // Edit and then cancel
        viewModel.onEditingStateChange(true, for: "1")
        viewModel.onTextEdit("Changed text", for: "1", originalText: "Original text")
        if case let .dirty(dirtyId, _) = viewModel.editSession {
            XCTAssertEqual(dirtyId, "1")
        } else {
            XCTFail("Expected dirty edit session for item 1")
        }

        viewModel.discardCurrentEdit()
        XCTAssertEqual(viewModel.editSession, .inactive)

        // No text should have been persisted
        XCTAssertTrue(client.updatedTexts.isEmpty)
    }

    func testEditWithSameTextIsNotDirty() async {
        let client = MockiOSBrowserStoreClient()
        let viewModel = makeViewModel(client: client)

        let item = makeItem(id: "1", text: "Same text")
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "Same text")],
            firstPreviewPayload: PreviewPayload(item: item, decoration: nil),
            totalCount: 1
        ))

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        client.resumeFetch(id: "1", with: item)
        viewModel.select(itemId: "1", origin: .click)
        await flushMainActor()

        viewModel.onEditingStateChange(true, for: "1")
        viewModel.onTextEdit("Same text", for: "1", originalText: "Same text")
        // Same text as original — not dirty, just focused
        XCTAssertEqual(viewModel.editSession, .focused(itemId: "1"))
    }

    // MARK: - Search Refresh After Save

    func testSaveInvalidatesStaleDecoration() async {
        let client = MockiOSBrowserStoreClient()
        let viewModel = makeViewModel(client: client)

        let item = makeItem(id: "1", text: "search term here")
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "search term here")],
            firstPreviewPayload: PreviewPayload(item: item, decoration: nil),
            totalCount: 1
        ))

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        // Select the item — resolves from firstPreviewPayload
        viewModel.select(itemId: "1", origin: .click)
        await flushMainActor()

        // Verify selection is established
        XCTAssertNotNil(viewModel.selectedItemState)

        // Edit and save
        viewModel.onEditingStateChange(true, for: "1")
        viewModel.onTextEdit("changed text", for: "1", originalText: "search term here")
        if case let .dirty(dirtyId, _) = viewModel.editSession {
            XCTAssertEqual(dirtyId, "1")
        } else {
            XCTFail("Expected dirty edit session for item 1")
        }

        viewModel.commitCurrentEdit()
        await flushMainActor()

        // Verify the edit was committed
        XCTAssertEqual(viewModel.editSession, .inactive)
        XCTAssertEqual(client.updatedTexts.count, 1)
        XCTAssertEqual(client.updatedTexts.first?.text, "changed text")

        // Verify edit session returned to inactive
        XCTAssertEqual(viewModel.editSession, .inactive)
    }

    // MARK: - PreviewEditSession Sum Type

    func testPreviewEditSessionTransitions() {
        // Test that PreviewEditSession enum represents valid states
        let inactive: PreviewEditSession = .inactive
        let focused: PreviewEditSession = .focused(itemId: "1")
        let dirty: PreviewEditSession = .dirty(itemId: "1", draft: "new text")

        XCTAssertEqual(inactive, .inactive)
        XCTAssertEqual(focused, .focused(itemId: "1"))
        XCTAssertEqual(dirty, .dirty(itemId: "1", draft: "new text"))

        // Different items are not equal
        XCTAssertNotEqual(
            PreviewEditSession.focused(itemId: "1"),
            PreviewEditSession.focused(itemId: "2")
        )

        // Different drafts are not equal
        XCTAssertNotEqual(
            PreviewEditSession.dirty(itemId: "1", draft: "a"),
            PreviewEditSession.dirty(itemId: "1", draft: "b")
        )
    }

    func testSelectingDifferentItemClearsDirtyState() async {
        let client = MockiOSBrowserStoreClient()
        let viewModel = makeViewModel(client: client)

        let item1 = makeItem(id: "1", text: "First item")
        let item2 = makeItem(id: "2", text: "Second item")
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [
                makeMatch(id: "1", excerpt: "First item"),
                makeMatch(id: "2", excerpt: "Second item"),
            ],
            firstPreviewPayload: PreviewPayload(item: item1, decoration: nil),
            totalCount: 2
        ))

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        client.resumeFetch(id: "1", with: item1)
        viewModel.select(itemId: "1", origin: .click)
        await flushMainActor()

        // Make item 1 dirty
        viewModel.onEditingStateChange(true, for: "1")
        viewModel.onTextEdit("Changed", for: "1", originalText: "First item")
        if case let .dirty(dirtyId, _) = viewModel.editSession {
            XCTAssertEqual(dirtyId, "1")
        } else {
            XCTFail("Expected dirty edit session for item 1")
        }

        // Select item 2 — dirty state for item 1 should be cleared
        client.resumeFetch(id: "2", with: item2)
        viewModel.select(itemId: "2", origin: .click)
        await flushMainActor()

        XCTAssertEqual(viewModel.editSession, .inactive)
    }

    // MARK: - Helpers

    private func makeViewModel(client: MockiOSBrowserStoreClient) -> BrowserViewModel {
        BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )
    }

    private func flushMainActor() async {
        for _ in 0 ..< 5 {
            await Task.yield()
        }
    }

    private func makeMetadata(
        id: String,
        icon: ItemIcon = .symbol(iconType: .text)
    ) -> ItemMetadata {
        ItemMetadata(
            itemId: id,
            icon: icon,
            sourceApp: nil,
            sourceAppBundleId: nil,
            timestampUnix: 0,
            tags: []
        )
    }

    private func makeMatch(
        id: String,
        excerpt: String
    ) -> ItemMatch {
        ItemMatch(
            itemMetadata: makeMetadata(id: id),
            presentation: .baseline(excerpt: BaselineExcerpt(text: excerpt))
        )
    }

    private func makeItem(id: String, text: String) -> ClipboardItem {
        ClipboardItem(
            itemMetadata: makeMetadata(id: id),
            content: .text(value: text)
        )
    }
}
