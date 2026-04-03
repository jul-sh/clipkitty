import ClipKittyAppleServices
import ClipKittyRust
import ClipKittyShared
import SwiftUI

// MARK: - App Launch State

enum AppLaunchState {
    case launching
    case ready(AppContainer, AppState, AppRouter)
    case failed(String)
}

// MARK: - App State (UI coordinator)

@MainActor
@Observable
final class AppState {
    let container: AppContainer
    let viewModel: BrowserViewModel

    var toastMessage: ToastMessage?
    var toastAction: (() -> Void)?
    var contentRevision: Int = 0

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
                toastBox.showToast?(.copied, nil)
            },
            onCopyOnly: { _, content in
                clipboardService.copy(content: content)
                haptics.fire(.copy)
                toastBox.showToast?(.copied, nil)
            },
            onDismiss: {},
            showSnackbarNotification: { kind, action in
                toastBox.showToast?(.notification(kind), action)
            },
            dismissSnackbarNotification: {
                toastBox.dismissToast?()
            }
        )

        // Wire the box to self after all stored properties are initialized
        toastBox.showToast = { [weak self] message, action in
            self?.showToast(message, action: action)
        }
        toastBox.dismissToast = { [weak self] in
            withAnimation(.bouncy) {
                self?.toastMessage = nil
                self?.toastAction = nil
            }
        }
    }

    func showToast(_ message: ToastMessage, action: (() -> Void)? = nil) {
        withAnimation(.bouncy) {
            toastMessage = message
            toastAction = action
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(message.duration))
            if toastMessage == message {
                withAnimation(.bouncy) {
                    toastMessage = nil
                    toastAction = nil
                }
            }
        }
    }

    func refreshFeed() {
        contentRevision += 1
        viewModel.handlePanelVisibilityChange(true, contentRevision: contentRevision)
    }
}

// MARK: - Toast Message

enum ToastMessage: Equatable {
    case copied
    case bookmarked
    case unbookmarked
    case saved
    case deleted
    case addSucceeded
    case addFailed(String)
    case notification(NotificationKind)

    var text: String {
        switch self {
        case .copied: return String(localized: "Copied to clipboard")
        case .bookmarked: return String(localized: "Bookmarked")
        case .unbookmarked: return String(localized: "Removed bookmark")
        case .saved: return String(localized: "Saved")
        case .deleted: return String(localized: "Deleted")
        case .addSucceeded: return String(localized: "Added")
        case let .addFailed(reason): return String(localized: "Failed: \(reason)")
        case let .notification(kind): return kind.message
        }
    }

    var iconSystemName: String {
        switch self {
        case .copied: return "doc.on.doc"
        case .bookmarked: return "bookmark.fill"
        case .unbookmarked: return "bookmark.slash"
        case .saved: return "checkmark.circle"
        case .deleted: return "trash"
        case .addSucceeded: return "plus.circle"
        case .addFailed: return "exclamationmark.triangle"
        case let .notification(kind): return kind.iconSystemName
        }
    }

    var actionTitle: String? {
        switch self {
        case let .notification(kind):
            if case let .actionable(_, _, title) = kind { return title }
            return nil
        default:
            return nil
        }
    }

    var duration: TimeInterval {
        switch self {
        case .copied, .bookmarked, .unbookmarked, .saved, .deleted, .addSucceeded:
            return 1.5
        case .addFailed:
            return 3.0
        case let .notification(kind):
            return kind.duration
        }
    }
}

@MainActor
private final class ToastCallbackBox {
    var showToast: ((ToastMessage, (() -> Void)?) -> Void)?
    var dismissToast: (() -> Void)?
}

// MARK: - App Entry Point

@main
struct ClipKittyiOSApp: App {
    @State private var launchState: AppLaunchState = .launching
    @Environment(\.scenePhase) private var scenePhase

    #if ENABLE_SYNC
        @State private var syncCoordinator: iOSSyncCoordinator?
    #endif

    init() {
        FontManager.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            switch launchState {
            case .launching:
                ProgressView("Loading ClipKitty...")
                    .onAppear { performBootstrap() }

            case let .ready(container, appState, router):
                rootView(container: container, appState: appState, router: router)

            case let .failed(message):
                bootstrapFailureView(message: message)
            }
        }
    }

    @ViewBuilder
    private func rootView(
        container: AppContainer,
        appState: AppState,
        router: AppRouter
    ) -> some View {
        let base = RootTabView()
            .environment(container)
            .environment(appState)
            .environment(appState.viewModel)
            .environment(router)
            .environment(container.settings)
            .environment(container.haptics)
            .onOpenURL { router.handleURL($0) }

        #if ENABLE_SYNC
            if let coordinator = syncCoordinator {
                base
                    .environment(coordinator)
                    .onChange(of: scenePhase) { _, newPhase in
                        coordinator.handleScenePhaseChange(newPhase)
                    }
            } else {
                base
            }
        #else
            base
        #endif
    }

    private func performBootstrap() {
        switch AppContainer.bootstrap() {
        case let .success(container):
            let appState = AppState(container: container)
            let router = AppRouter()

            #if ENABLE_SYNC
                let coordinator = iOSSyncCoordinator(
                    store: container.store,
                    enabled: container.settings.syncEnabled,
                    onContentChanged: { [weak appState] in
                        appState?.refreshFeed()
                    }
                )
                syncCoordinator = coordinator
                if container.settings.syncEnabled {
                    coordinator.handleScenePhaseChange(.active)
                }
            #endif

            launchState = .ready(container, appState, router)
        case let .failure(error):
            launchState = .failed(error.localizedDescription)
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
