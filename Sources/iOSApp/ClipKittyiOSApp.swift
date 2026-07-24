import ClipKittyAppleServices
import ClipKittyRust
import ClipKittyShared
import ClipKittyShortcuts
import SwiftUI

// MARK: - App Launch State

struct AppSession {
    let container: AppContainer
    let appState: AppState
}

struct AppSuspensionContext {
    let id: UUID
    let session: AppSession
    let task: Task<Void, Never>
}

enum AppResumePhase: Equatable {
    /// Keep rendering the previous session during the grace period.
    case waitingForSpinner
    /// The store open outlasted the grace period, so render the launch spinner.
    case showingSpinner
}

struct AppResumeContext {
    let id: UUID
    let previous: AppSession
    var phase: AppResumePhase
    let spinnerTask: Task<Void, Never>
    let openTask: Task<Void, Never>
}

/// A suspended app may still have a superseded store open draining in the
/// background. Keeping that task in the state that requires it ensures the
/// next resume cannot open a second store against the same index concurrently.
enum AppSuspendedState {
    case withoutPreviousSession
    case resting(previous: AppSession)
    case waitingForSupersededResume(previous: AppSession, openTask: Task<Void, Never>)
}

enum AppResumeCallbackDisposition {
    case current(AppResumeContext)
    case superseded
}

enum AppLaunchState {
    case launching
    case ready(AppSession)
    case suspending(AppSuspensionContext)
    /// Database released. The suspended state keeps the outgoing session so
    /// the next foreground can render it while a fresh container bootstraps.
    case suspended(AppSuspendedState)
    /// Re-bootstrapping after a foreground activation: the previous session
    /// stays on screen, and the spinner only appears once the resume
    /// outlasts its grace period.
    case resuming(AppResumeContext)
    case failed(String)

    func resumeCallbackDisposition(for resumeID: UUID) -> AppResumeCallbackDisposition {
        guard case let .resuming(context) = self, context.id == resumeID else {
            return .superseded
        }
        return .current(context)
    }

    mutating func advanceResumeSpinner(for resumeID: UUID) {
        guard case var .resuming(context) = self, context.id == resumeID else { return }
        switch context.phase {
        case .waitingForSpinner:
            context.phase = .showingSpinner
            self = .resuming(context)
        case .showingSpinner:
            break
        }
    }
}

