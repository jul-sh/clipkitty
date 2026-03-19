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
        let firstMatchData = makeMatchData(text: "alpha beta", highlightStart: 0, highlightEnd: 1)
        let refinedMatchData = makeMatchData(text: "alpha beta", highlightStart: 0, highlightEnd: 2)
        client.matchDataByQuery = [
            "a": [1: firstMatchData],
            "al": [1: refinedMatchData],
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
        XCTAssertEqual(viewModel.previewSelection?.matchData, firstMatchData)

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
        XCTAssertEqual(viewModel.previewSelection?.matchData, refinedMatchData)
        XCTAssertEqual(client.loadMatchDataRequests.map(\.query), ["a", "al"])
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
        try? await Task.sleep(for: .seconds(4))
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
            items: [makeMatch(id: 1, snippet: "one")],
            firstItem: nil,
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
        client.resumeFetch(id: 1, with: makeItem(id: 1, text: "first"))
        await flushMainActor()

        viewModel.addTagToSelectedItem(.bookmark)

        XCTAssertTrue(viewModel.selectedItem?.itemMetadata.tags.contains(.bookmark) == true)
        XCTAssertTrue(viewModel.session.query.items.first?.itemMetadata.tags.contains(.bookmark) == true)
    }

    func testTagMutationFailureRollsBackState() async {
        let client = MockBrowserStoreClient()
        client.addTagResult = .failure(.databaseOperationFailed(
            operation: "addTag",
            underlying: NSError(domain: "ClipKitty", code: 3)
        ))
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: 1, snippet: "one")],
            firstItem: nil,
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
        client.resumeFetch(id: 1, with: makeItem(id: 1, text: "first"))
        await flushMainActor()

        viewModel.addTagToSelectedItem(.bookmark)
        await flushMainActor()

        XCTAssertFalse(viewModel.selectedItem?.itemMetadata.tags.contains(.bookmark) ?? true)
        XCTAssertFalse(viewModel.session.query.items.first?.itemMetadata.tags.contains(.bookmark) ?? true)

        guard case .failed = viewModel.session.mutation else {
            return XCTFail("Expected failed mutation after tag rollback")
        }
    }

    func testRemoveTagUnderFilterRemovesItemAndAdvancesSelection() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .tagged(tag: .bookmark)),
            items: [
                makeMatch(id: 1, snippet: "one", tags: [.bookmark]),
                makeMatch(id: 2, snippet: "two", tags: [.bookmark]),
            ],
            firstItem: nil,
            totalCount: 2
        ))

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.setTagFilter(.bookmark)
        await flushMainActor()
        client.resumeFetch(id: 1, with: makeItem(id: 1, text: "first", tags: [.bookmark]))
        await flushMainActor()

        viewModel.removeTagFromSelectedItem(.bookmark)
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, [2])
        XCTAssertEqual(viewModel.selectedItemId, 2)
        XCTAssertFalse(viewModel.itemIds.contains(1))
    }

    func testDeleteOptimisticallyRemovesAndAdvancesSelection() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [
                makeMatch(id: 1, snippet: "one"),
                makeMatch(id: 2, snippet: "two"),
                makeMatch(id: 3, snippet: "three"),
            ],
            firstItem: nil,
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
        client.resumeFetch(id: 1, with: makeItem(id: 1, text: "first"))
        await flushMainActor()

        viewModel.deleteSelectedItem()
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, [2, 3])
        XCTAssertEqual(viewModel.selectedItemId, 2)

        guard case .deleting(.pending(_)) = viewModel.session.mutation else {
            return XCTFail("Expected pending delete mutation")
        }
    }

    func testUndoDeleteRestoresItemAndSelection() async {
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
        client.resumeFetch(id: 1, with: makeItem(id: 1, text: "first"))
        await flushMainActor()

        viewModel.deleteSelectedItem()
        await flushMainActor()

        viewModel.undoPendingDelete()
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, [1, 2])
        XCTAssertEqual(viewModel.selectedItemId, 1)
        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, 1)

        guard case .idle = viewModel.session.mutation else {
            return XCTFail("Expected idle mutation after undo")
        }
    }

    func testDeleteLastItemClearsSelection() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: 1, snippet: "one")],
            firstItem: nil,
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
        client.resumeFetch(id: 1, with: makeItem(id: 1, text: "first"))
        await flushMainActor()

        viewModel.deleteSelectedItem()
        await flushMainActor()

        XCTAssertTrue(viewModel.itemIds.isEmpty)
        XCTAssertNil(viewModel.selectedItemId)

        guard case .empty = viewModel.session.preview else {
            return XCTFail("Expected empty preview after deleting final item")
        }
    }

    func testCommitEditUpdatesPreviewOptimistically() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: 1, snippet: "original text")],
            firstItem: nil,
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
        client.resumeFetch(id: 1, with: makeItem(id: 1, text: "original text"))
        await flushMainActor()

        viewModel.onTextEdit("edited text", for: 1, originalText: "original text")
        viewModel.commitCurrentEdit()
        await flushMainActor()

        guard case let .text(value)? = viewModel.selectedItem?.content else {
            return XCTFail("Expected selected item text content")
        }
        XCTAssertEqual(value, "edited text")
        XCTAssertTrue(viewModel.session.query.items.first?.itemMetadata.snippet.contains("edited") == true)
        XCTAssertEqual(client.updatedTexts.count, 1)
        XCTAssertEqual(client.updatedTexts.first?.itemId, 1)
        XCTAssertEqual(client.updatedTexts.first?.text, "edited text")
        XCTAssertFalse(viewModel.hasPendingEdit(for: 1))
    }

    func testDiscardEditClearsPendingState() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: 1, snippet: "original text")],
            firstItem: nil,
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
        client.resumeFetch(id: 1, with: makeItem(id: 1, text: "original text"))
        await flushMainActor()

        viewModel.onTextEdit("edited text", for: 1, originalText: "original text")
        viewModel.onEditingStateChange(true, for: 1)

        viewModel.discardCurrentEdit()
        await flushMainActor()

        XCTAssertFalse(viewModel.hasPendingEdit(for: 1))
        XCTAssertFalse(viewModel.isEditingPreview)
        XCTAssertEqual(viewModel.editFocus, .idle)
    }

    func testEditRevertedToOriginalClearsPendingEdit() async {
        let client = MockBrowserStoreClient()
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )

        viewModel.onTextEdit("edited", for: 1, originalText: "original")
        XCTAssertTrue(viewModel.hasPendingEdit(for: 1))

        viewModel.onTextEdit("original", for: 1, originalText: "original")

        XCTAssertFalse(viewModel.hasPendingEdit(for: 1))
    }

    func testMoveSelectionNavigatesList() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [
                makeMatch(id: 1, snippet: "one"),
                makeMatch(id: 2, snippet: "two"),
                makeMatch(id: 3, snippet: "three"),
            ],
            firstItem: nil,
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

        XCTAssertEqual(viewModel.selectedItemId, 1)

        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedItemId, 2)

        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedItemId, 3)

        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedItemId, 3)
    }

    func testClearSuccessEmptiesAllState() async {
        let client = MockBrowserStoreClient()
        client.clearResult = .success(())
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
        client.resumeFetch(id: 1, with: makeItem(id: 1, text: "first"))
        await flushMainActor()

        viewModel.clearAll()
        await flushMainActor()
        await flushMainActor()

        XCTAssertTrue(viewModel.itemIds.isEmpty)
        XCTAssertNil(viewModel.selectedItemId)

        guard case .empty = viewModel.session.preview else {
            return XCTFail("Expected empty preview after clear")
        }
        guard case .idle = viewModel.session.mutation else {
            return XCTFail("Expected idle mutation after clear success")
        }
    }

    func testPreviewLoadsOnInitialSearchWithFirstItem() async {
        let client = MockBrowserStoreClient()
        let item = makeItem(id: 1, text: "selected text")
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: 1, snippet: "selected text")],
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

        XCTAssertEqual(viewModel.selectedItemId, 1)
        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, 1)
    }

    func testSelectionChangeTriggersPreviewLoad() async {
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
        client.resumeFetch(id: 1, with: makeItem(id: 1, text: "first"))
        await flushMainActor()

        viewModel.select(itemId: 2, origin: .user)
        await flushMainActor()
        client.resumeFetch(id: 2, with: makeItem(id: 2, text: "second"))
        await flushMainActor()

        XCTAssertEqual(viewModel.selectedItem?.itemMetadata.itemId, 2)
    }

    func testConfirmSelectionFiresCallback() async {
        let client = MockBrowserStoreClient()
        let item = makeItem(id: 1, text: "selected text")
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: 1, snippet: "selected text")],
            firstItem: item,
            totalCount: 1
        ))

        var selectedId: Int64?
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

        XCTAssertEqual(selectedId, 1)
        guard case let .text(value)? = selectedContent else {
            return XCTFail("Expected text content in onSelect callback")
        }
        XCTAssertEqual(value, "selected text")
    }

    func testCopyOnlyFiresCallback() async {
        let client = MockBrowserStoreClient()
        let item = makeItem(id: 1, text: "selected text")
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: 1, snippet: "selected text")],
            firstItem: item,
            totalCount: 1
        ))

        var copiedId: Int64?
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

        XCTAssertEqual(copiedId, 1)
        guard case let .text(value)? = copiedContent else {
            return XCTFail("Expected text content in onCopyOnly callback")
        }
        XCTAssertEqual(value, "selected text")
    }

    func testDeleteBlockedWhileMutationPending() async {
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
        client.resumeFetch(id: 1, with: makeItem(id: 1, text: "first"))
        await flushMainActor()

        viewModel.deleteSelectedItem()
        await flushMainActor()

        viewModel.select(itemId: 2, origin: .user)
        viewModel.deleteSelectedItem()
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, [2])
        XCTAssertTrue(viewModel.itemIds.contains(2))

        guard case let .deleting(.pending(transaction)) = viewModel.session.mutation else {
            return XCTFail("Expected original delete to remain pending")
        }
        XCTAssertEqual(transaction.deletedItemId, 1)
    }

    func testDismissMutationFailureClearsState() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: 1, snippet: "one"), makeMatch(id: 2, snippet: "two")],
            firstItem: nil,
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
            onDismiss: {}
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()
        client.resumeFetch(id: 1, with: makeItem(id: 1, text: "first"))
        await flushMainActor()

        viewModel.deleteSelectedItem()
        try? await Task.sleep(for: .seconds(4))
        await flushMainActor()

        XCTAssertNotNil(viewModel.mutationFailureMessage)

        viewModel.dismissMutationFailure()

        XCTAssertNil(viewModel.mutationFailureMessage)
        guard case .idle = viewModel.session.mutation else {
            return XCTFail("Expected idle mutation after dismissing failure")
        }
    }

    private func flushMainActor() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    private func makeMatch(id: Int64, snippet: String, tags: [ItemTag] = []) -> ItemMatch {
        ItemMatch(
            itemMetadata: ItemMetadata(
                itemId: id,
                icon: .symbol(iconType: .text),
                snippet: snippet,
                sourceApp: nil,
                sourceAppBundleId: nil,
                timestampUnix: 0,
                tags: tags
            ),
            matchData: nil
        )
    }

    private func makeItem(id: Int64, text: String, tags: [ItemTag] = []) -> ClipboardItem {
        ClipboardItem(
            itemMetadata: ItemMetadata(
                itemId: id,
                icon: .symbol(iconType: .text),
                snippet: text,
                sourceApp: nil,
                sourceAppBundleId: nil,
                timestampUnix: 0,
                tags: tags
            ),
            content: .text(value: text)
        )
    }

    private func makeMatchData(
        text: String,
        highlightStart: UInt64,
        highlightEnd: UInt64
    ) -> MatchData {
        let highlight = HighlightRange(start: highlightStart, end: highlightEnd, kind: .exact)
        return MatchData(
            text: text,
            highlights: [highlight],
            lineNumber: 1,
            fullContentHighlights: [highlight],
            densestHighlightStart: highlightStart
        )
    }
}

