import ClipKittyCore
import ClipKittyRust
import Foundation

public enum RepositorySearchOutcome {
    case success(SearchResult)
    case cancelled
    case failure(ClipboardError)
}

/// Typed result of the store's bounded, all-or-nothing transfer preflight.
public enum RepositoryTransferFetchOutcome {
    case success([ClipboardItem])
    case rejected(TransferFetchRejection)
    case cancelled
    case failure(ClipboardError)
}

public protocol ClipboardSearchOperation: AnyObject {
    func cancel()
    func awaitOutcome() async -> RepositorySearchOutcome
}

private final class RustClipboardSearchOperation: ClipboardSearchOperation {
    private let operation: ClipKittyRust.SearchOperation

    init(operation: ClipKittyRust.SearchOperation) {
        self.operation = operation
    }

    func cancel() {
        operation.cancel()
    }

    func awaitOutcome() async -> RepositorySearchOutcome {
        do {
            let outcome = try await operation.awaitResult()
            switch outcome {
            case let .success(result):
                return .success(result)
            case .cancelled:
                return .cancelled
            }
        } catch {
            return .failure(.databaseOperationFailed(operation: "search", underlying: error))
        }
    }
}

public func runRepositoryOperation<T: Sendable>(
    _ operation: String,
    on store: ClipKittyRust.ClipboardStore,
    body: @escaping @Sendable (ClipKittyRust.ClipboardStore) throws -> T
) async -> Result<T, ClipboardError> {
    do {
        let result = try await Task.detached(priority: .userInitiated) {
            try body(store)
        }.value
        return .success(result)
    } catch {
        return .failure(.databaseOperationFailed(operation: operation, underlying: error))
    }
}

/// Runs a synchronous Rust operation away from the caller's executor while
/// preserving structured cancellation at the repository boundary.
///
/// Cancelling the parent marks the detached operation cancelled. The operation
/// checks before and after the synchronous FFI call, and the parent still awaits
/// its completion so admitted Rust store work cannot outlive suspension teardown.
public func runCancellableRepositoryOperation<T: Sendable>(
    _ operation: String,
    on store: ClipKittyRust.ClipboardStore,
    body: @escaping @Sendable (ClipKittyRust.ClipboardStore) throws -> T
) async -> Result<T, ClipboardError> {
    let task = Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        let result = try body(store)
        try Task.checkCancellation()
        return result
    }

    do {
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        return .success(result)
    } catch {
        return .failure(.databaseOperationFailed(operation: operation, underlying: error))
    }
}

public final class ClipboardRepository: @unchecked Sendable {
    public let store: ClipKittyRust.ClipboardStore

    public init(store: ClipKittyRust.ClipboardStore) {
        self.store = store
    }

    public func databaseSize() async -> Result<Int64, ClipboardError> {
        await runRepositoryOperation("databaseSize", on: store) { $0.databaseSize() }
    }

    public func startSearch(query: String, filter: ItemQueryFilter, presentation: ListPresentationProfile) -> ClipboardSearchOperation {
        let operation = store.startSearch(query: query, filter: filter, presentation: presentation)
        return RustClipboardSearchOperation(operation: operation)
    }

    public func search(query: String, filter: ItemQueryFilter, presentation: ListPresentationProfile) async -> RepositorySearchOutcome {
        await startSearch(query: query, filter: filter, presentation: presentation).awaitOutcome()
    }

    public func fetchItem(id: String) async -> ClipboardItem? {
        let result = await fetchItems(ids: [id])
        if case let .success(items) = result {
            return items.first
        }
        return nil
    }

    /// Fetches clips in the caller's requested order with one store read.
    ///
    /// Unlike ``fetchItem(id:)``, this keeps database failures distinct from
    /// missing item identifiers. Bulk UI actions use that distinction to
    /// avoid replacing the system clipboard with only a partial selection.
    public func fetchItems(ids: [String]) async -> Result<[ClipboardItem], ClipboardError> {
        guard !ids.isEmpty else { return .success([]) }
        return await runRepositoryOperation("fetchItems", on: store) { store in
            try store.fetchByIds(itemIds: ids)
        }
    }

