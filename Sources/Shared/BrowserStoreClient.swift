import ClipKittyRust
import Foundation

public enum BrowserSearchOutcome {
    case success(BrowserSearchResponse)
    case cancelled
    case failure(ClipboardError)
}

public protocol BrowserSearchOperation: AnyObject {
    var request: SearchRequest { get }
    func cancel()
    func awaitOutcome() async -> BrowserSearchOutcome
}

@MainActor
public protocol BrowserStoreClient: AnyObject {
    func startSearch(request: SearchRequest) -> BrowserSearchOperation
    func fetchItem(id: String) async -> ClipboardItem?
    func loadListDecorations(itemIds: [String], query: String, presentation: ListPresentationProfile) async -> [ListDecorationResult]
    func loadPreviewPayload(itemId: String, query: String) async -> PreviewPayload?
    func fetchLinkMetadata(url: String, itemId: String) async -> ClipboardItem?
    func addTag(itemId: String, tag: ItemTag) async -> Result<Void, ClipboardError>
    func removeTag(itemId: String, tag: ItemTag) async -> Result<Void, ClipboardError>
    func delete(itemId: String) async -> Result<Void, ClipboardError>
    func clear() async -> Result<Void, ClipboardError>
    func updateTextItem(itemId: String, text: String) async -> Result<Void, ClipboardError>
}
