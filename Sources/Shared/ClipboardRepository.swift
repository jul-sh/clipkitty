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

/// Fails deferred-store operations once their pending open has been revoked
/// (the owning session suspended before the store finished opening).
public struct StoreUnavailableError: Error {}

/// Thread-safe handle for a store that a warm-booted session is still opening.
/// Repository operations await it instead of failing during the brief open
/// window; revocation resolves every waiter so suspension can never strand a
/// joined task behind an open that will not complete.
public final class DeferredStoreHandle: @unchecked Sendable {
    private enum State {
        case pending([CheckedContinuation<ClipKittyRust.ClipboardStore?, Never>])
        case available(ClipKittyRust.ClipboardStore)
        case revoked
    }

    private let lock = NSLock()
    private var state: State = .pending([])

    public init() {}

    /// The open store, or nil while the open is pending or after revocation.
    public var availableStore: ClipKittyRust.ClipboardStore? {
        lock.lock()
        defer { lock.unlock() }
        if case let .available(store) = state { return store }
        return nil
    }

    /// Waits for the open to resolve. Returns nil once the handle is revoked.
    public func awaitStore() async -> ClipKittyRust.ClipboardStore? {
        await withCheckedContinuation { continuation in
            lock.lock()
            switch state {
            case var .pending(waiters):
                waiters.append(continuation)
                state = .pending(waiters)
                lock.unlock()
            case let .available(store):
                lock.unlock()
                continuation.resume(returning: store)
            case .revoked:
                lock.unlock()
                continuation.resume(returning: nil)
            }
        }
    }

    public func fulfill(_ store: ClipKittyRust.ClipboardStore) {
        let waiters: [CheckedContinuation<ClipKittyRust.ClipboardStore?, Never>]
        lock.lock()
        switch state {
        case let .pending(pendingWaiters):
            waiters = pendingWaiters
            state = .available(store)
        case .revoked:
            // The owning session was retired while its open was in flight.
            // The store's lifecycle is governed by the open gate's drain;
            // this handle stays unavailable.
            waiters = []
        case .available:
            lock.unlock()
            preconditionFailure("deferred store fulfilled more than once")
        }
        lock.unlock()

        for waiter in waiters {
            waiter.resume(returning: store)
        }
    }

    public func revoke() {
        let waiters: [CheckedContinuation<ClipKittyRust.ClipboardStore?, Never>]
        lock.lock()
        switch state {
        case let .pending(pendingWaiters):
            waiters = pendingWaiters
        case .available, .revoked:
            waiters = []
        }
        state = .revoked
        lock.unlock()

        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }
}

/// Defers search admission until a pending store open resolves, while keeping
/// the operation cancellable from any thread during the wait.
private final class DeferredClipboardSearchOperation: ClipboardSearchOperation, @unchecked Sendable {
    private enum State {
        case waiting
        case cancelledWhileWaiting
        case running(ClipKittyRust.SearchOperation)
        case finished
    }

    private let handle: DeferredStoreHandle
    private let query: String
    private let filter: ItemQueryFilter
    private let presentation: ListPresentationProfile
    private let lock = NSLock()
    private var state: State = .waiting

    init(
        handle: DeferredStoreHandle,
        query: String,
        filter: ItemQueryFilter,
        presentation: ListPresentationProfile
    ) {
        self.handle = handle
        self.query = query
        self.filter = filter
        self.presentation = presentation
    }

    func cancel() {
        lock.lock()
        switch state {
        case .waiting:
            state = .cancelledWhileWaiting
            lock.unlock()
        case let .running(operation):
            lock.unlock()
            operation.cancel()
        case .cancelledWhileWaiting, .finished:
            lock.unlock()
        }
    }

    func awaitOutcome() async -> RepositorySearchOutcome {
        guard let store = await handle.awaitStore() else {
            lock.lock()
            state = .finished
            lock.unlock()
            return .cancelled
        }

        lock.lock()
        switch state {
        case .cancelledWhileWaiting:
            state = .finished
            lock.unlock()
            return .cancelled
        case .waiting:
            let operation = store.startSearch(
                query: query,
                filter: filter,
                presentation: presentation
            )
            state = .running(operation)
            lock.unlock()
            let outcome = await RustClipboardSearchOperation(operation: operation).awaitOutcome()
            lock.lock()
            state = .finished
            lock.unlock()
            return outcome
        case .running, .finished:
            lock.unlock()
            preconditionFailure("deferred search awaited more than once")
        }
    }
}

public final class ClipboardRepository: @unchecked Sendable {
    private enum StoreAccess: @unchecked Sendable {
        case immediate(ClipKittyRust.ClipboardStore)
        case deferred(DeferredStoreHandle)
    }

    private let access: StoreAccess

    public init(store: ClipKittyRust.ClipboardStore) {
        access = .immediate(store)
    }

    /// A repository whose store is still opening. Operations await the open
    /// and fail (or report cancellation) once the handle is revoked.
    public init(deferredStore handle: DeferredStoreHandle) {
        access = .deferred(handle)
    }

