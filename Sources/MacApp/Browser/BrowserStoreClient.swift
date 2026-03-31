import ClipKittyRust
import ClipKittyShared
import Foundation

private final class ClipboardStoreBrowserSearchOperation: BrowserSearchOperation {
    let request: SearchRequest
    private let operation: ClipboardSearchOperation

    init(request: SearchRequest, operation: ClipboardSearchOperation) {
        self.request = request
        self.operation = operation
    }

    func cancel() {
        operation.cancel()
    }

    func awaitOutcome() async -> BrowserSearchOutcome {
        switch await operation.awaitOutcome() {
        case let .success(result):
            return .success(BrowserSearchResponse(
                request: request,
                items: result.matches,
                firstPreviewPayload: result.firstPreviewPayload,
                totalCount: Int(result.totalCount)
            ))
        case .cancelled:
            return .cancelled
        case let .failure(error):
            return .failure(error)
        }
    }
}

@MainActor
final class ClipboardStoreBrowserClient: BrowserStoreClient {
    private let store: ClipboardStore

    init(store: ClipboardStore) {
        self.store = store
    }

    func startSearch(request: SearchRequest) -> BrowserSearchOperation {
        ClipboardStoreBrowserSearchOperation(
            request: request,
            operation: store.startSearch(query: request.text, filter: request.filter, presentation: .compactRow)
        )
    }

    func fetchItem(id: String) async -> ClipboardItem? {
        await store.fetchItem(id: id)
    }

    func loadListDecorations(itemIds: [String], query: String, presentation: ListPresentationProfile) async -> [ListDecorationResult] {
        await store.loadListDecorations(itemIds: itemIds, query: query, presentation: presentation)
    }

    func loadPreviewPayload(itemId: String, query: String) async -> PreviewPayload? {
        await store.loadPreviewPayload(itemId: itemId, query: query)
    }

    func fetchLinkMetadata(url: String, itemId: String) async -> ClipboardItem? {
        await store.fetchLinkMetadata(url: url, itemId: itemId)
    }

    func addTag(itemId: String, tag: ItemTag) async -> Result<Void, ClipboardError> {
        await store.addTag(itemId: itemId, tag: tag)
    }

    func removeTag(itemId: String, tag: ItemTag) async -> Result<Void, ClipboardError> {
        await store.removeTag(itemId: itemId, tag: tag)
    }

    func delete(itemId: String) async -> Result<Void, ClipboardError> {
        await store.deleteItem(itemId: itemId)
    }

    func clear() async -> Result<Void, ClipboardError> {
        await store.clearAll()
    }

    func updateTextItem(itemId: String, text: String) async -> Result<Void, ClipboardError> {
        await store.updateTextItem(itemId: itemId, text: text)
    }
}
