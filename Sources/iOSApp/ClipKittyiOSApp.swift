import ClipKittyBrowser
import ClipKittyCore
import ClipKittyRust
import ClipKittyShortcuts
import ClipKittyStore
import SwiftUI
import UIKit

@MainActor
struct AppBackgroundTaskClient {
    let begin: (
        _ name: String,
        _ expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier
    let end: (_ identifier: UIBackgroundTaskIdentifier) -> Void

    static let live = AppBackgroundTaskClient(
        begin: { name, expirationHandler in
            UIApplication.shared.beginBackgroundTask(
                withName: name,
                expirationHandler: expirationHandler
            )
        },
        end: { identifier in
            UIApplication.shared.endBackgroundTask(identifier)
        }
    )
}

enum AppBackgroundTaskReservation {
    case granted(AppBackgroundTaskLease)
    case unavailable
}

@MainActor
final class AppBackgroundTaskLease {
    private enum State {
        case reserving
        case active(UIBackgroundTaskIdentifier)
        case ended
    }

    private enum Installation {
        case granted
        case unavailable
    }

    private var state: State = .reserving
    private let endTask: (UIBackgroundTaskIdentifier) -> Void

    private init(endTask: @escaping (UIBackgroundTaskIdentifier) -> Void) {
        self.endTask = endTask
    }

    static func acquire(
        named name: String,
        onExpiration: @escaping @MainActor @Sendable () -> Void
    ) -> AppBackgroundTaskReservation {
        acquire(
            named: name,
            client: .live,
            onExpiration: onExpiration
        )
    }

    static func acquire(
        named name: String,
        client: AppBackgroundTaskClient,
        onExpiration: @escaping @MainActor @Sendable () -> Void
    ) -> AppBackgroundTaskReservation {
        let lease = AppBackgroundTaskLease(endTask: client.end)
        let identifier = client.begin(name) { [weak lease] in
            onExpiration()
            lease?.end()
        }
        switch lease.install(identifier) {
        case .granted:
            return .granted(lease)
        case .unavailable:
            return .unavailable
        }
    }

    private func install(_ identifier: UIBackgroundTaskIdentifier) -> Installation {
        switch state {
        case .reserving:
            if identifier == .invalid {
                state = .ended
                return .unavailable
            } else {
                state = .active(identifier)
                return .granted
            }
        case .ended:
            if identifier != .invalid {
                endTask(identifier)
            }
            return .unavailable
        case .active:
            preconditionFailure("background-task identifier installed more than once")
        }
    }

    func end() {
        switch state {
        case .reserving:
            state = .ended
        case let .active(identifier):
            state = .ended
            endTask(identifier)
        case .ended:
            break
        }
    }

    isolated deinit {
        // UIKit retains its expiration closure until the reservation ends.
        // The closure captures this lease weakly, so dropping the final owner
        // can deterministically release an otherwise-abandoned reservation.
        end()
    }
}

final class AppBackgroundTaskCancellation: @unchecked Sendable {
    private enum State {
        case waiting
        case installed(@Sendable () -> Void)
        case cancelled
        case completed
    }

    private let lock = NSLock()
    private var state: State = .waiting

    func install(_ cancel: @escaping @Sendable () -> Void) {
        let action: (@Sendable () -> Void)?
        lock.lock()
        switch state {
        case .waiting:
            state = .installed(cancel)
            action = nil
        case .cancelled:
            action = cancel
        case .completed:
            action = nil
        case .installed:
            preconditionFailure("background cancellation installed more than once")
        }
        lock.unlock()
        action?()
    }

    func cancel() {
        let action: (@Sendable () -> Void)?
        lock.lock()
        switch state {
        case .waiting:
            state = .cancelled
            action = nil
        case let .installed(cancel):
            state = .cancelled
            action = cancel
        case .cancelled:
            action = nil
        case .completed:
            action = nil
        }
        lock.unlock()
        action?()
    }

    /// Clears an installed cancellation action after its work has completed.
    /// This also breaks any task/lifetime retention chain owned by that action.
    func complete() {
        lock.lock()
        state = .completed
        lock.unlock()
    }
}

/// A small async latch used to make foreground-owned work joinable from the
/// terminal suspension path without retaining the UI object that owns it.
final class AppSessionWorkCompletion: @unchecked Sendable {
    private enum State {
        case pending([CheckedContinuation<Void, Never>])
        case finished
    }

