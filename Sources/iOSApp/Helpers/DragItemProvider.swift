import ClipKittyRust
import UIKit
import UniformTypeIdentifiers

enum DragItemProvider {
    /// Type identifier registered on every card drag, visible only within
    /// this process, so the window's drop-to-add target
    /// (`AddClipDropTarget`) can recognize ClipKitty's own drags and ignore
    /// them: re-dropping an existing clip onto the feed must not duplicate
    /// it. Deliberately undeclared as a UTType — receivers match it by exact
    /// identifier, never by conformance.
    static let internalDragMarker = "com.eviljuliette.clipkitty.internal-drag"

    /// Lightweight content metadata used to advertise only representations
    /// the stored clip can actually provide. No full payload is hydrated to
    /// determine this value.
    enum ContentKind: Equatable {
        case text
        case color
        case link
        case image
        case file
        case unknown

        init(icon: ItemIcon) {
            switch icon {
            case let .symbol(iconType):
                switch iconType {
                case .text: self = .text
                case .color: self = .color
                case .link: self = .link
                case .image: self = .image
                case .file: self = .file
                }
            case .colorSwatch:
                self = .color
            case .thumbnail:
                self = .image
            }
        }
    }

    /// Bounds all work owned by one UIKit drag session. The item limit is
    /// applied before `NSItemProvider` creation by `ExternalCopyDragPayload`;
    /// the byte and concurrency limits are shared by every provider in it.
    struct SessionPolicy: Equatable {
        static let externalDrag = SessionPolicy(
            maximumItemCount: iOSTransferLimits.maximumItemCount,
            maximumTransferByteCount: iOSTransferLimits.maximumAggregateByteCount,
            maximumConcurrentLoads: 2
        )

        let maximumItemCount: Int
        let maximumTransferByteCount: Int
        let maximumConcurrentLoads: Int

        init(
            maximumItemCount: Int,
            maximumTransferByteCount: Int,
            maximumConcurrentLoads: Int
        ) {
            self.maximumItemCount = max(0, maximumItemCount)
            self.maximumTransferByteCount = max(0, maximumTransferByteCount)
            self.maximumConcurrentLoads = max(1, maximumConcurrentLoads)
        }
    }

