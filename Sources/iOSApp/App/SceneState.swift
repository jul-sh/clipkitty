import ClipKittyShared
import SwiftUI

// MARK: - Scene Presentation State

/// Which modal is currently presented. Only one modal at a time.
enum ModalRoute: Equatable, Identifiable {
    case settings
    case edit(itemId: String)
    case compose

    var id: String {
        switch self {
        case .settings: return "settings"
        case let .edit(itemId): return "edit-\(itemId)"
        case .compose: return "compose"
        }
    }
}

/// Detail selection state for the regular-width shell.
enum DetailSelection: Equatable {
    case none
    case selected(itemId: String)
}

/// Chrome-level UI mode. Each case is mutually exclusive — entering one
/// dismisses the others, preventing stale cross-state.
enum ChromeState: Equatable {
    case idle
    case searching
    case filterExpanded
    case addMenuExpanded
}

// MARK: - Scene State (per-window UI coordinator)

/// Owns all UI state that must be independent per iPad window.
/// Replaces the former app-level AppState so each scene gets its own
/// BrowserViewModel, toast, router, and content revision.
@MainActor
@Observable
final class SceneState {
    let viewModel: BrowserViewModel
    let router: AppRouter

    var toast: ToastState = .init()
    var contentRevision: Int = 0

    /// Current modal presentation. Set to nil to dismiss.
    var modalRoute: ModalRoute?

    /// Chrome-level UI mode (idle vs searching).
    var chromeState: ChromeState = .idle

    /// Detail selection for regular-width layout.
    var detailSelection: DetailSelection = .none

    /// Compact-only: item to preview via push navigation.
    /// On regular width, use `detailSelection` instead — this property
    /// drives `NavigationStack.navigationDestination(item:)` which only
    /// exists in CompactShell.
    var previewItemId: String?

    struct ToastState {
        var message: ToastMessage?
        var action: (() -> Void)?
    }

    init(container: AppContainer) {
        self.router = AppRouter()

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

        toastBox.showToast = { [weak self] message, action in
            self?.showToast(message, action: action)
        }
        toastBox.dismissToast = { [weak self] in
            withAnimation(.bouncy) {
                self?.toast = .init()
            }
        }
    }

    func showToast(_ message: ToastMessage, action: (() -> Void)? = nil) {
        withAnimation(.bouncy) {
            toast = ToastState(message: message, action: action)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(message.duration))
            if toast.message == message {
                withAnimation(.bouncy) {
                    toast = .init()
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

// MARK: - Toast Callback Box

@MainActor
final class ToastCallbackBox {
    var showToast: ((ToastMessage, (() -> Void)?) -> Void)?
    var dismissToast: (() -> Void)?
}
