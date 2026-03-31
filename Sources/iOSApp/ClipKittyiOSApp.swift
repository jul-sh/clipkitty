import ClipKittyAppleServices
import ClipKittyRust
import ClipKittyShared
import SwiftUI

@MainActor
@Observable
final class AppState {
    let repository: ClipboardRepository
    let previewLoader: PreviewLoader
    let storeClient: iOSBrowserStoreClient
    let clipboardService: iOSClipboardService
    let viewModel: BrowserViewModel

    var toastMessage: ToastMessage?
    var contentRevision: Int = 0

    init() {
        let dbPath = Self.databasePath()
        let store = try! ClipKittyRust.ClipboardStore(dbPath: dbPath)
        let repository = ClipboardRepository(store: store)
        let previewLoader = PreviewLoader(repository: repository)
        let storeClient = iOSBrowserStoreClient(repository: repository, previewLoader: previewLoader)
        let clipboardService = iOSClipboardService()

        self.repository = repository
        self.previewLoader = previewLoader
        self.storeClient = storeClient
        self.clipboardService = clipboardService

        // Use a box to capture toast callback — wired after init via the box
        let toastBox = ToastCallbackBox()

        self.viewModel = BrowserViewModel(
            client: storeClient,
            onSelect: { _, content in
                clipboardService.copy(content: content)
                HapticFeedback.copy()
                toastBox.showToast?(.copied)
            },
            onCopyOnly: { _, content in
                clipboardService.copy(content: content)
                HapticFeedback.copy()
                toastBox.showToast?(.copied)
            },
            onDismiss: {},
            showSnackbarNotification: { kind, _ in
                toastBox.showToast?(.notification(kind))
            },
            dismissSnackbarNotification: {
                toastBox.dismissToast?()
            }
        )

        // Wire the box to self after all stored properties are initialized
        toastBox.showToast = { [weak self] message in
            self?.showToast(message)
        }
        toastBox.dismissToast = { [weak self] in
            self?.toastMessage = nil
        }
    }

    func showToast(_ message: ToastMessage) {
        toastMessage = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(message.duration))
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }

    func refreshFeed() {
        contentRevision += 1
        viewModel.handlePanelVisibilityChange(true, contentRevision: contentRevision)
    }

    private static func databasePath() -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let appDir = appSupport.appendingPathComponent("ClipKitty", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("clipboard.db").path
    }
}

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
        case .copied: return "Copied to clipboard"
        case .bookmarked: return "Bookmarked"
        case .unbookmarked: return "Removed bookmark"
        case .saved: return "Saved"
        case .deleted: return "Deleted"
        case .addSucceeded: return "Added"
        case let .addFailed(reason): return "Failed: \(reason)"
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
    var showToast: ((ToastMessage) -> Void)?
    var dismissToast: (() -> Void)?
}

@main
struct ClipKittyiOSApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            HomeFeedView()
                .environment(appState)
                .environment(appState.viewModel)
        }
    }
}
