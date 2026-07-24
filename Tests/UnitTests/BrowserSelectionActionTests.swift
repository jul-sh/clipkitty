@testable import ClipKitty
@testable import ClipKittyBrowser
import ClipKittyCore
import ClipKittyRust
import XCTest

@MainActor
final class BrowserSelectionActionTests: XCTestCase {
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
}