    private let lock = NSLock()
    private var state: State = .pending([])

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            switch state {
            case var .pending(waiters):
                waiters.append(continuation)
                state = .pending(waiters)
                lock.unlock()
            case .finished:
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func finish() {
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        switch state {
        case let .pending(pendingWaiters):
            waiters = pendingWaiters
            state = .finished
        case .finished:
            waiters = []
        }
        lock.unlock()

        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// Bridges the possible synchronous-expiration edge of
/// `beginBackgroundTask` to a lease that is created only after UIKit returns a
/// valid identifier.
@MainActor
private final class AppExternalTransferExpirationRelay {
    private var didExpire = false
    private var handler: (@MainActor @Sendable () -> Void)?

    func install(_ handler: @escaping @MainActor @Sendable () -> Void) {
        precondition(self.handler == nil, "expiration handler installed more than once")
        if didExpire {
            handler()
        } else {
            self.handler = handler
        }
    }

    func expire() {
        guard !didExpire else { return }
        didExpire = true
        let handler = handler
        self.handler = nil
        handler?()
    }
}

/// Keeps the foreground store available while UIKit lazily asks an external
/// drag source for its promised data. The lease is completed by every terminal
/// drag path and is also fail-closed by UIKit background-task expiration.
@MainActor
final class AppExternalTransferLease {
    private enum State {
        case active
        case expired
        case finished
    }

    private let id: UUID
    private let completion: AppSessionWorkCompletion
    private let backgroundLease: AppBackgroundTaskLease
    private let onFinish: @MainActor @Sendable (UUID) -> Void
    private var state = State.active
    private var expirationHandler: (@MainActor @Sendable () -> Void)?
    private var expirationRequiresCleanup = false

    fileprivate init(
        id: UUID,
        completion: AppSessionWorkCompletion,
        backgroundLease: AppBackgroundTaskLease,
        onFinish: @escaping @MainActor @Sendable (UUID) -> Void
    ) {
        self.id = id
        self.completion = completion
        self.backgroundLease = backgroundLease
        self.onFinish = onFinish
    }

    func installExpirationHandler(
        _ handler: @escaping @MainActor @Sendable () -> Void,
        requiresCleanup: Bool = false
    ) {
        switch state {
        case .active:
            precondition(expirationHandler == nil, "expiration handler installed more than once")
            expirationHandler = handler
            expirationRequiresCleanup = requiresCleanup
        case .expired, .finished:
            // Expiration can win before the drag payload finishes wiring its
            // provider cancellation. Apply the cancellation immediately.
            handler()
        }
    }

    func expire() {
        guard case .active = state else { return }
        state = .expired
        let handler = expirationHandler
        expirationHandler = nil
        // UIKit has revoked our execution reservation. End it immediately,
        // but keep the AppState latch pending: terminal store suspension must
        // still wait for the payload to cancel and join every admitted fetch.
        backgroundLease.end()
        handler?()
        // A bare lease has no payload-owned work to drain. Payload lifetimes
        // explicitly opt in to retaining the AppState latch through async
        // cleanup; this preserves the fail-closed early-expiration path before
        // a payload has finished wiring itself.
        if !expirationRequiresCleanup {
            finish()
        }
    }

    func finish() {
        if case .finished = state { return }
        state = .finished
        expirationHandler = nil
        expirationRequiresCleanup = false
        backgroundLease.end()
        completion.finish()
        onFinish(id)
    }

    isolated deinit {
        // A disappearing interaction must never strand terminal suspension if
        // UIKit tears its delegate down without another terminal callback.
        finish()
    }
}

enum AppStoreOpenStartDisposition {
    case start
    case rejected
}

enum AppStoreTransferDisposition {
    case available
    case expired
}

/// Thread-safe ownership for a store that is being opened off the main actor.
/// Expiration can seal before construction, then synchronously join the store
/// as soon as it is registered, without ever adopting a sealed instance.
final class AppStoreOpenGate: @unchecked Sendable {
    private enum State {
        case scheduled
        case opening
        case open(ClipKittyRust.ClipboardStore)
        case expiringBeforeOpen
        case expiring(ClipKittyRust.ClipboardStore)
        case draining
        case failed
        case quiescent
        case transferred
    }

    private let condition = NSCondition()
    private var state: State = .scheduled

    func begin() -> AppStoreOpenStartDisposition {
        condition.lock()
        defer { condition.unlock() }
        switch state {
        case .scheduled:
            state = .opening
            return .start
        case .quiescent:
            return .rejected
        case .opening, .open, .expiringBeforeOpen, .expiring, .draining,
             .failed, .transferred:
            preconditionFailure("store-open gate began more than once")
        }
    }

    func register(_ store: ClipKittyRust.ClipboardStore) {
        let sealImmediately: Bool
        condition.lock()
        switch state {
        case .opening:
            state = .open(store)
            sealImmediately = false
        case .expiringBeforeOpen:
            state = .expiring(store)
            sealImmediately = true
        case .scheduled, .open, .expiring, .draining, .failed, .quiescent,
             .transferred:
            preconditionFailure("store registered outside an opening attempt")
        }
        condition.broadcast()
        condition.unlock()

        if sealImmediately {
            store.beginSuspend()
        }
    }

    func completeFailure() {
        condition.lock()
        switch state {
        case .opening:
            state = .failed
        case .expiringBeforeOpen:
            state = .quiescent
        case let .open(store):
            state = .expiring(store)
        case .expiring, .draining, .failed, .quiescent:
            break
        case .scheduled, .transferred:
            preconditionFailure("store-open failure completed in an invalid state")
        }
        condition.broadcast()
        condition.unlock()
    }

    func seal() {
        let storeToSeal: ClipKittyRust.ClipboardStore?
        condition.lock()
        switch state {
        case .scheduled:
            state = .quiescent
            storeToSeal = nil
        case .opening:
            state = .expiringBeforeOpen
            storeToSeal = nil
        case let .open(store):
            state = .expiring(store)
            storeToSeal = store
        case let .expiring(store):
            storeToSeal = store
        case .expiringBeforeOpen, .draining, .failed, .quiescent, .transferred:
            storeToSeal = nil
        }
        condition.broadcast()
        condition.unlock()
        storeToSeal?.beginSuspend()
    }

    func expireAndDrain() {
        seal()

        while true {
            let storeToDrain: ClipKittyRust.ClipboardStore?
            condition.lock()
            switch state {
            case .expiringBeforeOpen, .draining:
                condition.wait()
                condition.unlock()
                continue
            case let .expiring(store), let .open(store):
                state = .draining
                storeToDrain = store
            case .scheduled, .opening:
                condition.unlock()
                preconditionFailure("sealing must resolve a scheduled or opening state")
            case .failed, .quiescent, .transferred:
                condition.unlock()
                return
            }
            condition.unlock()

            if let storeToDrain {
                storeToDrain.beginSuspend()
                storeToDrain.prepareForSuspend()
                condition.lock()
                state = .quiescent
                condition.broadcast()
                condition.unlock()
                return
            }
        }
    }

    func transfer() -> AppStoreTransferDisposition {
        condition.lock()
        defer { condition.unlock() }
        switch state {
        case .open:
            state = .transferred
            return .available
        case .expiringBeforeOpen, .expiring, .draining, .quiescent:
            return .expired
        case .scheduled, .opening, .failed, .transferred:
            preconditionFailure("store transferred before a successful open completed")
        }
    }
}

// MARK: - App Launch State

struct AppSession {
    let persistenceClaimID: UUID
    let container: AppContainer
    let appState: AppState
}

struct AppSuspensionContext {
    let id: UUID
    let session: AppSession
}

struct AppResumeContext {
    let id: UUID
    let gate: AppStoreOpenGate
    let protection: AppResumeBackgroundProtection
    let openTask: Task<Void, Never>
}

enum AppResumeBackgroundProtection {
    case granted(AppBackgroundTaskLease)
    case unavailable
}

enum AppStoreSuspensionWork {
    case protected(
        lease: AppBackgroundTaskLease,
        drain: Task<Void, Never>
    )
    case unprotected(drain: Task<Void, Never>)
}

enum AppStateSuspensionWork {
    case quiescent
    case awaiting(Task<Void, Never>)
}

private enum AppStoreOpenAttemptResult {
    case completed(Result<StoreSession, AppContainer.BootstrapError>)
    case rejected
}

enum AppResumeRetryPolicy {
    static let delaysInMilliseconds = [100, 250, 500]

    static func delay(forAttempt attempt: Int) -> Duration? {
        guard delaysInMilliseconds.indices.contains(attempt) else { return nil }
        return .milliseconds(delaysInMilliseconds[attempt])
    }
}

/// A suspended state never carries an AppSession, so it cannot retain or
/// restart a store after terminal suspension begins.
enum AppSuspendedState {
    case resting
    case waitingForSupersededResume(openTask: Task<Void, Never>)
}

enum AppResumeCallbackDisposition {
    case current(AppResumeContext)
    case superseded
}

enum AppLaunchState {
    case launching
    case ready(AppSession)
    case suspending(AppSuspensionContext)
    /// Database released. No store-bearing session survives in this state.
    case suspended(AppSuspendedState)
    /// Re-bootstrapping after a foreground activation.
    case resuming(AppResumeContext)
    case failed(String)

    func resumeCallbackDisposition(for resumeID: UUID) -> AppResumeCallbackDisposition {
        guard case let .resuming(context) = self, context.id == resumeID else {
            return .superseded
        }
        return .current(context)
    }
}

/// What the window actually renders, derived from ``AppLaunchState``. The
/// outgoing session remains visible only while its terminal drain runs; a
/// rebootstrapped session gets a fresh view-tree identity.
private enum LaunchPresentation {
    case spinner
    case session(AppSession)
    case failure(String)
}

// MARK: - App State (UI coordinator)

@MainActor
@Observable
final class AppState {
    typealias ImageDescriptionUpdate = @MainActor (String) async -> Result<Bool, ClipboardError>

    private let container: AppContainer
    private let imageDescriptionUpdate: ImageDescriptionUpdate
    let viewModel: BrowserViewModel

    var toast: ToastState = .hidden
    var contentRevision: Int = 0

    @ObservationIgnored private var isForegroundVisible = false
    @ObservationIgnored private var acceptsSessionWork = true
    @ObservationIgnored private var pasteboardMonitor: iOSPasteboardMonitor?
    @ObservationIgnored private var pendingShareTask: Task<Void, Never>?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingImageDescriptionItemIDs: [String] = []
    @ObservationIgnored private var imageDescriptionWorker: Task<Void, Never>?
    @ObservationIgnored private var foregroundTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var externalTransferTasks: [UUID: Task<Void, Never>] = [:]

    /// A transient snackbar request plus presentation identity. The request
    /// structurally owns its action only when it is actionable.
    enum ToastState {
        case hidden
        case visible(id: UUID, request: NotificationRequest)
    }

    init(
        container: AppContainer,
        imageDescriptionUpdate: ImageDescriptionUpdate? = nil
    ) {
        self.container = container
        self.imageDescriptionUpdate = imageDescriptionUpdate ?? { itemID in
            await container.imageDescriptionUpdater.update(itemId: itemID)
        }

        // Use a box to capture toast callback — wired after init via the box
        let toastBox = ToastCallbackBox()
        let clipboardCopyBox = ClipboardCopyCallbackBox()
        let clipboardService = container.clipboardService
        let settings = container.settings

        let copyItem: (String, ClipboardContent) -> Void = { _, content in
            clipboardCopyBox.copy?(content)
        }

        viewModel = BrowserViewModel(
            client: container.storeClient,
            shouldGenerateLinkPreviews: { settings.generateLinkPreviews },
            onSelect: copyItem,
            onCopyOnly: copyItem,
            onDismiss: {},
            showSnackbarNotification: { request in
                toastBox.show?(request)
            },
            dismissSnackbarNotification: {
                toastBox.dismiss?()
            }
        )

        // Wire the box to self after all stored properties are initialized
        toastBox.show = { [weak self] request in
            self?.showNotification(request)
        }
        toastBox.dismiss = { [weak self] in
            self?.dismissToast()
        }
        clipboardCopyBox.copy = { [weak self] content in
            self?.copyToPasteboard(content)
        }

        pasteboardMonitor = iOSPasteboardMonitor(
            isEnabled: { settings.autoAddFromClipboard },
            changeCount: { clipboardService.pasteboardChangeCount },
            acknowledgedChangeCount: { settings.lastIngestedPasteboardChangeCount },
            ingest: { [weak self] generation in
                guard let self else { return .handled }
                return await self.autoAddFromClipboard(generation: generation)
            }
        )
    }

    /// Prepares image copies away from the main actor and keeps the resulting
    /// pasteboard mutation scoped to this foreground store session. Text and
    /// links take the same path but skip detached preparation internally.
    func copyToPasteboard(_ content: ClipboardContent) {
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishForegroundTask(id: taskID) }

            let copied = await self.container.clipboardService.copy(content: content)
            guard !Task.isCancelled, self.acceptsSessionWork else { return }
            if copied {
                self.container.haptics.fire(.copy)
                self.showToast(.copied)
            } else {
                self.container.haptics.fire(.destructive)
                self.showToast(.addFailed(String(localized: "Could not load item")))
            }
        }
        _ = registerForegroundTask(id: taskID, task: task)
    }

    func showToast(_ message: ToastMessage) {
        showNotification(message.notificationRequest)
    }

    /// Show a shared notification request. The overlay projects its
    /// closure-free kind for rendering and matches the request to run actions.
    func showNotification(_ request: NotificationRequest) {
        let id = UUID()
        let duration = request.kind.duration
        withAnimation(.bouncy) {
            toast = .visible(id: id, request: request)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            self?.dismissToast(id: id)
        }
    }

    func dismissToast() {
        withAnimation(.bouncy) {
            toast = .hidden
        }
    }

    func dismissToast(id: UUID) {
        switch toast {
        case let .visible(currentID, _) where currentID == id:
            dismissToast()
        case .hidden, .visible:
            break
        }
    }

    func refreshFeed() {
        contentRevision += 1
        // A successful background-owned follow-up may still invalidate the
        // feed after terminal suspension revoked UI producers. Preserve that
        // revision for the next fresh/visible presentation without starting a
        // BrowserViewModel search against the outgoing store.
        guard acceptsSessionWork, isForegroundVisible else { return }
        viewModel.handlePanelVisibilityChange(true, contentRevision: contentRevision)
    }

    func restoreVisibleFeedAfterForegroundActivation() {
        viewModel.handlePanelVisibilityChange(true, contentRevision: contentRevision)
    }

    func beginForegroundActivity(runLaunchMaintenance: Bool = false) {
        guard acceptsSessionWork else { return }
        isForegroundVisible = true
        pasteboardMonitor?.sceneBecameActive()
        schedulePendingShareProcessing()
        if runLaunchMaintenance {
            scheduleLaunchMaintenance()
        }
    }

    func saveImage(
        imageData: Data,
        thumbnail: Data?,
        sourceApp: String?,
        sourceAppBundleId: String?,
        isAnimated: Bool
    ) async -> Result<String, ClipboardError> {
        let result = await container.repository.saveImage(
            imageData: imageData,
            thumbnail: thumbnail,
            sourceApp: sourceApp,
            sourceAppBundleId: sourceAppBundleId,
            isAnimated: isAnimated
        )
        // Caller cancellation can mean only that the initiating view
        // disappeared while this non-cancellable repository write committed.
        // Keep committed-image maintenance alive for the current foreground
        // session; terminal suspension independently revokes session work.
        scheduleImageDescriptionUpdate(after: result)
        return result
    }

    private func scheduleImageDescriptionUpdate(
        after result: Result<String, ClipboardError>
    ) {
        guard acceptsSessionWork,
              case let .success(itemId) = result,
              !itemId.isEmpty
        else { return }

        pendingImageDescriptionItemIDs.append(itemId)
        startImageDescriptionWorkerIfNeeded()
    }

    private func startImageDescriptionWorkerIfNeeded() {
        guard acceptsSessionWork,
              imageDescriptionWorker == nil,
              !pendingImageDescriptionItemIDs.isEmpty
        else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.imageDescriptionWorker = nil }
            await self.processImageDescriptionQueue()
        }
        imageDescriptionWorker = task
    }

