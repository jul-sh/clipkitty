import Foundation
import ClipKittyRust

@MainActor
protocol BrowserStoreClient: AnyObject {
    func search(request: SearchRequest) async throws -> BrowserSearchResponse
    func fetchItem(id: Int64) async -> ClipboardItem?
    func loadMatchData(itemIds: [Int64], query: String) async -> [MatchData]
    func fetchLinkMetadata(url: String, itemId: Int64) async -> ClipboardItem?
    func addTag(itemId: Int64, tag: ItemTag) async -> Result<Void, ClipboardError>
    func removeTag(itemId: Int64, tag: ItemTag) async -> Result<Void, ClipboardError>
    func delete(itemId: Int64) async -> Result<Void, ClipboardError>
    func clear() async -> Result<Void, ClipboardError>
}

@MainActor
final class ClipboardStoreBrowserClient: BrowserStoreClient {
    private let store: ClipboardStore

    init(store: ClipboardStore) {
        self.store = store
    }

    func search(request: SearchRequest) async throws -> BrowserSearchResponse {
        let result = try await store.search(query: request.text, filter: request.filter)
        return BrowserSearchResponse(
            request: request,
            items: result.matches,
            firstItem: result.firstItem,
            totalCount: Int(result.totalCount)
        )
    }

    func fetchItem(id: Int64) async -> ClipboardItem? {
        await store.fetchItem(id: id)
    }

    func loadMatchData(itemIds: [Int64], query: String) async -> [MatchData] {
        await store.loadMatchData(itemIds: itemIds, query: query)
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
}
