import ClipKittyCore
import ClipKittyRust
import ClipKittyStore
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

/// Adapts the repository's cancellable search operation to the browser's
/// request-aware result model. Both platform clients use the same adapter so
/// cancellation and result mapping cannot drift.
public final class RepositoryBrowserSearchOperation: BrowserSearchOperation {
    public let request: SearchRequest
    private let operation: ClipboardSearchOperation

    public init(request: SearchRequest, operation: ClipboardSearchOperation) {
        self.request = request
        self.operation = operation
    }

    public func cancel() {
        operation.cancel()
    }

    public func awaitOutcome() async -> BrowserSearchOutcome {
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
public protocol BrowserStoreClient: AnyObject {
    var listPresentationProfile: ListPresentationProfile { get }
    func startSearch(request: SearchRequest) -> BrowserSearchOperation
    func fetchItem(id: String) async -> ClipboardItem?
    func resolveMatchedExcerpts(requests: [MatchedExcerptRequest]) async -> [MatchedExcerptResolution]
    func loadPreviewPayload(itemId: String, query: String) async -> PreviewPayload?
    #if ENABLE_LINK_PREVIEWS
        func fetchLinkMetadata(url: String, itemId: String) async -> ClipboardItem?
    #endif
    func addTag(itemId: String, tag: ItemTag) async -> Result<Void, ClipboardError>
    func removeTag(itemId: String, tag: ItemTag) async -> Result<Void, ClipboardError>
    func delete(itemId: String) async -> Result<Void, ClipboardError>
    func clear() async -> Result<Void, ClipboardError>
    func updateTextItem(itemId: String, text: String) async -> Result<Void, ClipboardError>
    func formatExcerpt(content: String) -> String
}