    private func processImageDescriptionQueue() async {
        while acceptsSessionWork,
              !Task.isCancelled,
              !pendingImageDescriptionItemIDs.isEmpty
        {
            let itemID = pendingImageDescriptionItemIDs.removeFirst()
            let update = await imageDescriptionUpdate(itemID)
            if case .success(true) = update {
                // The repository update is authoritative even if terminal
                // cancellation became observable while it was in flight.
                // `refreshFeed()` records the revision without starting browser
                // work for an outgoing or hidden session.
                refreshFeed()
            }
            // Loop admission checks cancellation before fetching the next
            // persisted image. At most one Vision request is ever in flight.
        }
    }

    private func schedulePendingShareProcessing() {
        guard acceptsSessionWork, pendingShareTask == nil else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let added = await self.processPendingShareItems()
            self.pendingShareTask = nil
            if added > 0 {
                // Queue items were durably persisted before they were
                // acknowledged. Preserve that model invalidation even when
                // suspension cancelled the producer during its final await.
                self.refreshFeed()
            }
        }
        pendingShareTask = task
    }

    private func scheduleLaunchMaintenance() {
        guard acceptsSessionWork, maintenanceTask == nil else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.container.pruneToStorageLimit()
            // Pruning can commit after the first visible search has already
            // completed, and repository work reports its authoritative result
            // even when terminal cancellation arrived while it was in flight.
            // Preserve the invalidation in both cases; `refreshFeed()` defers
            // BrowserViewModel work when this session is no longer visible.
            self.refreshFeed()
            self.maintenanceTask = nil
        }
        maintenanceTask = task
    }

    /// Registers UI work that is valid only while this foreground session owns
    /// the store. Terminal suspension cancels and joins the exact task before
    /// store admission is sealed.
    @discardableResult
    func registerForegroundTask(id: UUID, task: Task<Void, Never>) -> Bool {
        guard acceptsSessionWork else {
            task.cancel()
            return false
        }
        precondition(foregroundTasks[id] == nil, "foreground task registered twice")
        foregroundTasks[id] = task
        return true
    }

    func finishForegroundTask(id: UUID) {
        foregroundTasks[id] = nil
    }

    /// Begins a bounded UIKit background reservation for one external drag.
    /// Its join task does not retain the returned lease, so interaction teardown
    /// can deinitialize the lease and release suspension even if UIKit omits a
    /// later callback.
    func beginExternalTransfer() -> AppExternalTransferLease? {
        beginExternalTransfer(backgroundTaskClient: .live)
    }

    func beginExternalTransfer(
        backgroundTaskClient: AppBackgroundTaskClient
    ) -> AppExternalTransferLease? {
        guard acceptsSessionWork else { return nil }

        let expirationRelay = AppExternalTransferExpirationRelay()
        let reservation = AppBackgroundTaskLease.acquire(
            named: "ClipKitty External Drag Transfer",
            client: backgroundTaskClient,
            onExpiration: {
                expirationRelay.expire()
            }
        )
        guard case let .granted(backgroundLease) = reservation,
              acceptsSessionWork
        else {
            if case let .granted(backgroundLease) = reservation {
                backgroundLease.end()
            }
            return nil
        }

        let id = UUID()
        let completion = AppSessionWorkCompletion()
        let waiter = Task {
            await completion.wait()
        }
        let lease = AppExternalTransferLease(
            id: id,
            completion: completion,
            backgroundLease: backgroundLease,
            onFinish: { [weak self] id in
                self?.externalTransferTasks[id] = nil
            }
        )
        externalTransferTasks[id] = waiter
        expirationRelay.install { [weak lease] in
            lease?.expire()
        }
        return lease
    }

    @discardableResult
    func prepareForSuspension() -> AppStateSuspensionWork {
        isForegroundVisible = false
        acceptsSessionWork = false
        var tasks: [Task<Void, Never>] = []

        switch pasteboardMonitor?.stop() ?? .quiescent {
        case .quiescent:
            break
        case let .awaiting(task):
            tasks.append(task)
        }

        if let pendingShareTask {
            pendingShareTask.cancel()
            tasks.append(pendingShareTask)
        }
        if let maintenanceTask {
            maintenanceTask.cancel()
            tasks.append(maintenanceTask)
        }
        // The FIFO stores only IDs; release all work that has not begun before
        // joining the one serial fetch/Vision worker.
        pendingImageDescriptionItemIDs.removeAll(keepingCapacity: false)
        if let imageDescriptionWorker {
            imageDescriptionWorker.cancel()
            tasks.append(imageDescriptionWorker)
        }
        for task in foregroundTasks.values {
            task.cancel()
            tasks.append(task)
        }
        // External item-provider loads are the exception to foreground-only
        // work: UIKit intentionally requests their data after a full-screen
        // cross-app drop backgrounds the source. Their own background leases
        // bound the wait and cancel providers on expiration.
        tasks.append(contentsOf: externalTransferTasks.values)

        switch viewModel.prepareForSuspension() {
        case .quiescent:
            break
        case let .awaiting(task):
            tasks.append(task)
        }

        toast = .hidden
        guard !tasks.isEmpty else { return .quiescent }
        return .awaiting(Task { @MainActor in
            for task in tasks {
                await task.value
            }
        })
    }

    func processPendingShareItems() async -> Int {
        let loadTask = Task.detached(priority: .utility) {
            PendingShareQueue.loadAll()
        }
        let pending = await withTaskCancellationHandler {
            await loadTask.value
        } onCancel: {
            loadTask.cancel()
        }
        guard !pending.isEmpty else { return 0 }

        var saved = 0
        pendingItems: for item in pending {
            guard acceptsSessionWork, !Task.isCancelled else { break }
            let sourceApp = "Share Sheet"

            let result: Result<String, ClipboardError>
            switch item.payload {
            case let .text(text):
                result = await container.repository.saveText(
                    text: text,
                    sourceApp: sourceApp,
                    sourceAppBundleId: nil
                )
            case let .url(url):
                result = await container.repository.saveText(
                    text: url,
                    sourceApp: sourceApp,
                    sourceAppBundleId: nil
                )
            case let .image(imageData, _, _):
                // App Group files are a persistence boundary, not a trust
                // boundary. Re-validate the original bytes off-main instead of
                // trusting queued thumbnail/animation metadata, including for
                // items written by older extension versions.
                guard let analysis = await PasteboardImageInspector
                    .analyzeCancellable(imageData)
                else {
                    guard acceptsSessionWork, !Task.isCancelled else {
                        break pendingItems
                    }
                    // A deterministically malformed published item can never
                    // become valid on retry. Deliberately discard it so every
                    // activation does not repeatedly parse hostile bytes.
                    await Task.detached(priority: .utility) {
                        PendingShareQueue.acknowledge(item)
                    }.value
                    continue pendingItems
                }
                guard acceptsSessionWork, !Task.isCancelled else {
                    break pendingItems
                }
                result = await saveImage(
                    imageData: imageData,
                    thumbnail: analysis.thumbnail,
                    sourceApp: sourceApp,
                    sourceAppBundleId: nil,
                    isAnimated: analysis.isAnimated
                )
            }
            if case .success = result {
                // Queue scans and full-resolution image reads/removals are file
                // I/O. Keep them off the main actor while retaining this parent
                // task so suspension can still join the exact work.
                await Task.detached(priority: .utility) {
                    PendingShareQueue.acknowledge(item)
                }.value
                saved += 1
            }
        }
        return saved
    }

    private func autoAddFromClipboard(
        generation: Int
    ) async -> iOSPasteboardIngestAttemptResult {
        guard acceptsSessionWork,
              container.settings.autoAddFromClipboard
        else { return .handled }

        let clipboardService = container.clipboardService
        guard generation != container.settings.lastIngestedPasteboardChangeCount else {
            return .handled
        }
        guard clipboardService.pasteboardChangeCount == generation else {
            return .handled
        }

        let content: AutomaticPasteboardContent
        switch await clipboardService.readCurrentClipboardForAutomaticIngest() {
        case let .content(snapshot):
            content = snapshot
        case .ignored:
            acknowledgePasteboardGeneration(generation)
            return .handled
        case .temporarilyUnavailable:
            // Do not permanently suppress a denied or lazily arriving payload.
            return .retry
        }

        // Do not associate a snapshot with the wrong generation if another app
        // rewrites the pasteboard while the value is being materialized.
        guard clipboardService.pasteboardChangeCount == generation else {
            return .handled
        }
        guard acceptsSessionWork,
              container.settings.autoAddFromClipboard,
              !Task.isCancelled
        else { return .handled }

        let result = await saveAutomaticPasteboardContent(content)
        switch result {
        case .success:
            acknowledgePasteboardGeneration(generation)
            // A settings change can cancel the monitor immediately after the
            // store commits. The exact generation is already acknowledged, so
            // always reconcile that committed item with the visible model.
            // Suspended sessions retain only the revision and start no search.
            refreshFeed()
            return .handled
        case .failure(.imageCompressionFailed):
            guard !Task.isCancelled else { return .handled }
            // The provider advertised an image UTI but supplied malformed or
            // abstract bytes. Deliberately ignore this generation rather than
            // storing a broken image or repeatedly materializing it.
            acknowledgePasteboardGeneration(generation)
            return .handled
        case .failure:
            // A fresh session or the monitor's bounded retry will try again.
            return .retry
        }
    }

    private func acknowledgePasteboardGeneration(_ generation: Int) {
        container.clipboardService.acknowledgeCurrentPasteboardGeneration(
            ifUnchangedFrom: generation
        )
    }

    private func saveAutomaticPasteboardContent(
        _ content: AutomaticPasteboardContent
    ) async -> Result<String, ClipboardError> {
        switch content {
        case let .image(data, analysis):
            return await saveImage(
                imageData: data,
                thumbnail: analysis.thumbnail,
                sourceApp: "Pasteboard",
                sourceAppBundleId: nil,
                isAnimated: analysis.isAnimated
            )
        case let .link(url):
            return await savePasteboardText(url.absoluteString)
        case let .text(text):
            return await savePasteboardText(text)
        }
    }

    func savePasteboardContent(
        _ content: PasteboardContent
    ) async -> Result<String, ClipboardError>? {
        switch content {
        case let .image(image):
            guard let data = image.pngData() else { return nil }
            let thumbnail = image.preparingThumbnail(
                of: CGSize(width: 200, height: 200)
            )?.jpegData(compressionQuality: 0.7)
            return await saveImage(
                imageData: data,
                thumbnail: thumbnail,
                sourceApp: "Pasteboard",
                sourceAppBundleId: nil,
                isAnimated: false
            )
        case let .link(url):
            return await savePasteboardText(url.absoluteString)
        case let .text(text):
            return await savePasteboardText(text)
        }
    }

    private func savePasteboardText(
        _ text: String
    ) async -> Result<String, ClipboardError> {
        await container.repository.saveText(
            text: text,
            sourceApp: "Pasteboard",
            sourceAppBundleId: nil
        )
    }
}

