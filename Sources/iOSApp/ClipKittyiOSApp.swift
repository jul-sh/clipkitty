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

enum AppLaunchState {
    case launching
    case ready(AppSession)
    case suspending(AppSuspensionContext)
    /// Database released. Keeps the outgoing session so the next foreground
    /// can keep rendering the last known state while a fresh container
    /// bootstraps; nil when the app never reached `.ready`.
    case suspended(previous: AppSession?)
    /// Re-bootstrapping after a foreground activation: the previous session
    /// stays on screen, and the spinner only appears once the resume
    /// outlasts its grace period.
    case resuming(previous: AppSession, spinnerVisible: Bool)
    case failed(String)
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

    var toast: ToastState = .init()
    var contentRevision: Int = 0

    /// A transient snackbar notification (with optional inline action). The
    /// underlying value is a shared `NotificationKind` so iOS and Mac can use
    /// the same snackbar model; see `SnackbarItem` in `ClipKittyShared`.
    struct ToastState {
        var kind: NotificationKind?
        var action: (() -> Void)?
    }

    init(container: AppContainer) {
        self.container = container

        // Use a box to capture toast callback — wired after init via the box
        let toastBox = ToastCallbackBox()
        let clipboardService = container.clipboardService
        let haptics = container.haptics
        let settings = container.settings

        viewModel = BrowserViewModel(
            client: container.storeClient,
            shouldGenerateLinkPreviews: { settings.generateLinkPreviews },
            onSelect: { _, content in
                clipboardService.copy(content: content)
                haptics.fire(.copy)
                toastBox.show?(ToastMessage.copied.notificationKind, nil)
            },
            onCopyOnly: { _, content in
                clipboardService.copy(content: content)
                haptics.fire(.copy)
                toastBox.show?(ToastMessage.copied.notificationKind, nil)
            },
            onDismiss: {},
            showSnackbarNotification: { kind, action in
                toastBox.show?(kind, action)
            },
            dismissSnackbarNotification: {
                toastBox.dismiss?()
            }
        )

        // Wire the box to self after all stored properties are initialized
        toastBox.show = { [weak self] kind, action in
            self?.showNotification(kind, action: action)
        }
        toastBox.dismiss = { [weak self] in
            withAnimation(.bouncy) {
                self?.toast = .init()
            }
        }
    }

    func showToast(_ message: ToastMessage, action: (() -> Void)? = nil) {
        showNotification(message.notificationKind, action: action)
    }

