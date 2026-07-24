import ClipKittyBrowser
import ClipKittyCore
import ClipKittyRust
import Foundation

@MainActor
final class ClipboardStoreBrowserClient: BrowserStoreClient {
    private let store: ClipboardStore

    let listPresentationProfile: ListPresentationProfile = .compactRow

    init(store: ClipboardStore) {
        self.store = store
    }

    func startSearch(request: SearchRequest) -> BrowserSearchOperation {
        RepositoryBrowserSearchOperation(
            request: request,
            operation: store.startSearch(query: request.text, filter: request.filter, presentation: .compactRow)
        )
    }

    func fetchItem(id: String) async -> ClipboardItem? {
        await store.fetchItem(id: id)
    }

    func resolveMatchedExcerpts(requests: [MatchedExcerptRequest]) async -> [MatchedExcerptResolution] {
        await store.resolveMatchedExcerpts(requests: requests)
    }

    func loadPreviewPayload(itemId: String, query: String) async -> PreviewPayload? {
        await store.loadPreviewPayload(itemId: itemId, query: query)
    }

    func fetchLinkMetadata(url: String, itemId: String) async -> ClipboardItem? {
        #if ENABLE_LINK_PREVIEWS
            await store.fetchLinkMetadata(url: url, itemId: itemId)
        #else
            nil
        #endif
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

    func formatExcerpt(content: String) -> String {
        store.formatExcerpt(content: content, presentation: listPresentationProfile)
    }
}