// MARK: - Toast Message

/// Sugar for the most common iOS-internal transient notifications. Each case
/// builds a shared `NotificationRequest` for the platform transport.
enum ToastMessage: Equatable {
    case copied
    case bookmarked
    case unbookmarked
    case addSucceeded
    case addFailed(String)
    case clipboardEmpty

    var notificationRequest: NotificationRequest {
        switch self {
        case .copied:
            return .passive(message: String(localized: "Copied to clipboard"), iconSystemName: "doc.on.doc")
        case .bookmarked:
            return .passive(message: String(localized: "Bookmarked"), iconSystemName: "bookmark.fill")
        case .unbookmarked:
            return .passive(message: String(localized: "Removed bookmark"), iconSystemName: "bookmark.slash")
        case .addSucceeded:
            return .passive(message: String(localized: "Added"), iconSystemName: "plus.circle")
        case let .addFailed(reason):
            return .passive(
                message: String(localized: "Failed: \(reason)"),
                iconSystemName: "exclamationmark.triangle"
            )
        case .clipboardEmpty:
            return .passive(
                message: String(localized: "Clipboard is empty"),
                iconSystemName: "doc.on.clipboard"
            )
        }
    }
}

/// Captures snackbar callbacks for BrowserViewModel closures that are set during init,
/// before `self` is available. BrowserViewModel stores callbacks as `private let`,
/// so they must be provided at construction time — this box bridges that gap.
@MainActor
private final class ToastCallbackBox {
    var show: ((NotificationRequest) -> Void)?
    var dismiss: (() -> Void)?
}

