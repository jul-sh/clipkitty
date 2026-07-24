@testable import ClipKittyBrowser
import ClipKittyCore
import ClipKittyRust
import Foundation

@MainActor
final class MockBrowserStoreClient: BrowserStoreClient {
    struct MatchedExcerptRequestKey: Hashable {
        let itemIds: [String]
        let query: String
    }

    struct PreviewDecorationRequest: Hashable {
        let itemId: String
        let query: String
    }

    let listPresentationProfile: ListPresentationProfile = .compactRow

    private var pendingSearchResponses: [BrowserSearchResponse] = []
    private var searchContinuations: [CheckedContinuation<BrowserSearchOutcome, Never>] = []
    var addTagResult: Result<Void, ClipboardError> = .success(())
    var defersTagMutations = false
    var addTagRequests: [(itemId: String, tag: ItemTag)] = []
    var removeTagResult: Result<Void, ClipboardError> = .success(())
    var deleteResult: Result<Void, ClipboardError> = .success(())
    var queuedDeleteResults: [Result<Void, ClipboardError>] = []
    var deletedItemIds: [String] = []
    var clearResult: Result<Void, ClipboardError> = .success(())
    var defersClear = false
    var clearCallCount = 0
    var updateTextResult: Result<Void, ClipboardError> = .success(())
    var defersTextUpdates = false
    var updatedTexts: [(itemId: String, text: String)] = []
    var startedSearchRequests: [SearchRequest] = []
    var resolveMatchedExcerptRequests: [MatchedExcerptRequestKey] = []
    var loadPreviewDecorationRequests: [PreviewDecorationRequest] = []
    var matchedExcerptsByQuery: [String: [String: MatchedExcerpt]] = [:]
    var previewPayloadsByQuery: [String: [String: PreviewPayload]] = [:]
    private var fetchContinuations: [String: [CheckedContinuation<ClipboardItem?, Never>]] = [:]
    private var matchedExcerptContinuations: [MatchedExcerptRequestKey: [CheckedContinuation<[MatchedExcerptResolution], Never>]] = [:]
    private var previewPayloadContinuations: [PreviewDecorationRequest: [CheckedContinuation<PreviewPayload?, Never>]] = [:]
    private var updateTextContinuations: [CheckedContinuation<Result<Void, ClipboardError>, Never>] = []
    private var queuedUpdateTextResults: [Result<Void, ClipboardError>] = []
    private var addTagContinuations: [CheckedContinuation<Result<Void, ClipboardError>, Never>] = []
    private var queuedAddTagResults: [Result<Void, ClipboardError>] = []
    private var clearContinuations: [CheckedContinuation<Result<Void, ClipboardError>, Never>] = []
    private var queuedClearResults: [Result<Void, ClipboardError>] = []
    // Results resumed before the view model parked the matching request.
    // Every resume either resolves a parked continuation or queues here — a
    // resume must never be silently dropped just because the test won the
    // race to the mock (the search path already queues; these mirror it).
    private var queuedFetchResults: [String: ClipboardItem?] = [:]
    private var queuedMatchedExcerpts: [MatchedExcerptRequestKey: [MatchedExcerptResolution]] = [:]
    private var queuedPreviewPayloads: [PreviewDecorationRequest: PreviewPayload?] = [:]

    func startSearch(request: SearchRequest) -> BrowserSearchOperation {
        startedSearchRequests.append(request)
        return MockBrowserSearchOperation(request: request) { [weak self] in
            guard let self else { return .cancelled }
            return await self.nextSearchOutcome()
        }
    }

    func nextSearchOutcome() async -> BrowserSearchOutcome {
        if !pendingSearchResponses.isEmpty {
            return .success(pendingSearchResponses.removeFirst())
        }
        return await withCheckedContinuation { continuation in
            searchContinuations.append(continuation)
        }
    }

