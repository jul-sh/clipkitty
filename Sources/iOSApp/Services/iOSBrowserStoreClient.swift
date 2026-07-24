import ClipKittyBrowser
import ClipKittyContentServices
import ClipKittyCore
import ClipKittyRust
import ClipKittyStore
import Foundation

@MainActor
final class iOSBrowserStoreClient: BrowserStoreClient {
    private let repository: ClipboardRepository
    private let previewLoader: PreviewLoader

    let listPresentationProfile: ListPresentationProfile = .card

    init(
        repository: ClipboardRepository,
        previewLoader: PreviewLoader
    ) {
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