@MainActor
private final class MockBrowserStoreClient: BrowserStoreClient {
    struct MatchDataRequest: Equatable {
        let itemIds: [Int64]
        let query: String
    }

    private var pendingSearchResponses: [BrowserSearchResponse] = []
    private var searchContinuations: [CheckedContinuation<BrowserSearchOutcome, Never>] = []
    var addTagResult: Result<Void, ClipboardError> = .success(())
    var removeTagResult: Result<Void, ClipboardError> = .success(())
    var deleteResult: Result<Void, ClipboardError> = .success(())
    var clearResult: Result<Void, ClipboardError> = .success(())
    var updateTextResult: Result<Void, ClipboardError> = .success(())
    var updatedTexts: [(itemId: Int64, text: String)] = []
    var startedSearchRequests: [SearchRequest] = []
    var loadMatchDataRequests: [MatchDataRequest] = []
    var matchDataByQuery: [String: [Int64: MatchData]] = [:]
    private var fetchContinuations: [Int64: [CheckedContinuation<ClipboardItem?, Never>]] = [:]

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

    func loadMatchData(itemIds: [Int64], query: String) async -> [MatchData] {
        loadMatchDataRequests.append(MatchDataRequest(itemIds: itemIds, query: query))
        let matchDataByItemId = matchDataByQuery[query] ?? [:]
        return itemIds.compactMap { matchDataByItemId[$0] }
    }

    func fetchLinkMetadata(url: String, itemId: Int64) async -> ClipboardItem? {
        nil
    }

    func addTag(itemId: Int64, tag: ItemTag) async -> Result<Void, ClipboardError> {
        addTagResult
    }

    func removeTag(itemId: Int64, tag: ItemTag) async -> Result<Void, ClipboardError> {
        removeTagResult
    }

    func delete(itemId: Int64) async -> Result<Void, ClipboardError> {
        deleteResult
    }

    func clear() async -> Result<Void, ClipboardError> {
        clearResult
    }

    func updateTextItem(itemId: Int64, text: String) async -> Result<Void, ClipboardError> {
        updatedTexts.append((itemId: itemId, text: text))
        return updateTextResult
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
