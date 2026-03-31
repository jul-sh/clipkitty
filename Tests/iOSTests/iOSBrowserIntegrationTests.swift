@testable import ClipKittyShared
import ClipKittyRust
import XCTest

/// Integration tests for iOS-specific BrowserViewModel flows.
/// Uses `.card` presentation profile to mirror the real iOS client.
@MainActor
final class iOSBrowserIntegrationTests: XCTestCase {

    // MARK: - Add item → appears in feed

    func testNewItemAppearsAfterContentRevisionBump() async {
        let client = MockiOSBrowserStoreClient()
        let viewModel = makeViewModel(client: client)

        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", snippet: "Hello world")],
            firstPreviewPayload: nil,
            totalCount: 1
        ))

        viewModel.onAppear(initialSearchQuery: "", contentRevision: 0)
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, ["1"])

        // Simulate a new item arriving (content revision bump triggers re-search)
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [
                makeMatch(id: "2", snippet: "New item"),
                makeMatch(id: "1", snippet: "Hello world"),
            ],
            firstPreviewPayload: nil,
            totalCount: 2
        ))

        viewModel.handleContentRevisionChange(1, isPanelVisible: true)
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, ["2", "1"])
    }

    // MARK: - Tap card → copy callback fires

    func testCopyOnlyItemFiresCallback() async {
        let client = MockiOSBrowserStoreClient()
        var copiedContent: ClipboardContent?
        var copiedItemId: String?

        let item = makeItem(id: "1", text: "Copy me")
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", snippet: "Copy me")],
            firstPreviewPayload: PreviewPayload(item: item, decoration: nil),
            totalCount: 1
        ))

        let viewModel = BrowserViewModel(
            client: client,
            onSelect: { _, _ in },
            onCopyOnly: { id, content in
                copiedItemId = id
                copiedContent = content
            },
            onDismiss: {}
        )

        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        // Resolve the fetch for the selected item so copyOnly can read content
        client.resumeFetch(id: "1", with: item)
        await flushMainActor()

        viewModel.copyOnlyItem(itemId: "1")
        await flushMainActor()

        XCTAssertEqual(copiedItemId, "1")
        if case let .text(value) = copiedContent {
            XCTAssertEqual(value, "Copy me")
        } else {
            XCTFail("Expected text content, got \(String(describing: copiedContent))")
        }
    }

    // MARK: - Edit long text → snippet uses formatExcerpt

    func testEditLongTextUsesFormatExcerpt() async {
        let client = MockiOSBrowserStoreClient()
        let longText = String(repeating: "a", count: 500)
        let item = makeItem(id: "1", text: "Short original")

        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", snippet: "Short original")],
            firstPreviewPayload: PreviewPayload(item: item, decoration: nil),
            totalCount: 1
        ))

        let viewModel = makeViewModel(client: client)
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        client.resumeFetch(id: "1", with: item)
        await flushMainActor()

        // Start editing
        viewModel.onTextEdit(longText, for: "1", originalText: "Short original")
        viewModel.commitCurrentEdit()
        await flushMainActor()

        // The mock formatExcerpt truncates to 300 chars (simulating card profile)
        // Verify the update was dispatched with the full text
        XCTAssertEqual(client.updatedTexts.count, 1)
        XCTAssertEqual(client.updatedTexts.first?.text, longText)

        // The optimistic snippet should have been formatted through formatExcerpt
        let displayRow = viewModel.displayRows.first { $0.id == "1" }
        XCTAssertNotNil(displayRow)
        // formatExcerpt in mock returns prefix(300), so snippet should be truncated
        XCTAssertEqual(displayRow?.metadata.snippet.count, 300)
    }

    // MARK: - Bookmark filter

    func testBookmarkFilterShowsOnlyBookmarkedItems() async {
        let client = MockiOSBrowserStoreClient()

        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [
                makeMatch(id: "1", snippet: "Bookmarked", tags: [.bookmark]),
                makeMatch(id: "2", snippet: "Not bookmarked"),
            ],
            firstPreviewPayload: nil,
            totalCount: 2
        ))

        let viewModel = makeViewModel(client: client)
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, ["1", "2"])

        // Apply bookmark filter — triggers new search
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .tag(.bookmark)),
            items: [makeMatch(id: "1", snippet: "Bookmarked", tags: [.bookmark])],
            firstPreviewPayload: nil,
            totalCount: 1
        ))

        viewModel.setTagFilter(.bookmark)
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, ["1"])
        XCTAssertEqual(viewModel.selectedTagFilter, .bookmark)

        // Clear bookmark filter
        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [
                makeMatch(id: "1", snippet: "Bookmarked", tags: [.bookmark]),
                makeMatch(id: "2", snippet: "Not bookmarked"),
            ],
            firstPreviewPayload: nil,
            totalCount: 2
        ))

        viewModel.setTagFilter(nil)
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, ["1", "2"])
    }

    // MARK: - File items filtered from iOS display rows

    func testFileItemsFilteredFromDisplayRows() async {
        let client = MockiOSBrowserStoreClient()

        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [
                makeMatch(id: "1", snippet: "Text item", icon: .symbol(iconType: .text)),
                makeMatch(id: "2", snippet: "file.pdf", icon: .symbol(iconType: .file)),
                makeMatch(id: "3", snippet: "https://example.com", icon: .symbol(iconType: .link)),
            ],
            firstPreviewPayload: nil,
            totalCount: 3
        ))

        let viewModel = makeViewModel(client: client)
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        // ViewModel sees all items
        XCTAssertEqual(viewModel.itemIds, ["1", "2", "3"])

        // iOS HomeFeedView filteredRows logic: exclude .file icons
        let filteredRows = viewModel.displayRows.filter { row in
            if case .symbol(.file) = row.metadata.icon { return false }
            return true
        }

        XCTAssertEqual(filteredRows.map(\.id), ["1", "3"])
    }

    // MARK: - Card presentation profile

    func testCardPresentationProfileUsed() {
        let client = MockiOSBrowserStoreClient()
        XCTAssertEqual(client.listPresentationProfile, .card)
    }

    // MARK: - Delete item

    func testDeleteItemRemovesFromFeed() async {
        let client = MockiOSBrowserStoreClient()
        let item = makeItem(id: "1", text: "Delete me")

        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", snippet: "Delete me")],
            firstPreviewPayload: PreviewPayload(item: item, decoration: nil),
            totalCount: 1
        ))

        let viewModel = makeViewModel(client: client)
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        client.resumeFetch(id: "1", with: item)
        await flushMainActor()

        XCTAssertEqual(viewModel.itemIds, ["1"])

        viewModel.deleteItem(itemId: "1")
        await flushMainActor()

        // After delete, item should be removed optimistically
        XCTAssertTrue(viewModel.itemIds.isEmpty)
    }

    // MARK: - Add/remove bookmark

    func testToggleBookmarkUpdatesItemTags() async {
        let client = MockiOSBrowserStoreClient()
        let item = makeItem(id: "1", text: "Tag me")

        client.enqueueSearchResponse(BrowserSearchResponse(
            request: SearchRequest(text: "", filter: .all),
            items: [makeMatch(id: "1", snippet: "Tag me")],
            firstPreviewPayload: PreviewPayload(item: item, decoration: nil),
            totalCount: 1
        ))

        let viewModel = makeViewModel(client: client)
        viewModel.onAppear(initialSearchQuery: "")
        await flushMainActor()

        client.resumeFetch(id: "1", with: item)
        await flushMainActor()

        // Add bookmark
        viewModel.addTag(.bookmark, toItem: "1")
        await flushMainActor()

        XCTAssertEqual(client.addedTags, [("1", .bookmark)])

        // Remove bookmark
        viewModel.removeTag(.bookmark, fromItem: "1")
        await flushMainActor()

        XCTAssertEqual(client.removedTags, [("1", .bookmark)])
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

    private func makeMatch(
        id: String,
        snippet: String,
        tags: [ItemTag] = [],
        icon: ItemIcon = .symbol(iconType: .text)
    ) -> ItemMatch {
        ItemMatch(
            itemMetadata: ItemMetadata(
                itemId: id,
                icon: icon,
                snippet: snippet,
                sourceApp: nil,
                sourceAppBundleId: nil,
                timestampUnix: 0,
                tags: tags
            ),
            listDecoration: nil
        )
    }

    private func makeItem(id: String, text: String, tags: [ItemTag] = []) -> ClipboardItem {
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
}
