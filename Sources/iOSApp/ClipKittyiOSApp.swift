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
        let identifier = client.begin(name) {
            onExpiration()
            lease.end()
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
}

final class AppBackgroundTaskCancellation: @unchecked Sendable {
    private enum State {
        case waiting
        case installed(@Sendable () -> Void)
        case cancelled
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
        }
        lock.unlock()
        action?()
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
    case quiescent
}

private enum AppStoreOpenAttemptResult {
    case completed(Result<StoreSession, AppContainer.BootstrapError>)
    case rejected
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
    private let container: AppContainer
    let viewModel: BrowserViewModel

    var toast: ToastState = .hidden
    var contentRevision: Int = 0

    /// A transient snackbar request plus presentation identity. The request
    /// structurally owns its action only when it is actionable.
    enum ToastState {
        case hidden
        case visible(id: UUID, request: NotificationRequest)
    }

    init(container: AppContainer) {
        self.container = container

        // Use a box to capture toast callback — wired after init via the box
        let toastBox = ToastCallbackBox()
        let clipboardService = container.clipboardService
        let haptics = container.haptics
        let settings = container.settings

        let copyItem: (String, ClipboardContent) -> Void = { _, content in
            clipboardService.copy(content: content)
            haptics.fire(.copy)
            toastBox.show?(ToastMessage.copied.notificationRequest)
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
        viewModel.handlePanelVisibilityChange(true, contentRevision: contentRevision)
    }

    func restoreVisibleFeedAfterForegroundActivation() {
        viewModel.handlePanelVisibilityChange(true, contentRevision: contentRevision)
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
        scheduleImageDescriptionUpdate(after: result, imageData: imageData)
        return result
    }

    private func scheduleImageDescriptionUpdate(
        after result: Result<String, ClipboardError>,
        imageData: Data
    ) {
        guard case let .success(itemId) = result, !itemId.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            let update = await self.container.imageDescriptionUpdater.update(itemId: itemId, imageData: imageData)
            if case .success(true) = update {
                self.refreshFeed()
            }
        }
    }

    func ingestPendingAndClipboard() async {
        let added = await processPendingShareItems()
        if added > 0 { refreshFeed() }
        await autoAddFromClipboard()
    }

    @discardableResult
    func prepareForSuspension() -> BrowserSuspensionWork {
        let mutation = viewModel.prepareForSuspension()
        toast = .hidden
        return mutation
    }

    func processPendingShareItems() async -> Int {
        let pending = PendingShareQueue.loadAll()
        guard !pending.isEmpty else { return 0 }

        var saved = 0
        for item in pending {
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
            case let .image(imageData, thumbnail):
                result = await saveImage(
                    imageData: imageData,
                    thumbnail: thumbnail,
                    sourceApp: sourceApp,
                    sourceAppBundleId: nil,
                    isAnimated: false
                )
            }
            if case .success = result {
                PendingShareQueue.acknowledge(item)
                saved += 1
            }
        }
        return saved
    }

    func autoAddFromClipboard() async {
        guard container.settings.autoAddFromClipboard else { return }

        // Reading changeCount does not trigger the paste-consent alert. If the
        // pasteboard has not changed since we last looked, skip the read so we
        // don't prompt for "Allow Paste" on every foreground.
        let changeCount = container.clipboardService.pasteboardChangeCount
        guard changeCount != container.settings.lastIngestedPasteboardChangeCount else { return }

        guard let content = container.clipboardService.readCurrentClipboard() else {
            // A denied or unreadable generation should not prompt repeatedly.
            acknowledgePasteboardGeneration(changeCount)
            return
        }

        guard let result = await savePasteboardContent(content) else {
            acknowledgePasteboardGeneration(changeCount)
            return
        }

        switch result {
        case .success:
            acknowledgePasteboardGeneration(changeCount)
            refreshFeed()
        case .failure:
            // Leave the generation pending so suspension or another transient
            // store failure retries it with the next fresh session.
            break
        }
    }

    private func acknowledgePasteboardGeneration(_ generation: Int) {
        guard container.clipboardService.pasteboardChangeCount == generation else { return }
        container.settings.lastIngestedPasteboardChangeCount = generation
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

// MARK: - App Entry Point

@main
struct ClipKittyiOSApp: App {
    @State private var launchState: AppLaunchState = .launching
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
            .task {
                await appState.ingestPendingAndClipboard()
            }

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
        guard scenePhase == .active else { return }
        let resumeID = UUID()
        #if ENABLE_ICLOUD_SYNC
            // Hold foreground path authority through open, ready use, and the
            // eventual terminal drain. Claiming synchronously drains any
            // background-launched headless store first.
            iOSBackgroundSyncRunner.shared.claimForegroundStore(resumeID)
        #endif
        let customPath = databasePathOverride
        let gate = AppStoreOpenGate()
        let protection: AppResumeBackgroundProtection
        switch AppBackgroundTaskLease.acquire(
            named: "ClipKitty Store Open",
            onExpiration: { gate.expireAndDrain() }
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
                if case .current = launchState.resumeCallbackDisposition(for: resumeID) {
                    launchState = .suspended(.resting)
                }
                #if ENABLE_ICLOUD_SYNC
                    iOSBackgroundSyncRunner.shared.releaseForegroundStore(resumeID)
                #endif
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
                guard scenePhase == .active else {
                    // The environment can observe background before its
                    // onChange callback runs. Do not transfer a store after
                    // foreground authority has already ended.
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
                    Task { await container.pruneToStorageLimit() }
                case .expired:
                    #if ENABLE_ICLOUD_SYNC
                        iOSBackgroundSyncRunner.shared.releaseForegroundStore(resumeID)
                    #endif
                    launchState = .suspended(.resting)
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
            #if ENABLE_ICLOUD_SYNC
                syncCoordinator?.handleScenePhaseChange(.inactive)
            #endif
        case .background:
            prepareForSuspension()
        @unknown default:
            break
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
        #if ENABLE_ICLOUD_SYNC
            syncCoordinator?.handleScenePhaseChange(.active)
        #endif
        Task {
            await session.appState.ingestPendingAndClipboard()
        }
    }

    private func prepareForSuspension() {
        guard case let .ready(session) = launchState else {
            switch launchState {
            case .launching:
                launchState = .suspended(.resting)
            case let .resuming(context):
                // Seal synchronously. If UIKit could not reserve background
                // time, block this scene transition until the opening attempt
                // is fully quiescent; otherwise its existing lease owns the
                // bounded asynchronous drain.
                context.gate.seal()
                launchState = .suspended(.waitingForSupersededResume(
                    openTask: context.openTask
                ))
                switch context.protection {
                case .granted:
                    break
                case .unavailable:
                    context.gate.expireAndDrain()
                }
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
                store.beginSuspend()
                store.prepareForSuspend()
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
            // No assertion means no asynchronous grace period. Finish all file
            // work before returning from the background scene transition.
            store.beginSuspend()
            store.prepareForSuspend()
            storeSuspension = .quiescent
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
        case .quiescent:
            break
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

        let shouldResume = scenePhase == .active
        launchState = .suspended(.resting)
        if shouldResume {
            // Return first so this function releases its final AppSession
            // reference before a new store opens on the same path.
            Task { @MainActor in
                await Task.yield()
                guard scenePhase == .active else { return }
                handleForegroundActivation()
            }
        }
    }

    private func bootstrapFailureView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("ClipKitty couldn't start")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