/// Captures the browser's synchronous copy callback until AppState is fully
/// initialized, then routes it into the cancellable async preparation path.
@MainActor
private final class ClipboardCopyCallbackBox {
    var copy: ((ClipboardContent) -> Void)?
}

// MARK: - App Entry Point

@main
struct ClipKittyiOSApp: App {
    @State private var launchState: AppLaunchState = .launching
    @State private var didScheduleLaunchMaintenance = false
    @State private var resumeRetryAttempt = 0
    /// Owned by the app rather than the container: onboarding state has to
    /// survive the container teardown that every background/foreground cycle
    /// performs, so a suspend mid-onboarding does not restart the flow.
    @State private var lifecycle = iOSLifecycleState()
    @Environment(\.scenePhase) private var scenePhase

    #if ENABLE_ICLOUD_SYNC
        @UIApplicationDelegateAdaptor(iOSAppDelegate.self) private var appDelegate
        @State private var syncCoordinator: iOSSyncCoordinator?
    #endif

    init() {
        FontManager.registerFonts()
        ClipKittyAppShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            content
                .onChange(of: scenePhase) { _, newPhase in
                    handleScenePhaseChange(newPhase)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch presentation {
        case .spinner:
            ProgressView("Loading ClipKitty...")
                .onAppear {
                    if case .launching = launchState { performBootstrap() }
                }

        case let .session(session):
            rootView(container: session.container, appState: session.appState)
                // A rebootstrapped session must start with fresh view state.
                .id(ObjectIdentifier(session.appState))

        case let .failure(message):
            bootstrapFailureView(message: message)
        }
    }

    private var presentation: LaunchPresentation {
        switch launchState {
        case .launching:
            return .spinner
        case let .ready(session):
            return .session(session)
        case let .suspending(context):
            return .session(context.session)
        case .suspended, .resuming:
            return .spinner
        case let .failed(message):
            return .failure(message)
        }
    }

    @ViewBuilder
    private func rootView(
        container: AppContainer,
        appState: AppState
    ) -> some View {
        let base = RootView()
            .environment(container)
            .environment(appState)
            .environment(appState.viewModel)
            .environment(container.settings)
            .environment(container.haptics)
            .environment(lifecycle)

        #if ENABLE_ICLOUD_SYNC
            if let coordinator = syncCoordinator {
                base
                    .environment(coordinator)
            } else {
                base
            }
        #else
            base
        #endif
    }

    private var databasePathOverride: String? {
        #if ENABLE_TEST_FIXTURES
            ProcessInfo.processInfo.environment["CLIPKITTY_SCREENSHOT_DB"]
        #else
            nil
        #endif
    }

    private func performBootstrap() {
        // Cold launch uses the same protected, off-main open as foreground
        // resume. A background transition can therefore seal bootstrap even
        // while path inspection or index construction is still in flight.
        beginResume()
    }

    /// Wires the service graph around a freshly-bootstrapped container: the
    /// shortcut runtime, the UI coordinator, and (when enabled) iCloud sync.
    private func makeSession(container: AppContainer, persistenceClaimID: UUID) -> AppSession {
        ClipKittyShortcutRuntime.useStoreProvider { [weak container] in
            guard let container else {
                return .unavailable("ClipKitty is suspended.")
            }
            return container.shortcutStoreAvailability()
        }
        let appState = AppState(container: container)
        #if ENABLE_ICLOUD_SYNC
            let coordinator = iOSSyncCoordinator(
                store: container.store,
                enabled: container.settings.syncEnabled,
                onContentChanged: { [weak appState] in
                    appState?.refreshFeed()
                }
            )
            syncCoordinator = coordinator
            iOSRemoteNotificationBridge.shared.bind(coordinator: coordinator)
            if container.settings.syncEnabled {
                coordinator.handleScenePhaseChange(.active)
            }
        #endif
        return AppSession(
            persistenceClaimID: persistenceClaimID,
            container: container,
            appState: appState
        )
    }

    /// Opens a fresh store for cold launch or after terminal suspension. A
    /// superseded open is joined first so two stores never contend for the
    /// same index path.
    private func beginResume(after supersededOpen: Task<Void, Never>? = nil) {
        guard scenePhase != .background else { return }
        let resumeID = UUID()
        let customPath = databasePathOverride
        let gate = AppStoreOpenGate()
        let protection: AppResumeBackgroundProtection
        switch AppBackgroundTaskLease.acquire(
            named: "ClipKitty Store Open",
            onExpiration: {
                // Expiration callbacks execute on the main actor. Seal admission
                // synchronously, then do every wait and Rust drain off-main.
                gate.seal()
                Task.detached(priority: .utility) {
                    gate.expireAndDrain()
                }
            }
        ) {
        case let .granted(lease):
            protection = .granted(lease)
        case .unavailable:
            protection = .unavailable
        }

        let openTask = Task { @MainActor in
            defer {
                if case let .granted(lease) = protection {
                    lease.end()
                }
            }
            #if ENABLE_ICLOUD_SYNC
                // Deny new headless opens immediately, then join any existing
                // one off-main before foreground bootstrap touches the store.
                await iOSBackgroundSyncRunner.shared.claimForegroundStore(resumeID)
            #endif
            await supersededOpen?.value

            // This resume may have been suspended or superseded while it was
            // waiting for the previous open to drain. In that case the next
            // foreground transition owns opening a fresh store.
            switch launchState.resumeCallbackDisposition(for: resumeID) {
            case .current:
                break
            case .superseded:
                #if ENABLE_ICLOUD_SYNC
                    iOSBackgroundSyncRunner.shared.releaseForegroundStore(resumeID)
                #endif
                return
            }

            let attempt = await Task.detached(priority: .userInitiated) {
                guard case .start = gate.begin() else {
                    return AppStoreOpenAttemptResult.rejected
                }
                let outcome = AppContainer.openStore(
                    databasePath: customPath,
                    didConstructStore: { gate.register($0) }
                )
                if case .failure = outcome {
                    gate.completeFailure()
                }
                return AppStoreOpenAttemptResult.completed(outcome)
            }.value
            switch attempt {
            case let .completed(outcome):
                await handleResumeOpenOutcome(
                    outcome,
                    resumeID: resumeID,
                    gate: gate
                )
            case .rejected:
                #if ENABLE_ICLOUD_SYNC
                    iOSBackgroundSyncRunner.shared.releaseForegroundStore(resumeID)
                #endif
                transitionToRestingAndScheduleResumeRetry(resumeID: resumeID)
            }
        }

        launchState = .resuming(AppResumeContext(
            id: resumeID,
            gate: gate,
            protection: protection,
            openTask: openTask
        ))
    }

    private func handleResumeOpenOutcome(
        _ outcome: Result<StoreSession, AppContainer.BootstrapError>,
        resumeID: UUID,
        gate: AppStoreOpenGate
    ) async {
        switch outcome {
        case let .success(storeSession):
            switch launchState.resumeCallbackDisposition(for: resumeID) {
            case .current:
                guard scenePhase != .background else {
                    // The environment can observe background before its
                    // onChange callback runs. `.inactive` remains visible in
                    // Slide Over and still owns foreground store authority.
                    await Task.detached(priority: .utility) {
                        gate.expireAndDrain()
                    }.value
                    #if ENABLE_ICLOUD_SYNC
                        iOSBackgroundSyncRunner.shared.releaseForegroundStore(resumeID)
                    #endif
                    launchState = .suspended(.resting)
                    return
                }
                switch gate.transfer() {
                case .available:
                    let container = AppContainer.assemble(storeSession: storeSession)
                    let session = makeSession(
                        container: container,
                        persistenceClaimID: resumeID
                    )
                    launchState = .ready(session)
                    resumeRetryAttempt = 0
                    let runLaunchMaintenance = !didScheduleLaunchMaintenance
                    didScheduleLaunchMaintenance = true
                    session.appState.beginForegroundActivity(
                        runLaunchMaintenance: runLaunchMaintenance
                    )
                case .expired:
                    // An expiration callback may still be draining this exact
                    // store. Join it before allowing a retry to open the same
                    // path, otherwise a rapid foreground transition could
                    // contend with the outgoing index/database handles.
                    await Task.detached(priority: .utility) {
                        gate.expireAndDrain()
                    }.value
                    #if ENABLE_ICLOUD_SYNC
                        iOSBackgroundSyncRunner.shared.releaseForegroundStore(resumeID)
                    #endif
                    transitionToRestingAndScheduleResumeRetry(resumeID: resumeID)
                }
            case .superseded:
                // Backgrounded or replaced mid-open: join the gate's exact
                // store before the next resume's chained open can proceed.
                await Task.detached(priority: .utility) {
                    gate.expireAndDrain()
                }.value
                #if ENABLE_ICLOUD_SYNC
                    iOSBackgroundSyncRunner.shared.releaseForegroundStore(resumeID)
                #endif
            }
        case let .failure(error):
            await Task.detached(priority: .utility) {
                gate.expireAndDrain()
            }.value
            #if ENABLE_ICLOUD_SYNC
                iOSBackgroundSyncRunner.shared.releaseForegroundStore(resumeID)
            #endif
            switch launchState.resumeCallbackDisposition(for: resumeID) {
            case .current:
                launchState = .failed(error.localizedDescription)
            case .superseded:
                break
            }
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            handleForegroundActivation()
        case .inactive:
            // iPad Slide Over can remain `.inactive` while the adjacent app
            // owns input. The session, pasteboard monitor, and visible-feed
            // refreshes therefore stay live until an actual `.background`.
            switch launchState {
            case .launching, .suspended:
                handleForegroundActivation()
            case .ready, .suspending, .resuming, .failed:
                break
            }
            #if ENABLE_ICLOUD_SYNC
                syncCoordinator?.handleScenePhaseChange(.inactive)
            #endif
        case .background:
            resumeRetryAttempt = 0
            prepareForSuspension()
        @unknown default:
            break
        }
    }

    private func transitionToRestingAndScheduleResumeRetry(resumeID: UUID) {
        guard case .current = launchState.resumeCallbackDisposition(for: resumeID) else {
            return
        }
        launchState = .suspended(.resting)

        guard scenePhase != .background else { return }
        guard let delay = AppResumeRetryPolicy.delay(forAttempt: resumeRetryAttempt) else {
            launchState = .failed(
                String(localized: "ClipKitty couldn't reopen its database. Please relaunch the app.")
            )
            return
        }
        resumeRetryAttempt += 1

        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard scenePhase != .background,
                  case .suspended(.resting) = launchState
            else {
                return
            }
            beginResume()
        }
    }

