import ClipKittyAppleServices
import ClipKittyRust
import ClipKittyShared
import Foundation

private final class RepositoryBrowserSearchOperation: BrowserSearchOperation {
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
final class iOSBrowserStoreClient: BrowserStoreClient {
    private let repository: ClipboardRepository
    private let previewLoader: PreviewLoader

    let listPresentationProfile: ListPresentationProfile = .card

    init(repository: ClipboardRepository, previewLoader: PreviewLoader) {
        self.repository = repository
        self.previewLoader = previewLoader
    }

    func startSearch(request: SearchRequest) -> BrowserSearchOperation {
        RepositoryBrowserSearchOperation(
            request: request,
            operation: repository.startSearch(query: request.text, filter: request.filter, presentation: .card)
        )
    }

    func fetchItem(id: String) async -> ClipboardItem? {
        await previewLoader.fetchItem(id: id)
    }

    func resolveMatchedExcerpts(requests: [MatchedExcerptRequest]) async -> [MatchedExcerptResolution] {
        await repository.resolveMatchedExcerpts(requests: requests)
    }

    func loadPreviewPayload(itemId: String, query: String) async -> PreviewPayload? {
        await repository.loadPreviewPayload(itemId: itemId, query: query)
    }

    #if ENABLE_LINK_PREVIEWS
    func fetchLinkMetadata(url: String, itemId: String) async -> ClipboardItem? {
        await previewLoader.refreshLinkMetadata(url: url, itemId: itemId)
    }
    #endif

    func addTag(itemId: String, tag: ItemTag) async -> Result<Void, ClipboardError> {
        await repository.addTag(itemId: itemId, tag: tag)
    }

    func removeTag(itemId: String, tag: ItemTag) async -> Result<Void, ClipboardError> {
        await repository.removeTag(itemId: itemId, tag: tag)
    }

    func delete(itemId: String) async -> Result<Void, ClipboardError> {
        await repository.delete(itemId: itemId)
    }

    func clear() async -> Result<Void, ClipboardError> {
        await repository.clear()
    }

    func updateTextItem(itemId: String, text: String) async -> Result<Void, ClipboardError> {
        await repository.updateTextItem(itemId: itemId, text: text)
    }

    func formatExcerpt(content: String) -> String {
        repository.store.formatExcerpt(content: content, presentation: listPresentationProfile)
    }
}
