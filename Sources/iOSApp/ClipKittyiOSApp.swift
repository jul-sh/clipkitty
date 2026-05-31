import ClipKittyAppleServices
import ClipKittyRust
import ClipKittyShared
import ClipKittyShortcuts
import SwiftUI

// MARK: - App Launch State

enum AppLaunchState {
    case launching
    case ready(AppContainer, AppState)
    case suspended
    case failed(String)
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

        viewModel = BrowserViewModel(
            client: container.storeClient,
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
            let result: Result<String, ClipboardError>
            switch entry.item {
            case let .text(text):
                result = await container.repository.saveText(
                    text: text,
                    sourceApp: "Share Sheet",
                    sourceAppBundleId: nil
                )
            case let .url(url):
                result = await container.repository.saveText(
                    text: url,
                    sourceApp: "Share Sheet",
                    sourceAppBundleId: nil
                )
            case .image:
                guard let imageData = entry.imageData else { continue }
                result = await container.repository.saveImage(
                    imageData: imageData,
                    thumbnail: entry.thumbnailData,
                    sourceApp: "Share Sheet",
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
        guard let content = container.clipboardService.readCurrentClipboard() else { return }

        let result: Result<String, ClipboardError>

        switch content {
        case let .image(image):
            guard let data = image.pngData() else { return }
            let thumbnail = image.preparingThumbnail(of: CGSize(width: 200, height: 200))?.jpegData(
                compressionQuality: 0.7
            )
            result = await container.repository.saveImage(
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
            container.haptics.fire(.success)
            showToast(.addSucceeded)
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
        switch launchState {
        case .launching:
            ProgressView("Loading ClipKitty...")
                .onAppear { performBootstrap() }

        case let .ready(container, appState):
            rootView(container: container, appState: appState)

        case .suspended:
            ProgressView("Loading ClipKitty...")

        case let .failed(message):
            bootstrapFailureView(message: message)
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

    private func performBootstrap() {
        let customPath = ProcessInfo.processInfo.environment["CLIPKITTY_SCREENSHOT_DB"]
        switch AppContainer.bootstrap(databasePath: customPath) {
        case let .success(container):
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

            launchState = .ready(container, appState)
        case let .failure(error):
            launchState = .failed(error.localizedDescription)
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
        case .suspended:
            performBootstrap()
        case let .ready(_, appState):
            #if ENABLE_ICLOUD_SYNC
                syncCoordinator?.handleScenePhaseChange(.active)
            #endif
            Task {
                await appState.ingestPendingAndClipboard()
            }
        case .launching, .failed:
            break
        }
    }

    private func prepareForSuspension() {
        #if ENABLE_ICLOUD_SYNC
            syncCoordinator?.handleScenePhaseChange(.background)
            syncCoordinator = nil
        #endif

        guard case let .ready(container, appState) = launchState else {
            if case .launching = launchState {
                launchState = .suspended
            }
            return
        }

        appState.prepareForSuspension()
        container.prepareForSuspension()
        launchState = .suspended
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
