import ClipKittyRust
import ClipKittyShared
import SwiftUI

struct ContentView: View {
    let store: ClipboardStore
    let onSelect: (String, ClipboardContent) -> Void
    let onCopyOnly: (String, ClipboardContent) -> Void
    let onDismiss: () -> Void
    let showSnackbarNotification: (NotificationRequest) -> Void
    let dismissSnackbarNotification: () -> Void
    var initialSearchQuery: String = ""

    @State private var viewModel: BrowserViewModel

    // `Files` support is a compile-time capability of this target; the shared
    // filter catalog receives it as data because the flag is not defined for
    // `ClipKittyShared`.
    #if ENABLE_FILE_CLIPBOARD_ITEMS
        private static let includesFileItems = true
    #else
        private static let includesFileItems = false
    #endif

    init(
        store: ClipboardStore,
        onSelect: @escaping (String, ClipboardContent) -> Void,
        onCopyOnly: @escaping (String, ClipboardContent) -> Void,
        onDismiss: @escaping () -> Void,
        showSnackbarNotification: @escaping (NotificationRequest) -> Void,
        dismissSnackbarNotification: @escaping () -> Void,
        initialSearchQuery: String = ""
    ) {
        self.store = store
        self.onSelect = onSelect
        self.onCopyOnly = onCopyOnly
        self.onDismiss = onDismiss
        self.showSnackbarNotification = showSnackbarNotification
        self.dismissSnackbarNotification = dismissSnackbarNotification
        self.initialSearchQuery = initialSearchQuery
        _viewModel = State(initialValue: BrowserViewModel(
            client: ClipboardStoreBrowserClient(store: store),
            filterCatalog: BrowserFilterCatalog(includesFileItems: Self.includesFileItems),
            onSelect: onSelect,
            onCopyOnly: onCopyOnly,
            onDismiss: onDismiss,
            showSnackbarNotification: showSnackbarNotification,
            dismissSnackbarNotification: dismissSnackbarNotification
        ))
    }

    var body: some View {
        let displayVersion = store.displayVersion
        let contentRevision = store.contentRevision
        let isPanelVisible = store.isPanelVisible

        return BrowserView(
            viewModel: viewModel,
            displayVersion: displayVersion,
            isPanelVisible: { store.isPanelVisible }
        )
        .onAppear {
            viewModel.onAppear(
                initialSearchQuery: initialSearchQuery,
                contentRevision: contentRevision
            )
        }
        .onChange(of: displayVersion) { _, _ in
            viewModel.handleDisplayReset(
                initialSearchQuery: initialSearchQuery,
                contentRevision: contentRevision
            )
        }
        .onChange(of: contentRevision) { _, newRevision in
            viewModel.handleContentRevisionChange(
                newRevision,
                isPanelVisible: isPanelVisible
            )
        }
        .onChange(of: isPanelVisible) { _, visible in
            viewModel.handlePanelVisibilityChange(
                visible,
                initialSearchQuery: initialSearchQuery,
                contentRevision: contentRevision
            )
        }
    }
}