    /// The open store, or nil while a deferred open is pending or revoked.
    public var store: ClipKittyRust.ClipboardStore? {
        switch access {
        case let .immediate(store):
            return store
        case let .deferred(handle):
            return handle.availableStore
        }
    }

    private func resolveStore() async -> ClipKittyRust.ClipboardStore? {
        switch access {
        case let .immediate(store):
            return store
        case let .deferred(handle):
            return await handle.awaitStore()
        }
    }

    private func run<T: Sendable>(
        _ operation: String,
        body: @escaping @Sendable (ClipKittyRust.ClipboardStore) throws -> T
    ) async -> Result<T, ClipboardError> {
        guard let store = await resolveStore() else {
            return .failure(.databaseOperationFailed(
                operation: operation,
                underlying: StoreUnavailableError()
            ))
        }
        return await runRepositoryOperation(operation, on: store, body: body)
    }

    private func runCancellable<T: Sendable>(
        _ operation: String,
        body: @escaping @Sendable (ClipKittyRust.ClipboardStore) throws -> T
    ) async -> Result<T, ClipboardError> {
        guard let store = await resolveStore() else {
            return .failure(.databaseOperationFailed(
                operation: operation,
                underlying: StoreUnavailableError()
            ))
        }
        return await runCancellableRepositoryOperation(operation, on: store, body: body)
    }

    public func databaseSize() async -> Result<Int64, ClipboardError> {
        await run("databaseSize") { $0.databaseSize() }
    }

    public func startSearch(query: String, filter: ItemQueryFilter, presentation: ListPresentationProfile) -> ClipboardSearchOperation {
        if let store {
            return RustClipboardSearchOperation(
                operation: store.startSearch(query: query, filter: filter, presentation: presentation)
            )
        }
        guard case let .deferred(handle) = access else {
            preconditionFailure("immediate repository lost its store")
        }
        return DeferredClipboardSearchOperation(
            handle: handle,
            query: query,
            filter: filter,
            presentation: presentation
        )
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
        return await run("fetchItems") { store in
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
        let result = await runCancellable("fetchTransferItems") { store in
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
        let result = await run("resolveMatchedExcerpts") { store in
            try store.resolveMatchedExcerpts(requests: requests)
        }
        if case let .success(resolutions) = result {
            return resolutions
        }
        return []
    }

    public func loadPreviewPayload(itemId: String, query: String) async -> PreviewPayload? {
        let result = await run("loadPreviewPayload") { store in
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
        await run("saveText") { store in
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
        await run("saveImage") { store in
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
        await run("saveFiles") { store in
            try store.saveFiles(
                files: files,
                sourceApp: sourceApp,
                sourceAppBundleId: sourceAppBundleId
            )
        }
    }

    public func updateTextItem(itemId: String, text: String) async -> Result<Void, ClipboardError> {
        await run("updateTextItem") { store in
            try store.updateTextItem(itemId: itemId, text: text)
        }
    }

    public func updateLinkMetadata(
        itemId: String,
        title: String?,
        description: String?,
        imageData: Data?
    ) async -> Result<Void, ClipboardError> {
        await run("updateLinkMetadata") { store in
            try store.updateLinkMetadata(
                itemId: itemId,
                title: title,
                description: description,
                imageData: imageData
            )
        }
    }

    public func updateImageDescription(itemId: String, description: String) async -> Result<Void, ClipboardError> {
        await run("updateImageDescription") { store in
            try store.updateImageDescription(itemId: itemId, description: description)
        }
    }

    public func updateTimestamp(itemId: String) async -> Result<Void, ClipboardError> {
        await run("updateTimestamp") { store in
            try store.updateTimestamp(itemId: itemId)
        }
    }

    public func addTag(itemId: String, tag: ItemTag) async -> Result<Void, ClipboardError> {
        await run("addTag") { store in
            try store.addTag(itemId: itemId, tag: tag)
        }
    }

    public func removeTag(itemId: String, tag: ItemTag) async -> Result<Void, ClipboardError> {
        await run("removeTag") { store in
            try store.removeTag(itemId: itemId, tag: tag)
        }
    }

    public func delete(itemId: String) async -> Result<Void, ClipboardError> {
        await run("deleteItem") { store in
            try store.deleteItem(itemId: itemId)
        }
    }

    public func clear() async -> Result<Void, ClipboardError> {
        await run("clear") { store in
            try store.clear()
        }
    }

    /// Prune oldest items until the database fits within `maxBytes`. When
    /// over the limit, prunes down to `keepRatio` of it so the store isn't
    /// re-pruned on every new item.
    public func pruneToSize(maxBytes: Int64, keepRatio: Double = 0.8) async -> Result<UInt64, ClipboardError> {
        await run("pruneToSize") { store in
            try store.pruneToSize(maxBytes: maxBytes, keepRatio: keepRatio)
        }
    }
}