    func fetchItem(id: String) async -> ClipboardItem? {
        if let queued = queuedFetchResults.removeValue(forKey: id) {
            return queued
        }
        return await withTaskCancellationHandler {
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

    func resolveMatchedExcerpts(requests: [MatchedExcerptRequest]) async -> [MatchedExcerptResolution] {
        let itemIds = requests.map { $0.itemId }
        let query = requests.first?.query ?? ""
        let request = MatchedExcerptRequestKey(itemIds: itemIds, query: query)
        resolveMatchedExcerptRequests.append(request)

        if let excerptsByItemId = matchedExcerptsByQuery[query] {
            return itemIds.map { itemId in
                if let excerpt = excerptsByItemId[itemId] {
                    return .ready(itemId: itemId, excerpt: excerpt)
                }
                return .unavailable(itemId: itemId, reason: .itemMissing)
            }
        }

        if let queued = queuedMatchedExcerpts.removeValue(forKey: request) {
            return queued
        }

        return await withCheckedContinuation { continuation in
            matchedExcerptContinuations[request, default: []].append(continuation)
        }
    }

    func formatExcerpt(content: String) -> String {
        String(content.prefix(200))
    }

    func loadPreviewPayload(itemId: String, query: String) async -> PreviewPayload? {
        let request = PreviewDecorationRequest(itemId: itemId, query: query)
        loadPreviewDecorationRequests.append(request)

        if let payloadsByItemId = previewPayloadsByQuery[query] {
            return payloadsByItemId[itemId]
        }

        if let queued = queuedPreviewPayloads.removeValue(forKey: request) {
            return queued
        }

        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let item = await fetchItem(id: itemId)
        {
            return PreviewPayload(item: item, decoration: nil)
        }

        return await withCheckedContinuation { continuation in
            previewPayloadContinuations[request, default: []].append(continuation)
        }
    }

    func fetchLinkMetadata(url _: String, itemId _: String) async -> ClipboardItem? {
        nil
    }

    func addTag(itemId: String, tag: ItemTag) async -> Result<Void, ClipboardError> {
        addTagRequests.append((itemId, tag))
        if !queuedAddTagResults.isEmpty {
            return queuedAddTagResults.removeFirst()
        }
        if defersTagMutations {
            return await withCheckedContinuation { continuation in
                addTagContinuations.append(continuation)
            }
        }
        return addTagResult
    }

    func removeTag(itemId _: String, tag _: ItemTag) async -> Result<Void, ClipboardError> {
        removeTagResult
    }

    func delete(itemId: String) async -> Result<Void, ClipboardError> {
        deletedItemIds.append(itemId)
        if !queuedDeleteResults.isEmpty {
            return queuedDeleteResults.removeFirst()
        }
        return deleteResult
    }

    func clear() async -> Result<Void, ClipboardError> {
        clearCallCount += 1
        if !queuedClearResults.isEmpty {
            return queuedClearResults.removeFirst()
        }
        if defersClear {
            return await withCheckedContinuation { continuation in
                clearContinuations.append(continuation)
            }
        }
        return clearResult
    }

    func updateTextItem(itemId: String, text: String) async -> Result<Void, ClipboardError> {
        updatedTexts.append((itemId: itemId, text: text))
        if !queuedUpdateTextResults.isEmpty {
            return queuedUpdateTextResults.removeFirst()
        }
        if defersTextUpdates {
            return await withCheckedContinuation { continuation in
                updateTextContinuations.append(continuation)
            }
        }
        return updateTextResult
    }

    func resumeTextUpdate(with result: Result<Void, ClipboardError>) {
        guard !updateTextContinuations.isEmpty else {
            queuedUpdateTextResults.append(result)
            return
        }
        updateTextContinuations.removeFirst().resume(returning: result)
    }

    func resumeAddTag(with result: Result<Void, ClipboardError>) {
        guard !addTagContinuations.isEmpty else {
            queuedAddTagResults.append(result)
            return
        }
        addTagContinuations.removeFirst().resume(returning: result)
    }

    func resumeClear(with result: Result<Void, ClipboardError>) {
        guard !clearContinuations.isEmpty else {
            queuedClearResults.append(result)
            return
        }
        clearContinuations.removeFirst().resume(returning: result)
    }

    func resumeFetch(id: String, with item: ClipboardItem?) {
        if let continuations = fetchContinuations.removeValue(forKey: id) {
            continuations.forEach { $0.resume(returning: item) }
        } else {
            queuedFetchResults[id] = item
        }
    }

    func resumeMatchedExcerpts(itemIds: [String], query: String, with results: [MatchedExcerptResolution]) {
        let request = MatchedExcerptRequestKey(itemIds: itemIds, query: query)
        if let continuations = matchedExcerptContinuations.removeValue(forKey: request) {
            continuations.forEach { $0.resume(returning: results) }
        } else {
            queuedMatchedExcerpts[request] = results
        }
    }

    func resumePreviewPayload(itemId: String, query: String, with payload: PreviewPayload?) {
        let request = PreviewDecorationRequest(itemId: itemId, query: query)
        if let continuations = previewPayloadContinuations.removeValue(forKey: request) {
            continuations.forEach { $0.resume(returning: payload) }
        } else {
            queuedPreviewPayloads[request] = payload
        }
    }

    func enqueueSearchResponse(_ response: BrowserSearchResponse) {
        if searchContinuations.isEmpty {
            pendingSearchResponses.append(response)
        } else {
            resumeSearch(with: response)
        }
    }

    func resumeSearch(with response: BrowserSearchResponse) {
        guard !searchContinuations.isEmpty else {
            pendingSearchResponses.append(response)
            return
        }
        searchContinuations.removeFirst().resume(returning: .success(response))
    }

    func cancelNextSearch() {
        guard !searchContinuations.isEmpty else { return }
        searchContinuations.removeFirst().resume(returning: .cancelled)
    }
}

private final class MockBrowserSearchOperation: BrowserSearchOperation {
    let request: SearchRequest
    private let loader: @Sendable () async -> BrowserSearchOutcome
    private let lock = NSLock()
    private var isCancelled = false

    init(request: SearchRequest, loader: @escaping @Sendable () async -> BrowserSearchOutcome) {
        self.request = request
        self.loader = loader
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func awaitOutcome() async -> BrowserSearchOutcome {
        if cancelled {
            return .cancelled
        }
        let outcome = await loader()
        if cancelled {
            return .cancelled
        }
        return outcome
    }

    private var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }
}
