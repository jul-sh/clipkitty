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

    func testCommitEditShowsSavedNotificationAfterSearchRefresh() async {
        let client = MockBrowserStoreClient()
        var notification: NotificationRequest?
        let viewModel = await makeLoadedTextViewModel(
            client: client,
            onSelect: { _, _ in },
            showSnackbarNotification: { notification = $0 }
        )
        editText("edited text", in: viewModel)

        viewModel.commitCurrentEdit()
        guard case .saving = viewModel.mutationState else {
            return XCTFail("Expected persistence to be in flight")
        }
        viewModel.updateSearchText("")
        XCTAssertEqual(viewModel.editSession, .dirty(itemId: "1", draft: "edited text"))

        let didShowNotification = await settle { notification != nil }
        XCTAssertTrue(didShowNotification)
        guard case let .passive(message, iconSystemName)? = notification else {
            return XCTFail("Expected a passive saved notification")
        }
        XCTAssertEqual(message, String(localized: "Saved"))
        XCTAssertEqual(iconSystemName, "checkmark.circle.fill")
    }

    func testCommitEditFailureDoesNotShowSavedNotification() async {
        let client = MockBrowserStoreClient()
        client.updateTextResult = .failure(.databaseOperationFailed(
            operation: "update text",
            underlying: NSError(domain: "BrowserEditingTests", code: 1)
        ))
        var notification: NotificationRequest?
        let viewModel = await makeLoadedTextViewModel(
            client: client,
            onSelect: { _, _ in },
            showSnackbarNotification: { notification = $0 }
        )
        editText("edited text", in: viewModel)

        viewModel.commitCurrentEdit()

        let didFail = await settle {
            if case .failed = viewModel.mutationState { return true }
            return false
        }
        XCTAssertTrue(didFail)
        XCTAssertNil(notification)
        XCTAssertEqual(viewModel.editSession, .dirty(itemId: "1", draft: "edited text"))
    }

    func testSaveAndPastePersistsBeforeSelectingIncludingEmptyDraft() async {
        for draft in ["edited text", ""] {
            let client = MockBrowserStoreClient()
            var selectedContent: ClipboardContent?
            let viewModel = await makeLoadedTextViewModel(
                client: client,
                onSelect: { _, content in selectedContent = content }
            )
            editText(draft, in: viewModel)

            viewModel.confirmSelection()

            XCTAssertNil(selectedContent, "Save & Paste must wait for persistence")
            guard case .saving = viewModel.mutationState else {
                XCTFail("Expected the edit save to be in flight")
                continue
            }
            let didPaste = await settle { selectedContent != nil }
            XCTAssertTrue(didPaste)
            XCTAssertEqual(client.updatedTexts.first?.text, draft)
            XCTAssertEqual(selectedContent, .text(value: draft))
        }
    }

    func testSaveAndPasteRejectedByConcurrentMutationPreservesDraft() async {
        let client = MockBrowserStoreClient()
        var selectedContent: ClipboardContent?
        let viewModel = await makeLoadedTextViewModel(
            client: client,
            onSelect: { _, content in selectedContent = content }
        )
        editText("edited text", in: viewModel)
        viewModel.addTag(.bookmark, toItem: "1")

        viewModel.confirmSelection()

        XCTAssertNil(selectedContent)
        XCTAssertTrue(client.updatedTexts.isEmpty)
        XCTAssertEqual(viewModel.editSession, .dirty(itemId: "1", draft: "edited text"))
    }

    func testSaveAndPasteFailureDoesNotPasteOrDiscardDraft() async {
        let client = MockBrowserStoreClient()
        client.updateTextResult = .failure(.databaseOperationFailed(
            operation: "update text",
            underlying: NSError(domain: "BrowserEditingTests", code: 1)
        ))
        var didSelect = false
        let viewModel = await makeLoadedTextViewModel(
            client: client,
            onSelect: { _, _ in didSelect = true }
        )
        editText("edited text", in: viewModel)

        viewModel.confirmSelection()
        let didFail = await settle {
            if case .failed = viewModel.mutationState { return true }
            return false
        }

        XCTAssertTrue(didFail)
        XCTAssertFalse(didSelect)
        XCTAssertEqual(viewModel.editSession, .dirty(itemId: "1", draft: "edited text"))
    }

    func testNewerDraftCancelsPendingSaveAndPasteFollowUp() async {
        let client = MockBrowserStoreClient()
        var didSelect = false
        let viewModel = await makeLoadedTextViewModel(
            client: client,
            onSelect: { _, _ in didSelect = true }
        )
        editText("first draft", in: viewModel)
        viewModel.confirmSelection()

        viewModel.onTextEdit(
            "newer draft",
            for: "1",
            originalContent: .text(value: "first draft")
        )
        await flushMainActor()

        XCTAssertFalse(didSelect)
        XCTAssertEqual(viewModel.editSession, .dirty(itemId: "1", draft: "newer draft"))
        guard case .idle = viewModel.mutationState else {
            return XCTFail("Expected the older save to settle without consuming the newer draft")
        }
    }

    func testDisplayResetCancelsPendingSaveAndPasteCompletionButPersistsEdit() async {
        let client = MockBrowserStoreClient()
        var didSelect = false
        let viewModel = await makeLoadedTextViewModel(
            client: client,
            onSelect: { _, _ in didSelect = true }
        )
        editText("edited text", in: viewModel)
        viewModel.confirmSelection()
        guard case .saving = viewModel.mutationState else {
            return XCTFail("Expected Save & Paste persistence to be in flight")
        }

        // FloatingPanelController calls resetForDisplay after an explicit
        // panel dismissal. Persistence must finish, but its now-stale action
        // must not paste or dismiss a subsequently displayed session.
        viewModel.handleDisplayReset(initialSearchQuery: "")
        let didSettle = await settle {
            if case .idle = viewModel.mutationState { return true }
            return false
        }

        XCTAssertTrue(didSettle)
        XCTAssertEqual(client.updatedTexts.first?.text, "edited text")
        XCTAssertFalse(didSelect)
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

        var didCopyAnotherItem = false
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in didCopyAnotherItem = true },
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
        viewModel.copyOnlyItem(itemId: "2")
        XCTAssertFalse(didCopyAnotherItem)
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

    private func makeLoadedTextViewModel(
        client: MockBrowserStoreClient,
        onSelect: @escaping (String, ClipboardContent) -> Void,
        showSnackbarNotification: @escaping (NotificationRequest) -> Void = { _ in }
    ) async -> BrowserViewModel {
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "original text")],
            firstItem: makeItem(id: "1", text: "original text"),
            totalCount: 1
        ))
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: onSelect,
            onCopyOnly: { _, _ in },
            onDismiss: {},
            showSnackbarNotification: showSnackbarNotification
        )
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()
        return viewModel
    }

    private func editText(_ text: String, in viewModel: BrowserViewModel) {
        viewModel.onTextEdit(
            text,
            for: "1",
            originalContent: .text(value: "original text")
        )
    }
}
