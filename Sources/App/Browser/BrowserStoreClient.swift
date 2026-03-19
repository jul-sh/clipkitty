import ClipKittyRust
import Foundation

enum BrowserSearchOutcome {
    case success(BrowserSearchResponse)
    case cancelled
    case failure(ClipboardError)
}

protocol BrowserSearchOperation: AnyObject {
    var request: SearchRequest { get }
    func cancel()
    func awaitOutcome() async -> BrowserSearchOutcome
}

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
protocol BrowserStoreClient: AnyObject {
    func startSearch(request: SearchRequest) -> BrowserSearchOperation
    func fetchItem(id: Int64) async -> ClipboardItem?
    func loadRowDecorations(itemIds: [Int64], query: String) async -> [RowDecorationResult]
    func loadPreviewPayload(itemId: Int64, query: String) async -> PreviewPayload?
    func fetchLinkMetadata(url: String, itemId: Int64) async -> ClipboardItem?
    func addTag(itemId: Int64, tag: ItemTag) async -> Result<Void, ClipboardError>
    func removeTag(itemId: Int64, tag: ItemTag) async -> Result<Void, ClipboardError>
    func delete(itemId: Int64) async -> Result<Void, ClipboardError>
    func clear() async -> Result<Void, ClipboardError>
    func updateTextItem(itemId: Int64, text: String) async -> Result<Void, ClipboardError>
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
            operation: store.startSearch(query: request.text, filter: request.filter)
        )
    }

    func fetchItem(id: Int64) async -> ClipboardItem? {
        await store.fetchItem(id: id)
    }

    func loadRowDecorations(itemIds: [Int64], query: String) async -> [RowDecorationResult] {
        await store.loadRowDecorations(itemIds: itemIds, query: query)
    }

    func loadPreviewPayload(itemId: Int64, query: String) async -> PreviewPayload? {
        await store.loadPreviewPayload(itemId: itemId, query: query)
    }

    func fetchLinkMetadata(url: String, itemId: Int64) async -> ClipboardItem? {
        await store.fetchLinkMetadata(url: url, itemId: itemId)
    }

    func addTag(itemId: Int64, tag: ItemTag) async -> Result<Void, ClipboardError> {
        await store.addTag(itemId: itemId, tag: tag)
    }

    func removeTag(itemId: Int64, tag: ItemTag) async -> Result<Void, ClipboardError> {
        await store.removeTag(itemId: itemId, tag: tag)
    }

    func delete(itemId: Int64) async -> Result<Void, ClipboardError> {
        await store.deleteItem(itemId: itemId)
    }

    func clear() async -> Result<Void, ClipboardError> {
        await store.clearAll()
    }

    func updateTextItem(itemId: Int64, text: String) async -> Result<Void, ClipboardError> {
        await store.updateTextItem(itemId: itemId, text: text)
    }
}