    /// Fetches a bounded, complete transfer batch in requested order.
    ///
    /// Rust rejects more than 50 IDs, duplicates, missing clips, text payloads
    /// over 10 MiB, image payloads over 50 MiB, and aggregate payloads over
    /// 50 MiB before hydrating any accepted database payload.
    public func fetchTransferItems(ids: [String]) async -> RepositoryTransferFetchOutcome {
        guard !ids.isEmpty else { return .success([]) }
        let result = await runCancellableRepositoryOperation(
            "fetchTransferItems",
            on: store
        ) { store in
            try store.fetchItemsForTransfer(itemIds: ids)
        }
        switch result {
        case let .success(.success(items)):
            return .success(items)
        case let .success(.rejected(reason)):
            return .rejected(reason)
        case let .failure(error):
            if case let .databaseOperationFailed(_, underlying) = error,
               underlying is CancellationError
            {
                return .cancelled
            }
            return .failure(error)
        }
    }

    /// Single-item bounded lookup for lazy drag item providers.
    public func fetchTransferItem(id: String) async -> ClipboardItem? {
        let outcome = await fetchTransferItems(ids: [id])
        if case let .success(items) = outcome {
            return items.first
        }
        return nil
    }

    public func resolveMatchedExcerpts(requests: [MatchedExcerptRequest]) async -> [MatchedExcerptResolution] {
        let result = await runRepositoryOperation("resolveMatchedExcerpts", on: store) { store in
            try store.resolveMatchedExcerpts(requests: requests)
        }
        if case let .success(resolutions) = result {
            return resolutions
        }
        return []
    }

    public func loadPreviewPayload(itemId: String, query: String) async -> PreviewPayload? {
        let result = await runRepositoryOperation("loadPreviewPayload", on: store) { store in
            try store.loadPreviewPayload(itemId: itemId, query: query)
        }
        if case let .success(payload) = result {
            return payload
        }
        return nil
    }

    public func saveText(
        text: String,
        sourceApp: String?,
        sourceAppBundleId: String?
    ) async -> Result<String, ClipboardError> {
        await runRepositoryOperation("saveText", on: store) { store in
            try store.saveText(
                text: text,
                sourceApp: sourceApp,
                sourceAppBundleId: sourceAppBundleId
            )
        }
    }

    public func saveImage(
        imageData: Data,
        thumbnail: Data?,
        sourceApp: String?,
        sourceAppBundleId: String?,
        isAnimated: Bool
    ) async -> Result<String, ClipboardError> {
        await runRepositoryOperation("saveImage", on: store) { store in
            try store.saveImage(
                imageData: imageData,
                thumbnail: thumbnail,
                sourceApp: sourceApp,
                sourceAppBundleId: sourceAppBundleId,
                isAnimated: isAnimated
            )
        }
    }

    public func saveFiles(
        files: [NewFileInput],
        sourceApp: String?,
        sourceAppBundleId: String?
    ) async -> Result<String, ClipboardError> {
        await runRepositoryOperation("saveFiles", on: store) { store in
            try store.saveFiles(
                files: files,
                sourceApp: sourceApp,
                sourceAppBundleId: sourceAppBundleId
            )
        }
    }

    public func updateTextItem(itemId: String, text: String) async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("updateTextItem", on: store) { store in
            try store.updateTextItem(itemId: itemId, text: text)
        }
    }

    public func updateLinkMetadata(
        itemId: String,
        title: String?,
        description: String?,
        imageData: Data?
    ) async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("updateLinkMetadata", on: store) { store in
            try store.updateLinkMetadata(
                itemId: itemId,
                title: title,
                description: description,
                imageData: imageData
            )
        }
    }

    public func updateImageDescription(itemId: String, description: String) async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("updateImageDescription", on: store) { store in
            try store.updateImageDescription(itemId: itemId, description: description)
        }
    }

    public func updateTimestamp(itemId: String) async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("updateTimestamp", on: store) { store in
            try store.updateTimestamp(itemId: itemId)
        }
    }

    public func addTag(itemId: String, tag: ItemTag) async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("addTag", on: store) { store in
            try store.addTag(itemId: itemId, tag: tag)
        }
    }

    public func removeTag(itemId: String, tag: ItemTag) async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("removeTag", on: store) { store in
            try store.removeTag(itemId: itemId, tag: tag)
        }
    }

    public func delete(itemId: String) async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("deleteItem", on: store) { store in
            try store.deleteItem(itemId: itemId)
        }
    }

    public func clear() async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("clear", on: store) { store in
            try store.clear()
        }
    }

    /// Prune oldest items until the database fits within `maxBytes`. When
    /// over the limit, prunes down to `keepRatio` of it so the store isn't
    /// re-pruned on every new item.
    public func pruneToSize(maxBytes: Int64, keepRatio: Double = 0.8) async -> Result<UInt64, ClipboardError> {
        await runRepositoryOperation("pruneToSize", on: store) { store in
            try store.pruneToSize(maxBytes: maxBytes, keepRatio: keepRatio)
        }
    }
}