    /// Show a shared-model snackbar notification. The iOS overlay renders this
    /// from the same `NotificationKind` cases the Mac uses (see Mac's
    /// `SnackbarView`), keeping presentation aligned across platforms.
    func showNotification(_ kind: NotificationKind, action: (() -> Void)? = nil) {
        withAnimation(.bouncy) {
            toast = ToastState(kind: kind, action: action)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(kind.duration))
            guard let self, self.toast.kind == kind else { return }
            withAnimation(.bouncy) {
                self.toast = .init()
            }
        }
    }

    func refreshFeed() {
        contentRevision += 1
        viewModel.handlePanelVisibilityChange(true, contentRevision: contentRevision)
        // Content changed; if this landed while backgrounded (sync), the
        // keyboard snapshot refreshes now — foreground changes wait for
        // suspension (see KeyboardFeedService).
        container.keyboardFeed.scheduleRefresh()
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
        toast = .init()
    }

    func processPendingShareItems() async -> Int {
        let pending = PendingShareQueue.dequeueAll()
        guard !pending.isEmpty else { return 0 }

        var saved = 0
        for entry in pending {
            // Keyboard captures are clipboard content, so they get the same
            // source label auto-add uses; share-sheet items keep theirs.
            let sourceApp = switch entry.origin {
            case .shareSheet: "Share Sheet"
            case .keyboard: "Pasteboard"
            }

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

        // The keyboard may have captured (and marked) a generation while this
        // session was backgrounded but not torn down.
        container.settings.refreshPasteboardIngestState()

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
/// builds a shared `NotificationKind` so the snackbar slot can be rendered
/// from the same `SnackbarItem` model the Mac uses.
enum ToastMessage: Equatable {
    case copied
    case bookmarked
    case unbookmarked
    case saved
    case deleted
    case addSucceeded
    case addFailed(String)
    case clipboardEmpty

    var notificationKind: NotificationKind {
        switch self {
        case .copied:
            return .passive(message: String(localized: "Copied to clipboard"), iconSystemName: "doc.on.doc")
        case .bookmarked:
            return .passive(message: String(localized: "Bookmarked"), iconSystemName: "bookmark.fill")
        case .unbookmarked:
            return .passive(message: String(localized: "Removed bookmark"), iconSystemName: "bookmark.slash")
        case .saved:
            return .passive(message: String(localized: "Saved"), iconSystemName: "checkmark.circle")
        case .deleted:
            return .passive(message: String(localized: "Deleted"), iconSystemName: "trash")
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
    var show: ((NotificationKind, (() -> Void)?) -> Void)?
    var dismiss: (() -> Void)?
}

// MARK: - App Entry Point

@main
struct ClipKittyiOSApp: App {
    @State private var launchState: AppLaunchState = .launching
    /// The in-flight store open of the current resume, chained so a
    /// superseded open always releases its store before the next one starts.
    @State private var resumeOpenTask: Task<Void, Never>?
    @State private var deepLinks = DeepLinkRouter()
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
                // Attached above the launch-state switch so a link that
                // arrives mid-bootstrap (keyboard cold-starting the app)
                // still lands; the router holds it until the feed consumes it.
                .onOpenURL { url in
                    guard let link = AppDeepLink(url: url) else { return }
                    deepLinks.open(link)
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
        case let .suspended(previous):
            // Rendering the last known state here also keeps the app
            // switcher snapshot on content instead of a spinner.
            return previous.map(LaunchPresentation.session) ?? .spinner
        case let .resuming(previous, spinnerVisible):
            return spinnerVisible ? .spinner : .session(previous)
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
            .environment(deepLinks)
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

    private func performBootstrap() {
        let customPath = ProcessInfo.processInfo.environment["CLIPKITTY_SCREENSHOT_DB"]
        switch AppContainer.bootstrap(databasePath: customPath) {
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
        ClipKittyShortcutRuntime.useRepositoryProvider { [weak container] in
            guard let container else {
                return .unavailable("ClipKitty is suspended.")
            }
            return container.shortcutRepositoryAvailability()
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
    private func beginResume(previous: AppSession) {
        launchState = .resuming(previous: previous, spinnerVisible: false)
        let customPath = ProcessInfo.processInfo.environment["CLIPKITTY_SCREENSHOT_DB"]

        Task { @MainActor in
            try? await Task.sleep(for: Self.resumeSpinnerGrace)
            if case let .resuming(previous, spinnerVisible: false) = launchState {
                launchState = .resuming(previous: previous, spinnerVisible: true)
            }
        }

        // Chain on any superseded resume so its store is released before a
        // new one opens — two live stores would contend for the index lock.
        let supersededOpen = resumeOpenTask
        resumeOpenTask = Task { @MainActor in
            await supersededOpen?.value

            let outcome = await Task.detached(priority: .userInitiated) {
                AppContainer.openStore(databasePath: customPath)
            }.value

            switch outcome {
            case let .success(store):
                guard case .resuming = launchState else {
                    // Backgrounded again mid-open: release the fresh store
                    // rather than leaving the database locked.
                    store.prepareForSuspend()
                    return
                }
                await adoptResumedStore(store)
            case let .failure(error):
                guard case .resuming = launchState else { return }
                launchState = .failed(error.localizedDescription)
            }
        }
    }

    private func adoptResumedStore(_ store: ClipKittyRust.ClipboardStore) async {
        let container = AppContainer.assemble(store: store)
        let session = makeSession(container: container)

        // Warm the fresh feed while the previous state is still showing.
        session.appState.restoreVisibleFeedAfterForegroundActivation()
        let deadline = ContinuousClock.now.advanced(by: Self.resumeWarmupDeadline)
        while session.appState.viewModel.contentState.displayedContent == nil,
              ContinuousClock.now < deadline
        {
            guard case .resuming = launchState else {
                return discardUnadoptedSession(container: container)
            }
            try? await Task.sleep(for: .milliseconds(16))
        }

        guard case .resuming = launchState else {
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
        case let .suspended(previous):
            if let previous {
                beginResume(previous: previous)
            } else {
                performBootstrap()
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
                launchState = .suspended(previous: nil)
            case let .resuming(previous, _):
                // The fresh container was never adopted; the in-flight open
                // releases its store when it observes this state. The
                // previous session's store is already suspended.
                launchState = .suspended(previous: previous)
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
                // Snapshot the keyboard feed while the store is still open —
                // the user is heading to another app, where the keyboard may
                // come up next.
                await session.container.keyboardFeed.refreshOnSuspension()
                guard !Task.isCancelled,
                      case let .suspending(recheck) = launchState,
                      recheck.id == suspensionID
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
            await session.container.keyboardFeed.refreshOnSuspension()
            guard !Task.isCancelled,
                  case let .suspending(recheck) = launchState,
                  recheck.id == suspensionID
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
        launchState = .suspended(previous: session)
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