    enum LoadError: LocalizedError, Equatable {
        case cancelled
        case unavailable(typeIdentifier: String)
        case transferBudgetExceeded

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "The drag transfer was cancelled."
            case let .unavailable(typeIdentifier):
                return "No data is available for \(typeIdentifier)."
            case .transferBudgetExceeded:
                return "The drag transfer exceeds the session size limit."
            }
        }
    }

    /// One coordinator is retained by an `ExternalCopyDragPayload`. It
    /// memoizes one store fetch per item, admits at most two public
    /// representation loaders at once, and accounts delivered bytes against
    /// one session-wide budget.
    final class TransferSession: @unchecked Sendable {
        let policy: SessionPolicy

        private let cancellation = CancellationFlag()
        private let state: TransferState

        init(
            policy: SessionPolicy = .externalDrag,
            _onWaiterDequeued: (@Sendable () -> Void)? = nil
        ) {
            self.policy = policy
            state = TransferState(
                policy: policy,
                cancellation: cancellation,
                onWaiterDequeued: _onWaiterDequeued
            )
        }

        func loadRepresentation(
            itemID: String,
            typeIdentifier: String,
            fetch: @escaping @Sendable (String) async -> ClipboardItem?,
            extract: @escaping @Sendable (ClipboardItem) -> Data?
        ) async throws -> Data {
            try await state.loadRepresentation(
                itemID: itemID,
                typeIdentifier: typeIdentifier,
                fetch: fetch,
                extract: extract
            )
        }

        /// Marks cancellation synchronously so newly-starting loads fail
        /// closed, then wakes queued loads and cancels memoized fetch tasks.
        func cancel() {
            cancellation.cancel()
            Task {
                await state.requestCancellation()
            }
        }

        /// Deterministic cancellation hook used by tests and callers already
        /// running in an async teardown path. This does not return until every
        /// memoized repository fetch that was admitted before cancellation has
        /// actually settled, so a terminal store drain cannot race it.
        func cancelAndWait() async {
            cancellation.cancel()
            let fetchTasks = await state.cancelAll()
            for task in fetchTasks {
                _ = await task.value
            }
        }

        func snapshot() async -> TransferSnapshot {
            await state.snapshot()
        }
    }

    struct TransferSnapshot: Equatable {
        let transferredByteCount: Int
        let memoizedItemCount: Int
        let activeLoadCount: Int
        let queuedLoadCount: Int
        let pendingCancelledWaiterCount: Int
        let maximumObservedConcurrentLoads: Int
        let isCancelled: Bool
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.withLock { cancelled }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
            }
        }
    }

    private actor TransferState {
        private struct Waiter {
            let id: UUID
            let cancellation: CancellationFlag
            let continuation: CheckedContinuation<Void, Error>
        }

        private let policy: SessionPolicy
        private let cancellation: CancellationFlag
        private let onWaiterDequeued: (@Sendable () -> Void)?

        private var transferredByteCount = 0
        private var activeLoadCount = 0
        private var maximumObservedConcurrentLoads = 0
        private var fetchTasks: [String: Task<ClipboardItem?, Never>] = [:]
        private var accountedItemIDs: Set<String> = []
        private var waiters: [Waiter] = []

        init(
            policy: SessionPolicy,
            cancellation: CancellationFlag,
            onWaiterDequeued: (@Sendable () -> Void)?
        ) {
            self.policy = policy
            self.cancellation = cancellation
            self.onWaiterDequeued = onWaiterDequeued
        }

        func loadRepresentation(
            itemID: String,
            typeIdentifier: String,
            fetch: @escaping @Sendable (String) async -> ClipboardItem?,
            extract: @escaping @Sendable (ClipboardItem) -> Data?
        ) async throws -> Data {
            try await acquireLoadPermit()
            defer { releaseLoadPermit() }

            try checkCancellation()

            let fetchTask: Task<ClipboardItem?, Never>
            if let memoized = fetchTasks[itemID] {
                fetchTask = memoized
            } else {
                let task = Task.detached(priority: .userInitiated) {
                    await fetch(itemID)
                }
                fetchTasks[itemID] = task
                fetchTask = task
            }

            // A destination may keep probing providers after the shared byte
            // budget is exhausted. Do not let rejected or cancelled probes
            // accumulate their fully hydrated items in the memoization table.
            // A concurrent representation that succeeds restores the shared
            // task below, preserving one-fetch memoization for admitted items.
            var shouldDiscardUnaccountedFetch = true
            defer {
                if shouldDiscardUnaccountedFetch,
                   !accountedItemIDs.contains(itemID)
                {
                    fetchTasks.removeValue(forKey: itemID)
                }
            }

            guard let item = await fetchTask.value else {
                try checkCancellation()
                throw LoadError.unavailable(typeIdentifier: typeIdentifier)
            }
            try checkCancellation()
            guard item.itemMetadata.itemId == itemID else {
                throw LoadError.unavailable(typeIdentifier: typeIdentifier)
            }

            let itemPayloadByteCount: Int
            switch DragItemProvider.materializedPayloadByteCount(item.content) {
            case let .success(byteCount):
                itemPayloadByteCount = byteCount
            case .failure(.unsupported):
                throw LoadError.unavailable(typeIdentifier: typeIdentifier)
            case .failure:
                throw LoadError.transferBudgetExceeded
            }

            guard let data = extract(item) else {
                throw LoadError.unavailable(typeIdentifier: typeIdentifier)
            }
            try checkCancellation()

            // Account the stored payload once per item, not once per fallback
            // UTI or receiver retry. That keeps the budget deterministic while
            // the memoized fetch/data remains bounded by the same source clip.
            if accountedItemIDs.insert(itemID).inserted {
                let remainingBytes = policy.maximumTransferByteCount - transferredByteCount
                guard itemPayloadByteCount <= remainingBytes else {
                    accountedItemIDs.remove(itemID)
                    throw LoadError.transferBudgetExceeded
                }
                transferredByteCount += itemPayloadByteCount
            }
            fetchTasks[itemID] = fetchTask
            shouldDiscardUnaccountedFetch = false
            return data
        }

        func cancelAll() -> [Task<ClipboardItem?, Never>] {
            requestCancellation()
            let cancelledFetchTasks = Array(fetchTasks.values)
            fetchTasks.removeAll(keepingCapacity: false)
            return cancelledFetchTasks
        }

        /// Cancels admitted work but deliberately retains memoized task handles
        /// until `cancelAll()` can join them. A fire-and-forget cancellation is
        /// used while an external destination is still unwinding; dropping the
        /// handles here would let a later terminal drain miss an in-flight
        /// repository read.
        func requestCancellation() {
            fetchTasks.values.forEach { $0.cancel() }
            let queuedWaiters = waiters
            waiters.removeAll(keepingCapacity: false)
            queuedWaiters.forEach { $0.continuation.resume(throwing: LoadError.cancelled) }
        }

        func snapshot() -> TransferSnapshot {
            TransferSnapshot(
                transferredByteCount: transferredByteCount,
                memoizedItemCount: fetchTasks.count,
                activeLoadCount: activeLoadCount,
                queuedLoadCount: waiters.count,
                pendingCancelledWaiterCount: waiters.lazy.filter {
                    $0.cancellation.isCancelled
                }.count,
                maximumObservedConcurrentLoads: maximumObservedConcurrentLoads,
                isCancelled: cancellation.isCancelled
            )
        }

        private func acquireLoadPermit() async throws {
            try checkCancellation()

            if activeLoadCount < policy.maximumConcurrentLoads {
                activeLoadCount += 1
                maximumObservedConcurrentLoads = max(
                    maximumObservedConcurrentLoads,
                    activeLoadCount
                )
                return
            }

            let waiterID = UUID()
            let waiterCancellation = CancellationFlag()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    if cancellation.isCancelled || Task.isCancelled
                        || waiterCancellation.isCancelled
                    {
                        continuation.resume(throwing: LoadError.cancelled)
                    } else {
                        waiters.append(
                            Waiter(
                                id: waiterID,
                                cancellation: waiterCancellation,
                                continuation: continuation
                            )
                        )
                    }
                }
            } onCancel: {
                // This synchronous flag closes the cancellation-before-enqueue
                // race without retaining an orphan UUID in actor state.
                waiterCancellation.cancel()
                Task {
                    await self.cancelWaiter(id: waiterID)
                }
            }

            do {
                try checkCancellation()
            } catch {
                // The continuation may already have been resumed with a
                // handed-off permit when cancellation wins the race. Return
                // that permit before propagating the cancellation.
                releaseLoadPermit()
                throw error
            }
        }

        private func cancelWaiter(id: UUID) {
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                let waiter = waiters.remove(at: index)
                waiter.continuation.resume(throwing: LoadError.cancelled)
            }
        }

        private func releaseLoadPermit() {
            while !waiters.isEmpty {
                let next = waiters.removeFirst()
                onWaiterDequeued?()
                if next.cancellation.isCancelled {
                    next.continuation.resume(throwing: LoadError.cancelled)
                    continue
                }

                // Hand the existing permit directly to the next waiter. The
                // active count stays unchanged until that load releases it.
                next.continuation.resume()
                return
            }

            activeLoadCount = max(0, activeLoadCount - 1)
        }

        private func checkCancellation() throws {
            if cancellation.isCancelled || Task.isCancelled {
                throw LoadError.cancelled
            }
        }
    }

    /// Builds an `NSItemProvider` that lazily fetches the full clipboard item
    /// by id when a drop target requests the data. Every provider in a payload
    /// must receive the same `TransferSession` so its budgets are session-wide.
    @MainActor
    static func make(
        itemId: String,
        contentKind: ContentKind = .unknown,
        transferSession: TransferSession = TransferSession(),
        fetch: @escaping @Sendable (String) async -> ClipboardItem?,
        onRepresentationLoad: @escaping @Sendable (Bool) -> Void = { _ in }
    ) -> NSItemProvider {
        let provider = NSItemProvider()

        provider.registerDataRepresentation(
            forTypeIdentifier: internalDragMarker,
            visibility: .ownProcess
        ) { completion in
            completion(Data(), nil)
            return nil
        }

        // Text is the primary representation for text, colors, and filenames,
        // and an intentional fallback for links and image descriptions.
        if contentKind.supportsTextRepresentation {
            for type in [UTType.plainText, .utf8PlainText] {
                register(
                    provider,
                    type: type,
                    itemId: itemId,
                    transferSession: transferSession,
                    fetch: fetch,
                    onRepresentationLoad: onRepresentationLoad
                ) { item in
                    Self.textRepresentationData(
                        from: item,
                        expectedContentKind: contentKind
                    )
                }
            }
        }

        if contentKind.supportsURLRepresentation {
            register(
                provider,
                type: .url,
                itemId: itemId,
                transferSession: transferSession,
                fetch: fetch,
                onRepresentationLoad: onRepresentationLoad
            ) { item in
                Self.urlRepresentationData(
                    from: item,
                    expectedContentKind: contentKind
                )
            }
        }

        if contentKind.supportsImageRepresentation {
            // The concrete image UTI is unavailable until the lazy store
            // fetch. `public.image` truthfully describes every native subtype;
            // returning original ImageIO-validated bytes preserves JPEG, GIF,
            // HEIF, APNG, and WebP without transcoding.
            register(
                provider,
                type: .image,
                itemId: itemId,
                transferSession: transferSession,
                fetch: fetch,
                onRepresentationLoad: onRepresentationLoad
            ) { item in
                guard contentKind == .image || contentKind == .unknown,
                      case let .image(data, _, _) = item.content,
                      Self.nativeImageTypeIdentifier(for: data) != nil
                else { return nil }
                return data
            }
        }

        return provider
    }

    static func nativeImageTypeIdentifier(for data: Data) -> String? {
        TransferImageValidator.nativeTypeIdentifier(for: data)
    }

    static func textRepresentationData(
        from item: ClipboardItem,
        expectedContentKind: ContentKind
    ) -> Data? {
        let value: String
        switch (expectedContentKind, item.content) {
        case let (.text, .text(text)):
            value = text
        case let (.color, .color(color)):
            value = color
        case let (.link, .link(url, _)):
            value = url
        case let (.image, .image(_, description, _)):
            value = description
        case let (.file, .file(displayName, files)):
            value = files.first?.filename ?? displayName
        case let (.unknown, .text(text)):
            value = text
        case let (.unknown, .color(color)):
            value = color
        case let (.unknown, .link(url, _)):
            value = url
        case let (.unknown, .image(_, description, _)):
            value = description
        case let (.unknown, .file(displayName, files)):
            value = files.first?.filename ?? displayName
        default:
            return nil
        }

        guard !value.isEmpty, let data = value.data(using: .utf8), !data.isEmpty else {
            return nil
        }
        return data
    }

    static func urlRepresentationData(
        from item: ClipboardItem,
        expectedContentKind: ContentKind
    ) -> Data? {
        guard expectedContentKind == .link || expectedContentKind == .unknown,
              case let .link(url, _) = item.content,
              let linkURL = URL(string: url),
              linkURL.scheme != nil
        else { return nil }
        return try? NSKeyedArchiver.archivedData(
            withRootObject: linkURL,
            requiringSecureCoding: true
        )
    }

    /// Bytes retained by the transfer session after one bounded store fetch.
    ///
    /// Image clips carry both their native image bytes and a UTF-8 description;
    /// links carry both UTF-8 text and a secure-coded URL representation. Every
    /// distinct payload that can be retained or transferred participates in the
    /// shared session budget even when the destination asks for only one of the
    /// advertised representations.
    static func materializedPayloadByteCount(
        _ content: ClipboardContent
    ) -> Result<Int, iOSTransferLimits.Rejection> {
        switch content {
        case let .image(data, description, _):
            guard data.count <= iOSTransferLimits.maximumImageByteCount else {
                return .failure(.itemTooLarge)
            }
            let descriptionByteCount = description.utf8.count
            guard descriptionByteCount <= iOSTransferLimits.maximumTextByteCount else {
                return .failure(.itemTooLarge)
            }
            return iOSTransferLimits.adding(data.count, to: descriptionByteCount)

        case let .link(url, _):
            guard case let .success(textByteCount) = iOSTransferLimits.payloadByteCount(content)
            else { return .failure(.itemTooLarge) }
            guard let linkURL = URL(string: url),
                  linkURL.scheme != nil
            else {
                // An invalid stored link is still transferred as plain text.
                return .success(textByteCount)
            }
            guard let archivedURL = try? NSKeyedArchiver.archivedData(
                withRootObject: linkURL,
                requiringSecureCoding: true
            ) else {
                // If secure coding fails, the URL representation is unavailable
                // and only the valid text fallback can be retained or sent.
                return .success(textByteCount)
            }
            guard archivedURL.count <= iOSTransferLimits.maximumTextByteCount else {
                return .failure(.itemTooLarge)
            }
            return iOSTransferLimits.adding(archivedURL.count, to: textByteCount)

        case .text, .color, .file:
            return iOSTransferLimits.payloadByteCount(content)
        }
    }

    private static func register(
        _ provider: NSItemProvider,
        type: UTType,
        itemId: String,
        transferSession: TransferSession,
        fetch: @escaping @Sendable (String) async -> ClipboardItem?,
        onRepresentationLoad: @escaping @Sendable (Bool) -> Void,
        extract: @escaping @Sendable (ClipboardItem) -> Data?
    ) {
        provider.registerDataRepresentation(
            forTypeIdentifier: type.identifier,
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let data = try await transferSession.loadRepresentation(
                        itemID: itemId,
                        typeIdentifier: type.identifier,
                        fetch: fetch,
                        extract: extract
                    )
                    try Task.checkCancellation()
                    guard !progress.isCancelled else {
                        throw LoadError.cancelled
                    }

                    onRepresentationLoad(true)
                    progress.completedUnitCount = 1
                    completion(data, nil)
                } catch {
                    onRepresentationLoad(false)
                    completion(nil, error)
                }
            }
            progress.cancellationHandler = {
                task.cancel()
            }
            return progress
        }
    }
}

private extension DragItemProvider.ContentKind {
    var supportsTextRepresentation: Bool {
        switch self {
        case .text, .color, .link, .image, .file, .unknown:
            return true
        }
    }

    var supportsURLRepresentation: Bool {
        self == .link || self == .unknown
    }

    var supportsImageRepresentation: Bool {
        self == .image || self == .unknown
    }
}
