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
