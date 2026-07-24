@testable import ClipKitty
@testable import ClipKittyBrowser
import ClipKittyCore
import ClipKittyRust
import XCTest

@MainActor
final class BrowserEditingTests: XCTestCase {
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

        viewModel.onTextEdit(
            "edited text",
            for: "1",
            originalContent: .text(value: "original text")
        )
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

        viewModel.onTextEdit(
            "edited text",
            for: "1",
            originalContent: .text(value: "original text")
        )
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

        viewModel.onTextEdit(
            "edited",
            for: "1",
            originalContent: .text(value: "original")
        )
        XCTAssertEqual(viewModel.editSession, .dirty(itemId: "1", draft: "edited"))

        viewModel.onTextEdit(
            "original",
            for: "1",
            originalContent: .text(value: "original")
        )

        XCTAssertEqual(viewModel.editSession, .focused(itemId: "1"))
    }

    func testNonTextContentCannotCreateAnEditSession() {
        let viewModel = BrowserViewModel(
            client: MockBrowserStoreClient(),
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.onTextEdit(
            "not a color",
            for: "color",
            originalContent: .color(value: "#ff0000")
        )

        XCTAssertEqual(viewModel.editSession, .inactive)
    }

    func testDraftDoesNotChangeNonTextEffectiveContent() {
        let viewModel = BrowserViewModel(
            client: MockBrowserStoreClient(),
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )
        viewModel.onTextEdit(
            "draft",
            for: "1",
            originalContent: .text(value: "persisted")
        )
        let colorItem = ClipboardItem(
            itemMetadata: makeItem(id: "1", text: "persisted").itemMetadata,
            content: .color(value: "#ff0000")
        )

        XCTAssertEqual(viewModel.effectiveContent(for: colorItem), colorItem.content)
    }

    func testDeletingAnotherItemPreservesDirtyDraft() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "first"), makeMatch(id: "2", excerpt: "second")],
            firstItem: makeItem(id: "1", text: "original"),
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
        viewModel.onTextEdit(
            "edited",
            for: "1",
            originalContent: .text(value: "original")
        )

        viewModel.deleteItem(itemId: "2")

        XCTAssertEqual(viewModel.editSession, .dirty(itemId: "1", draft: "edited"))
        viewModel.undoPendingDelete()
    }

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
        viewModel.onTextEdit(
            "hello world",
            for: "1",
            originalContent: .text(value: "hello")
        )

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
        viewModel.onTextEdit(
            "first edited",
            for: "1",
            originalContent: .text(value: "first")
        )

        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedItemId, "2")
        XCTAssertEqual(viewModel.editSession, .suspendedDirty(itemId: "1", draft: "first edited"))

        // Focusing or typing into another preview cannot silently replace the
        // one pending draft. The UI renders this second preview read-only.
        viewModel.onEditingStateChange(true, for: "2")
        viewModel.onTextEdit(
            "second edited",
            for: "2",
            originalContent: .text(value: "second")
        )
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
        viewModel.onTextEdit(
            "first edited",
            for: "1",
            originalContent: .text(value: "first")
        )

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
        viewModel.onTextEdit(
            "hello world",
            for: "1",
            originalContent: .text(value: "hello")
        )
        XCTAssertEqual(viewModel.editSession, .dirty(itemId: "1", draft: "hello world"))

        viewModel.discardCurrentEdit()

        XCTAssertEqual(viewModel.editSession, .inactive)
    }
}
