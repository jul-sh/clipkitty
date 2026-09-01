import ClipKittyBrowser
import ClipKittyContentServices
import ClipKittyCore
import ClipKittyRust
import ClipKittyStore
import Foundation

/// Whether a client participates in warm-boot feed snapshots. Disabled for
/// contexts that must never mix persisted state into their fixture data
/// (screenshot runs) or that have no launch presentation to warm (tests).
enum iOSFeedSnapshotting {
    case disabled
    case enabled(initial: iOSFeedSnapshot?)
}

@MainActor
final class iOSBrowserStoreClient: BrowserStoreClient {
    private let repository: ClipboardRepository
    private let previewLoader: PreviewLoader
    private let recordsFeedSnapshot: Bool
    /// Served in place of the initial feed search while the deferred store is
    /// still opening, then dropped: the first live search replaces it.
    private var warmSnapshot: iOSFeedSnapshot?

    let listPresentationProfile: ListPresentationProfile = .card

    init(
        repository: ClipboardRepository,
        previewLoader: PreviewLoader,
        feedSnapshotting: iOSFeedSnapshotting = .disabled
    ) {
        self.repository = repository
        self.previewLoader = previewLoader
        switch feedSnapshotting {
        case .disabled:
            recordsFeedSnapshot = false
            warmSnapshot = nil
        case let .enabled(initial):
            recordsFeedSnapshot = true
            warmSnapshot = initial
        }
    }

    func startSearch(request: SearchRequest) -> BrowserSearchOperation {
        if repository.store == nil {
            if isInitialFeedRequest(request), let warmSnapshot {
                return WarmFeedSearchOperation(
                    request: request,
                    snapshot: warmSnapshot
                )
            }
        } else {
            warmSnapshot = nil
        }

        let operation = RepositoryBrowserSearchOperation(
            request: request,
            operation: repository.startSearch(
                query: request.text,
                filter: request.filter,
                presentation: .card
            )
        )
        guard recordsFeedSnapshot, isInitialFeedRequest(request) else {
            return operation
        }
        return FeedSnapshotRecordingSearchOperation(wrapping: operation)
    }

    private func isInitialFeedRequest(_ request: SearchRequest) -> Bool {
        request.text.isEmpty && request.filter == .all
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
        let result = await repository.clear()
        if case .success = result, recordsFeedSnapshot {
            warmSnapshot = nil
            iOSFeedSnapshotStore.scheduleClear()
        }
        return result
    }

    func updateTextItem(itemId: String, text: String) async -> Result<Void, ClipboardError> {
        await repository.updateTextItem(itemId: itemId, text: text)
    }

    func formatExcerpt(content: String) -> String {
        // While a deferred open is still pending there is no store to shape
        // the excerpt; the raw content stands in until the live search
        // replaces every warm row anyway.
        guard let store = repository.store else { return content }
        return store.formatExcerpt(content: content, presentation: listPresentationProfile)
    }
}

/// Serves the persisted last feed instantly while the deferred store opens.
private final class WarmFeedSearchOperation: BrowserSearchOperation {
    let request: SearchRequest
    private let snapshot: iOSFeedSnapshot

    init(request: SearchRequest, snapshot: iOSFeedSnapshot) {
        self.request = request
        self.snapshot = snapshot
    }

    func cancel() {}

    func awaitOutcome() async -> BrowserSearchOutcome {
        .success(BrowserSearchResponse(
            request: request,
            items: snapshot.items,
            firstPreviewPayload: nil,
            totalCount: snapshot.totalCount
        ))
    }
}

/// Persists successful default-feed responses so the next launch can warm-boot
/// from them.
private final class FeedSnapshotRecordingSearchOperation: BrowserSearchOperation {
    private let wrapped: BrowserSearchOperation

    var request: SearchRequest {
        wrapped.request
    }

    init(wrapping operation: BrowserSearchOperation) {
        wrapped = operation
    }

    func cancel() {
        wrapped.cancel()
    }

    func awaitOutcome() async -> BrowserSearchOutcome {
        let outcome = await wrapped.awaitOutcome()
        if case let .success(response) = outcome {
            iOSFeedSnapshotStore.scheduleSave(
                items: response.items,
                totalCount: response.totalCount
            )
        }
        return outcome
    }
}