    private func handleForegroundActivation() {
        switch launchState {
        case .launching:
            beginResume()
        case let .suspended(suspended):
            switch suspended {
            case .resting:
                beginResume()
            case let .waitingForSupersededResume(openTask):
                beginResume(after: openTask)
            }
        case let .ready(session):
            resumeReadySession(session)
        case .suspending:
            // Terminal teardown cannot be cancelled or reused. Its completion
            // observes the active scene and starts a fresh resume.
            break
        case .resuming, .failed:
            break
        }
    }

    private func resumeReadySession(_ session: AppSession) {
        session.appState.restoreVisibleFeedAfterForegroundActivation()
        session.appState.beginForegroundActivity()
        #if ENABLE_ICLOUD_SYNC
            syncCoordinator?.handleScenePhaseChange(.active)
        #endif
    }

    private func prepareForSuspension() {
        guard case let .ready(session) = launchState else {
            switch launchState {
            case .launching:
                launchState = .suspended(.resting)
            case let .resuming(context):
                // Seal synchronously so no store can transfer after foreground
                // authority ends. The existing open task owns the off-main join;
                // the next activation chains its replacement after that task.
                context.gate.seal()
                launchState = .suspended(.waitingForSupersededResume(
                    openTask: context.openTask
                ))
            case .ready, .suspending, .suspended, .failed:
                break
            }
            return
        }

        let store = session.container.store

        // Revoke UI and shortcut producers synchronously.
        let pendingMutation = session.appState.prepareForSuspension()
        ClipKittyShortcutRuntime.useStoreProvider {
            .unavailable("ClipKitty is suspended.")
        }

        let storeSuspension: AppStoreSuspensionWork
        switch AppBackgroundTaskLease.acquire(
            named: "ClipKitty Suspend",
            onExpiration: {
                // Reject new work immediately. The retained drain task below is
                // already responsible for waiting and closing off the main actor.
                store.beginSuspend()
            }
        ) {
        case let .granted(lease):
            let drain = Task { @MainActor in
                // Let a mutation already owned by the outgoing view model
                // settle before sealing Rust admission. No new UI or shortcut
                // producer can start after the synchronous revocation above.
                switch pendingMutation {
                case .quiescent:
                    break
                case let .awaiting(task):
                    await task.value
                }
                store.beginSuspend()
                await Task.detached(priority: .utility) {
                    store.prepareForSuspend()
                }.value
            }
            storeSuspension = .protected(lease: lease, drain: drain)
        case .unavailable:
            // UIKit granted no additional reservation for the drain itself.
            // Do not seal before an already-reserved external drag provider has
            // delivered its promised data; its own background lease bounds this
            // wait and expires fail-closed. The retained task still keeps every
            // wait and Rust drain off the lifecycle callback.
            let drain = Task { @MainActor in
                switch pendingMutation {
                case .quiescent:
                    break
                case let .awaiting(task):
                    await task.value
                }
                store.beginSuspend()
                await Task.detached(priority: .utility) {
                    store.prepareForSuspend()
                }.value
            }
            storeSuspension = .unprotected(drain: drain)
        }
        let suspensionID = UUID()
        Task { @MainActor in
            await finishPreparingForSuspension(
                suspensionID: suspensionID,
                storeSuspension: storeSuspension
            )
        }
        launchState = .suspending(
            AppSuspensionContext(id: suspensionID, session: session)
        )
    }

    private func finishPreparingForSuspension(
        suspensionID: UUID,
        storeSuspension: AppStoreSuspensionWork
    ) async {
        #if ENABLE_ICLOUD_SYNC
            await syncCoordinator?.prepareForSuspension()
        #endif
        switch storeSuspension {
        case let .protected(lease, drain):
            await drain.value
            lease.end()
        case let .unprotected(drain):
            await drain.value
        }

        guard case let .suspending(context) = launchState,
              context.id == suspensionID
        else {
            return
        }

        #if ENABLE_ICLOUD_SYNC
            syncCoordinator = nil
            iOSBackgroundSyncRunner.shared.releaseForegroundStore(
                context.session.persistenceClaimID
            )
        #endif

        let shouldResume = scenePhase != .background
        launchState = .suspended(.resting)
        if shouldResume {
            // Return first so this function releases its final AppSession
            // reference before a new store opens on the same path.
            Task { @MainActor in
                await Task.yield()
                guard scenePhase != .background else { return }
                handleForegroundActivation()
            }
        }
    }

    private func bootstrapFailureView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(String(localized: "ClipKitty couldn't start"))
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