/// What the window actually renders, derived from ``AppLaunchState``. The
/// session case is a single structural branch so suspend/resume transitions
/// of the SAME session never recreate the view tree (identity is keyed per
/// session), while a rebootstrapped session gets a fresh tree.
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

    private func scheduleImageDescriptionUpdate(after result: Result<String, ClipboardError>, imageData: Data) {
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

    func prepareForSuspension() {
        viewModel.prepareForSuspension()
        toast = .hidden
    }

    func processPendingShareItems() async -> Int {
        let pending = PendingShareQueue.dequeueAll()
        guard !pending.isEmpty else { return 0 }

        var saved = 0
        for entry in pending {
            let sourceApp = "Share Sheet"

            let result: Result<String, ClipboardError>
            switch entry.item {
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
            case .image:
                guard let imageData = entry.imageData else { continue }
                result = await saveImage(
                    imageData: imageData,
                    thumbnail: entry.thumbnailData,
                    sourceApp: sourceApp,
                    sourceAppBundleId: nil,
                    isAnimated: false
                )
            }
            if case .success = result { saved += 1 }
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

        // Record this generation now, before attempting the read, so a user
        // denial or unreadable content is not re-prompted for the same
        // pasteboard generation; we intentionally respect the denial.
        container.settings.lastIngestedPasteboardChangeCount = changeCount

        guard let content = container.clipboardService.readCurrentClipboard() else { return }

        let result: Result<String, ClipboardError>

        switch content {
        case let .image(image):
            guard let data = image.pngData() else { return }
            let thumbnail = image.preparingThumbnail(of: CGSize(width: 200, height: 200))?.jpegData(
                compressionQuality: 0.7
            )
            result = await saveImage(
                imageData: data,
                thumbnail: thumbnail,
                sourceApp: "Pasteboard",
                sourceAppBundleId: nil,
                isAnimated: false
            )
        case let .link(url):
            result = await container.repository.saveText(
                text: url.absoluteString,
                sourceApp: "Pasteboard",
                sourceAppBundleId: nil
            )
        case let .text(text):
            result = await container.repository.saveText(
                text: text,
                sourceApp: "Pasteboard",
                sourceAppBundleId: nil
            )
        }

        switch result {
        case .success:
            refreshFeed()
        case .failure:
            break
        }
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
                // Key the tree to the session: suspend/resume of the same
                // session keeps every @State (scroll position, search text),
                // while a rebootstrapped session starts a fresh tree.
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
        case let .suspended(suspended):
            // Rendering the last known state here also keeps the app
            // switcher snapshot on content instead of a spinner.
            switch suspended {
            case .withoutPreviousSession:
                return .spinner
            case let .resting(previous),
                 let .waitingForSupersededResume(previous, _):
                return .session(previous)
            }
        case let .resuming(context):
            switch context.phase {
            case .waitingForSpinner:
                return .session(context.previous)
            case .showingSpinner:
                return .spinner
            }
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

    private static let resumeSpinnerGrace: Duration = .milliseconds(150)
    private static let resumeWarmupDeadline: Duration = .seconds(2)

    private var databasePathOverride: String? {
        #if ENABLE_TEST_FIXTURES
            ProcessInfo.processInfo.environment["CLIPKITTY_SCREENSHOT_DB"]
        #else
            nil
        #endif
    }

    private func performBootstrap() {
        // The screenshot-DB override injects a synthetic store for automated
        // App Store screenshots. It must never exist in shipping builds, so the
        // build-variant capability compiles it into test fixtures only.
        switch AppContainer.bootstrap(databasePath: databasePathOverride) {
        case let .success(container):
            let session = makeSession(container: container)
            launchState = .ready(session)
            Task { await container.pruneToStorageLimit() }
        case let .failure(error):
            launchState = .failed(error.localizedDescription)
        }
    }

    /// Wires the service graph around a freshly-bootstrapped container: the
    /// shortcut runtime, the UI coordinator, and (when enabled) iCloud sync.
    private func makeSession(container: AppContainer) -> AppSession {
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
        return AppSession(container: container, appState: appState)
    }

    /// Re-bootstraps after a foreground activation while the previous
    /// session stays on screen. The store opens off the main actor; a
    /// watchdog swaps in the spinner only if the resume outlasts the grace
    /// period, and the fresh session is adopted only once its feed has
    /// content, so the UI goes straight from last known state to fresh
    /// content without an empty flash.
    private func beginResume(
        previous: AppSession,
        after supersededOpen: Task<Void, Never>? = nil
    ) {
        let resumeID = UUID()
        // Screenshot-DB override is fixture-only; shipping builds always resume
        // the real store (custom path nil). See `performBootstrap`.
        let customPath = databasePathOverride

        let spinnerTask = Task { @MainActor in
            try? await Task.sleep(for: Self.resumeSpinnerGrace)
            guard !Task.isCancelled else { return }
            launchState.advanceResumeSpinner(for: resumeID)
        }

        // Chain on any superseded resume so its store is released before a
        // new one opens — two live stores would contend for the index lock.
        let openTask = Task { @MainActor in
            await supersededOpen?.value

            // This resume may have been suspended or superseded while it was
            // waiting for the previous open to drain. In that case the next
            // foreground transition owns opening a fresh store.
            switch launchState.resumeCallbackDisposition(for: resumeID) {
            case .current:
                break
            case .superseded:
                return
            }

            let outcome = await Task.detached(priority: .userInitiated) {
                AppContainer.openStore(databasePath: customPath)
            }.value
            await handleResumeOpenOutcome(outcome, resumeID: resumeID)
        }

        launchState = .resuming(AppResumeContext(
            id: resumeID,
            previous: previous,
            phase: .waitingForSpinner,
            spinnerTask: spinnerTask,
            openTask: openTask
        ))
    }

    private func handleResumeOpenOutcome(
        _ outcome: Result<StoreSession, AppContainer.BootstrapError>,
        resumeID: UUID
    ) async {
        switch outcome {
        case let .success(storeSession):
            switch launchState.resumeCallbackDisposition(for: resumeID) {
            case .current:
                await adoptResumedStore(storeSession, resumeID: resumeID)
            case .superseded:
                // Backgrounded or replaced mid-open: release this store before
                // the next resume's chained open is allowed to proceed.
                storeSession.store.prepareForSuspend()
            }
        case let .failure(error):
            switch launchState.resumeCallbackDisposition(for: resumeID) {
            case let .current(context):
                context.spinnerTask.cancel()
                launchState = .failed(error.localizedDescription)
            case .superseded:
                break
            }
        }
    }

    private func adoptResumedStore(
        _ storeSession: StoreSession,
        resumeID: UUID
    ) async {
        let container = AppContainer.assemble(storeSession: storeSession)
        let session = makeSession(container: container)

        // Warm the fresh feed while the previous state is still showing.
        session.appState.restoreVisibleFeedAfterForegroundActivation()
        let deadline = ContinuousClock.now.advanced(by: Self.resumeWarmupDeadline)
        while session.appState.viewModel.contentState.displayedContent == nil,
              ContinuousClock.now < deadline
        {
            switch launchState.resumeCallbackDisposition(for: resumeID) {
            case .current:
                break
            case .superseded:
                return discardUnadoptedSession(container: container)
            }
            try? await Task.sleep(for: .milliseconds(16))
        }

        switch launchState.resumeCallbackDisposition(for: resumeID) {
        case let .current(context):
            context.spinnerTask.cancel()
        case .superseded:
            return discardUnadoptedSession(container: container)
        }

        launchState = .ready(session)
        Task { await container.pruneToStorageLimit() }
    }

    /// Backgrounded again before the fresh session was adopted: release its
    /// store and tear down the coordinator `makeSession` already installed.
    private func discardUnadoptedSession(container: AppContainer) {
        container.prepareForSuspension()
        #if ENABLE_ICLOUD_SYNC
            syncCoordinator = nil
        #endif
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
        case let .suspended(suspended):
            switch suspended {
            case .withoutPreviousSession:
                performBootstrap()
            case let .resting(previous):
                beginResume(previous: previous)
            case let .waitingForSupersededResume(previous, openTask):
                beginResume(previous: previous, after: openTask)
            }
        case let .ready(session):
            resumeReadySession(session)
        case let .suspending(context):
            context.task.cancel()
            launchState = .ready(context.session)
            resumeReadySession(context.session)
        case .launching, .resuming, .failed:
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
                launchState = .suspended(.withoutPreviousSession)
            case let .resuming(context):
                // The fresh container was never adopted; the in-flight open
                // releases its store when it observes this state. The
                // previous session's store is already suspended.
                context.spinnerTask.cancel()
                launchState = .suspended(.waitingForSupersededResume(
                    previous: context.previous,
                    openTask: context.openTask
                ))
            case .ready, .suspending, .suspended, .failed:
                break
            }
            return
        }

        let suspensionID = UUID()
        let task = Task { @MainActor in
            await finishPreparingForSuspension(session: session, suspensionID: suspensionID)
        }
        launchState = .suspending(
            AppSuspensionContext(id: suspensionID, session: session, task: task)
        )
    }

    private func finishPreparingForSuspension(
        session: AppSession,
        suspensionID: UUID
    ) async {
        guard !Task.isCancelled else { return }

        #if ENABLE_ICLOUD_SYNC
            await iOSBackgroundTaskRunner.run(named: "ClipKitty Suspend") {
                await syncCoordinator?.prepareForSuspension()
                guard !Task.isCancelled,
                      case let .suspending(context) = launchState,
                      context.id == suspensionID
                else {
                    return
                }
                session.appState.prepareForSuspension()
                session.container.prepareForSuspension()
            }
        #else
            guard case let .suspending(context) = launchState,
                  context.id == suspensionID
            else {
                return
            }
            session.appState.prepareForSuspension()
            session.container.prepareForSuspension()
        #endif

        guard !Task.isCancelled,
              case let .suspending(context) = launchState,
              context.id == suspensionID
        else {
            return
        }

        #if ENABLE_ICLOUD_SYNC
            syncCoordinator = nil
        #endif

        // Keep the outgoing session: its store is suspended, but its view
        // model still holds the last displayed content, which the next
        // resume renders instead of a spinner.
        launchState = .suspended(.resting(previous: session))
        if scenePhase == .active {
            handleForegroundActivation()
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
