import ClipKittyRust
@testable import ClipKittyShared
import Foundation

@MainActor
final class MockiOSBrowserStoreClient: BrowserStoreClient {
    let listPresentationProfile: ListPresentationProfile = .card

    private var pendingSearchResponses: [BrowserSearchResponse] = []
    private var searchContinuations: [CheckedContinuation<BrowserSearchOutcome, Never>] = []
    private var fetchContinuations: [String: [CheckedContinuation<ClipboardItem?, Never>]] = [:]

    var addTagResult: Result<Void, ClipboardError> = .success(())
    var removeTagResult: Result<Void, ClipboardError> = .success(())
    var deleteResult: Result<Void, ClipboardError> = .success(())
    var clearResult: Result<Void, ClipboardError> = .success(())
    var updateTextResult: Result<Void, ClipboardError> = .success(())
    var updatedTexts: [(itemId: String, text: String)] = []
    var addedTags: [(String, ItemTag)] = []
    var removedTags: [(String, ItemTag)] = []

    func enqueueSearchResponse(_ response: BrowserSearchResponse) {
        if !searchContinuations.isEmpty {
            let continuation = searchContinuations.removeFirst()
            continuation.resume(returning: .success(response))
        } else {
            pendingSearchResponses.append(response)
        }
    }

    func resumeSearch(with response: BrowserSearchResponse) {
        guard !searchContinuations.isEmpty else {
            pendingSearchResponses.append(response)
            return
        }
        let continuation = searchContinuations.removeFirst()
        continuation.resume(returning: .success(response))
    }

    func resumeFetch(id: String, with item: ClipboardItem?) {
        guard let continuations = fetchContinuations[id], !continuations.isEmpty else { return }
        let continuation = fetchContinuations[id]!.removeFirst()
        continuation.resume(returning: item)
    }

    func startSearch(request: SearchRequest) -> BrowserSearchOperation {
        MockiOSBrowserSearchOperation(request: request) { [weak self] in
            guard let self else { return .cancelled }
            return await self.nextSearchOutcome()
        }
    }

    private func nextSearchOutcome() async -> BrowserSearchOutcome {
        if !pendingSearchResponses.isEmpty {
            return .success(pendingSearchResponses.removeFirst())
        }
        return await withCheckedContinuation { continuation in
            searchContinuations.append(continuation)
        }
    }

    func fetchItem(id: String) async -> ClipboardItem? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                fetchContinuations[id, default: []].append(continuation)
            }
        } onCancel: {
            Task { @MainActor in
                fetchContinuations[id]?.forEach { $0.resume(returning: nil) }
                fetchContinuations.removeValue(forKey: id)
            }
        }
    }

    func loadListDecorations(itemIds: [String], query _: String, presentation _: ListPresentationProfile) async -> [ListDecorationResult] {
        itemIds.map { ListDecorationResult(itemId: $0, decoration: nil) }
    }

    func loadPreviewPayload(itemId _: String, query _: String) async -> PreviewPayload? {
        nil
    }

    func fetchLinkMetadata(url _: String, itemId _: String) async -> ClipboardItem? {
        nil
    }

    func addTag(itemId: String, tag: ItemTag) async -> Result<Void, ClipboardError> {
        addedTags.append((itemId, tag))
        return addTagResult
    }

    func removeTag(itemId: String, tag: ItemTag) async -> Result<Void, ClipboardError> {
        removedTags.append((itemId, tag))
        return removeTagResult
    }

    func delete(itemId _: String) async -> Result<Void, ClipboardError> {
        deleteResult
    }

    func clear() async -> Result<Void, ClipboardError> {
        clearResult
    }

    func updateTextItem(itemId: String, text: String) async -> Result<Void, ClipboardError> {
        updatedTexts.append((itemId: itemId, text: text))
        return updateTextResult
    }

    /// Simulates card-profile excerpt formatting (truncate to 300 chars).
    func formatExcerpt(content: String) -> String {
        String(content.prefix(300))
    }
}

private final class MockiOSBrowserSearchOperation: BrowserSearchOperation {
    let request: SearchRequest
    private let producer: @Sendable () async -> BrowserSearchOutcome

    init(request: SearchRequest, producer: @escaping @Sendable () async -> BrowserSearchOutcome) {
        self.request = request
        self.producer = producer
    }

    func cancel() {}

    func awaitOutcome() async -> BrowserSearchOutcome {
        await producer()
    }
}
