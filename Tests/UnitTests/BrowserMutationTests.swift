@testable import ClipKitty
@testable import ClipKittyBrowser
import ClipKittyCore
import ClipKittyRust
import XCTest

@MainActor
final class BrowserMutationTests: XCTestCase {
    func testDeleteFailureRollsBackSearchAndSelection() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
            totalCount: 2
        ))
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstItem: makeItem(id: "1", text: "first"),
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
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstItem: makeItem(id: "1", text: "first"),
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

    func testClearRemainsInFlightAcrossDisplayResetAndRefreshesAfterFailure() async {
        let client = MockBrowserStoreClient()
        client.defersClear = true
        let request = SearchRequest(text: "", filter: .all)
        let response = BrowserSearchResponse(
            request: request,
            items: [makeMatch(id: "1", excerpt: "one")],
            firstItem: makeItem(id: "1", text: "one"),
            totalCount: 1
        )
        client.enqueueSearchResponse(response)
        client.enqueueSearchResponse(response)
        client.enqueueSearchResponse(response)
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        viewModel.clearAll()
        let didStartClear = await settle { client.clearCallCount == 1 }
        XCTAssertTrue(didStartClear)
        viewModel.handleDisplayReset(initialSearchQuery: "")
        await flushMainActor()
        guard case .clearing = viewModel.mutationState else {
            return XCTFail("Display reset must retain ownership of the clear write")
        }
        XCTAssertTrue(viewModel.itemIds.isEmpty)

        client.resumeClear(with: .failure(.databaseOperationFailed(
            operation: "clear",
            underlying: NSError(domain: "BrowserMutationTests", code: 5)
        )))
        let didRefresh = await settle {
            if case .failed = viewModel.mutationState {
                return viewModel.itemIds == ["1"]
            }
            return false
        }
        XCTAssertTrue(didRefresh)
    }

    func testClearSuccessFencesOlderSearchAndReconcilesAuthoritativeEmptyState() async {
        let client = MockBrowserStoreClient()
        client.defersClear = true
        let request = SearchRequest(text: "", filter: .all)
        let staleResponse = BrowserSearchResponse(
            request: request,
            items: [makeMatch(id: "1", excerpt: "one")],
            firstItem: makeItem(id: "1", text: "one"),
            totalCount: 1
        )
        client.enqueueSearchResponse(staleResponse)
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )
        viewModel.onAppear(initialSearchQuery: "")
        let didLoad = await settle { viewModel.itemIds == ["1"] }
        XCTAssertTrue(didLoad)

        viewModel.updateSearchText("")
        let didStartStaleSearch = await settle { client.startedSearchRequests.count == 2 }
        XCTAssertTrue(didStartStaleSearch)
        viewModel.clearAll()
        let didStartClear = await settle { client.clearCallCount == 1 }
        XCTAssertTrue(didStartClear)

        client.resumeSearch(with: staleResponse)
        await flushMainActor()
        XCTAssertTrue(viewModel.itemIds.isEmpty)
        guard case .clearing = viewModel.mutationState else {
            return XCTFail("A stale search must remain masked while clear persists")
        }

        client.resumeClear(with: .success(()))
        let didStartAuthoritativeSearch = await settle { client.startedSearchRequests.count == 3 }
        XCTAssertTrue(didStartAuthoritativeSearch)
        client.resumeSearch(with: BrowserSearchResponse(
            request: request,
            items: [],
            firstPreviewPayload: nil,
            totalCount: 0
        ))
        let didReconcile = await settle {
            if case .idle = viewModel.mutationState {
                return viewModel.itemIds.isEmpty
            }
            return false
        }
        XCTAssertTrue(didReconcile)
    }

    func testTagRemainsInFlightAcrossDisplayResetAndRefreshesAfterFailure() async {
        let client = MockBrowserStoreClient()
        client.defersTagMutations = true
        let request = SearchRequest(text: "", filter: .all)
        let response = BrowserSearchResponse(
            request: request,
            items: [makeMatch(id: "1", excerpt: "one")],
            firstItem: makeItem(id: "1", text: "one"),
            totalCount: 1
        )
        client.enqueueSearchResponse(response)
        client.enqueueSearchResponse(response)
        client.enqueueSearchResponse(response)
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        viewModel.addTag(.bookmark, toItem: "1")
        let didStartTag = await settle { client.addTagRequests.count == 1 }
        XCTAssertTrue(didStartTag)
        viewModel.handleDisplayReset(initialSearchQuery: "")
        await flushMainActor()
        guard case .tagging = viewModel.mutationState else {
            return XCTFail("Display reset must retain ownership of the tag write")
        }
        XCTAssertTrue(viewModel.contentState.items.first?.itemMetadata.tags.contains(.bookmark) == true)

        client.resumeAddTag(with: .failure(.databaseOperationFailed(
            operation: "add tag",
            underlying: NSError(domain: "BrowserMutationTests", code: 6)
        )))
        let didRefresh = await settle {
            if case .failed = viewModel.mutationState {
                return viewModel.contentState.items.first?.itemMetadata.tags.contains(.bookmark) == false
            }
            return false
        }
        XCTAssertTrue(didRefresh)
    }

    func testTagSuccessFencesOlderSearchUntilAuthoritativeRefresh() async {
        let client = MockBrowserStoreClient()
        client.defersTagMutations = true
        let request = SearchRequest(text: "", filter: .all)
        let untaggedResponse = BrowserSearchResponse(
            request: request,
            items: [makeMatch(id: "1", excerpt: "one")],
            firstItem: makeItem(id: "1", text: "one"),
            totalCount: 1
        )
        client.enqueueSearchResponse(untaggedResponse)
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )
        viewModel.onAppear(initialSearchQuery: "")
        let didLoad = await settle { viewModel.itemIds == ["1"] }
        XCTAssertTrue(didLoad)

        viewModel.updateSearchText("")
        let didStartStaleSearch = await settle { client.startedSearchRequests.count == 2 }
        XCTAssertTrue(didStartStaleSearch)
        viewModel.addTag(.bookmark, toItem: "1")
        let didStartTag = await settle { client.addTagRequests.count == 1 }
        XCTAssertTrue(didStartTag)

        client.resumeSearch(with: untaggedResponse)
        await flushMainActor()
        XCTAssertTrue(viewModel.contentState.items.first?.itemMetadata.tags.contains(.bookmark) == true)

        client.resumeAddTag(with: .success(()))
        let didStartAuthoritativeSearch = await settle { client.startedSearchRequests.count == 3 }
        XCTAssertTrue(didStartAuthoritativeSearch)
        client.resumeSearch(with: BrowserSearchResponse(
            request: request,
            items: [makeMatch(id: "1", excerpt: "one", tags: [.bookmark])],
            firstItem: makeItem(id: "1", text: "one", tags: [.bookmark]),
            totalCount: 1
        ))
        let didReconcile = await settle {
            if case .idle = viewModel.mutationState {
                return viewModel.contentState.items.first?.itemMetadata.tags.contains(.bookmark) == true
            }
            return false
        }
        XCTAssertTrue(didReconcile)
    }

    func testAddTagUpdatesPreviewOptimistically() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one")],
            firstPreviewPayload: nil,
            totalCount: 1
        ))
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one", tags: [.bookmark])],
            firstItem: makeItem(id: "1", text: "first", tags: [.bookmark]),
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

    /// A multi-item selection tags every item it names, in one transaction.
    /// The single-flight guard on `mutationState` would otherwise drop all but
    /// the first if these were issued as separate mutations.
    func testBatchTagAppliesToEveryNamedItem() async {
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

        viewModel.setTag(.bookmark, onItems: ["1", "3"], shouldInclude: true)

        let tagged = viewModel.contentState.items.filter {
            $0.itemMetadata.tags.contains(.bookmark)
        }.map(\.itemMetadata.itemId)
        XCTAssertEqual(tagged, ["1", "3"], "Only the named items should be tagged")
    }

    /// Tagging updates the visible rows in place. Restarting the search would
    /// discard the feed's caches and scroll the user back to the top for what
    /// is only a tag change, so the batch mutation must not re-query.
    func testBatchTagDoesNotRestartTheSearch() async {
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
        let searchesBeforeTagging = client.startedSearchRequests.count

        viewModel.setTag(.bookmark, onItems: ["1", "2"], shouldInclude: true)

        XCTAssertEqual(
            client.startedSearchRequests.count,
            searchesBeforeTagging,
            "Applying a tag must not issue a fresh search"
        )
    }

    /// An empty selection is a no-op rather than an empty transaction that
    /// would occupy the single-flight slot for no work.
    func testBatchTagWithNoItemsDoesNothing() async {
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

        viewModel.setTag(.bookmark, onItems: [], shouldInclude: true)

        XCTAssertFalse(
            viewModel.contentState.items.contains { $0.itemMetadata.tags.contains(.bookmark) }
        )
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
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one")],
            firstItem: makeItem(id: "1", text: "first"),
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

    func testDeleteNotificationProjectsRenderingKindAndRoutesUndoAction() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstPreviewPayload: nil,
            totalCount: 2
        ))

        var notificationRequest: NotificationRequest?
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {},
            showSnackbarNotification: { notificationRequest = $0 }
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()
        client.resumeFetch(id: "1", with: makeItem(id: "1", text: "first"))
        await flushMainActor()

        viewModel.deleteSelectedItem()
        await flushMainActor()

        guard case let .actionable(message, iconSystemName, actionTitle, action)? = notificationRequest else {
            return XCTFail("Expected an actionable delete notification")
        }
        let deletedMessage = String(localized: "Deleted")
        let undoTitle = String(localized: "Undo")
        XCTAssertEqual(message, deletedMessage)
        XCTAssertEqual(iconSystemName, "trash")
        XCTAssertEqual(actionTitle, undoTitle)
        XCTAssertEqual(
            notificationRequest?.kind,
            .actionable(message: deletedMessage, iconSystemName: "trash", actionTitle: undoTitle)
        )

        action()

        XCTAssertEqual(viewModel.itemIds, ["1", "2"])
        XCTAssertEqual(viewModel.selectedItemId, "1")
        guard case .idle = viewModel.mutationState else {
            return XCTFail("Notification action should undo the pending delete")
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

    func testBatchDeleteDeduplicatesInStableOrderAndUndoRestoresSelection() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [
                makeMatch(id: "1", excerpt: "one"),
                makeMatch(id: "2", excerpt: "two"),
                makeMatch(id: "3", excerpt: "three"),
                makeMatch(id: "4", excerpt: "four"),
            ],
            firstItem: makeItem(id: "1", text: "one"),
            totalCount: 4
        ))
        var notifications: [NotificationRequest] = []
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {},
            showSnackbarNotification: { notifications.append($0) }
        )
        viewModel.onAppear(initialSearchQuery: "")
        let didLoad = await settle { viewModel.selectedItemId == "1" }
        XCTAssertTrue(didLoad)

        XCTAssertTrue(viewModel.deleteItems(itemIds: ["1", "2", "1"]))

        XCTAssertEqual(viewModel.itemIds, ["3", "4"])
        XCTAssertEqual(viewModel.contentState.response?.totalCount, 2)
        XCTAssertEqual(viewModel.selectedItemId, "3")
        XCTAssertEqual(notifications.count, 1)
        guard case let .deleting(.pending(transaction)) = viewModel.mutationState else {
            return XCTFail("Expected one pending batch delete")
        }
        XCTAssertEqual(transaction.deletedItemIds, ["1", "2"])

        viewModel.undoPendingDelete()

        XCTAssertEqual(viewModel.itemIds, ["1", "2", "3", "4"])
        XCTAssertEqual(viewModel.contentState.response?.totalCount, 4)
        XCTAssertEqual(viewModel.selectedItemId, "1")
        guard case .idle = viewModel.mutationState else {
            return XCTFail("Expected undo to end the batch delete")
        }
    }

    func testBatchDeleteAdvancesSelectionPastEveryDeletedRow() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [
                makeMatch(id: "1", excerpt: "one"),
                makeMatch(id: "2", excerpt: "two"),
                makeMatch(id: "3", excerpt: "three"),
                makeMatch(id: "4", excerpt: "four"),
            ],
            firstItem: makeItem(id: "1", text: "one"),
            totalCount: 4
        ))
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )
        viewModel.onAppear(initialSearchQuery: "")
        let didLoad = await settle { viewModel.itemIds == ["1", "2", "3", "4"] }
        XCTAssertTrue(didLoad)
        viewModel.select(itemId: "2", origin: .click)
        client.resumeFetch(id: "2", with: makeItem(id: "2", text: "two"))
        let didSelect = await settle { viewModel.selectedItemId == "2" }
        XCTAssertTrue(didSelect)

        XCTAssertTrue(viewModel.deleteItems(itemIds: ["2", "3"]))

        XCTAssertEqual(viewModel.itemIds, ["1", "4"])
        XCTAssertEqual(viewModel.selectedItemId, "4")
    }

    func testDeletingStaleItemDoesNotChangeVisibleRowsOrTotalCount() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstItem: makeItem(id: "1", text: "one"),
            totalCount: 2
        ))
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )
        viewModel.onAppear(initialSearchQuery: "")
        let didLoad = await settle { viewModel.itemIds == ["1", "2"] }
        XCTAssertTrue(didLoad)

        XCTAssertTrue(viewModel.deleteItem(itemId: "stale-item"))

        XCTAssertEqual(viewModel.itemIds, ["1", "2"])
        XCTAssertEqual(viewModel.contentState.response?.totalCount, 2)
        guard case let .deleting(.pending(transaction)) = viewModel.mutationState else {
            return XCTFail("Expected stale item deletion to remain pending for persistence")
        }
        XCTAssertEqual(transaction.deletedItemIds, ["stale-item"])
    }

    func testPendingBatchDeleteMasksOnlyMatchingItemsFromNewSearchCount() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [
                makeMatch(id: "1", excerpt: "one"),
                makeMatch(id: "2", excerpt: "two"),
                makeMatch(id: "4", excerpt: "four"),
            ],
            firstItem: makeItem(id: "1", text: "one"),
            totalCount: 3
        ))
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {}
        )
        viewModel.onAppear(initialSearchQuery: "")
        let didLoad = await settle { viewModel.itemIds == ["1", "2", "4"] }
        XCTAssertTrue(didLoad)
        XCTAssertTrue(viewModel.deleteItems(itemIds: ["1", "2"]))

        let nextRequest = SearchRequest(text: "next", filter: .all)
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: nextRequest,
            items: [makeMatch(id: "2", excerpt: "two"), makeMatch(id: "3", excerpt: "three")],
            firstItem: makeItem(id: "2", text: "two"),
            totalCount: 2
        ))
        viewModel.updateSearchText("next")

        let didLoadNextSearch = await settle {
            viewModel.contentState.request == nextRequest && viewModel.itemIds == ["3"]
        }
        XCTAssertTrue(didLoadNextSearch)
        XCTAssertEqual(viewModel.contentState.response?.totalCount, 1)
    }

    func testBatchDeleteCommitsEachUniqueItemOnceInInputOrder() async {
        let client = MockBrowserStoreClient()
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", excerpt: "one"), makeMatch(id: "2", excerpt: "two")],
            firstItem: makeItem(id: "1", text: "one"),
            totalCount: 2
        ))
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {},
            deleteCommitDelay: 0.05
        )
        viewModel.onAppear(initialSearchQuery: "")
        let didLoad = await settle { viewModel.itemIds == ["1", "2"] }
        XCTAssertTrue(didLoad)

        XCTAssertTrue(viewModel.deleteItems(itemIds: ["2", "1", "2"]))

        let didCommit = await settle { client.deletedItemIds == ["2", "1"] }
        XCTAssertTrue(didCommit)
    }

    func testMixedDeleteResultReconcilesWithAuthoritativeStoreState() async {
        let client = MockBrowserStoreClient()
        let request = SearchRequest(text: "", filter: .all)
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: request,
            items: [
                makeMatch(id: "1", excerpt: "one"),
                makeMatch(id: "2", excerpt: "two"),
                makeMatch(id: "3", excerpt: "three"),
            ],
            firstItem: makeItem(id: "1", text: "one"),
            totalCount: 3
        ))
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: request,
            items: [
                makeMatch(id: "2", excerpt: "two"),
                makeMatch(id: "3", excerpt: "three"),
            ],
            firstItem: makeItem(id: "2", text: "two"),
            totalCount: 2
        ))
        client.queuedDeleteResults = [
            .success(()),
            .failure(.databaseOperationFailed(
                operation: "delete item",
                underlying: NSError(domain: "BrowserMutationTests", code: 7)
            )),
        ]
        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { _, _ in },
            onDismiss: {},
            deleteCommitDelay: 0.05
        )
        viewModel.onAppear(initialSearchQuery: "")
        let didLoad = await settle { viewModel.itemIds == ["1", "2", "3"] }
        XCTAssertTrue(didLoad)

        viewModel.deleteItem(itemId: "1")
        viewModel.deleteItem(itemId: "2")

        let didReconcile = await settle(timeout: 2) {
            if case .failed = viewModel.mutationState {
                return viewModel.itemIds == ["2", "3"]
            }
            return false
        }
        XCTAssertTrue(didReconcile)
        XCTAssertEqual(client.deletedItemIds, ["1", "2"])
        XCTAssertEqual(viewModel.selectedItemId, "2")
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
}
