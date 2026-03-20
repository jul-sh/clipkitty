import ClipKittyRust
import SwiftUI

struct ContentView: View {
    let store: ClipboardStore
    let onSelect: (Int64, ClipboardContent) -> Void
    let onCopyOnly: (Int64, ClipboardContent) -> Void
    let onDismiss: () -> Void
    var initialSearchQuery: String = ""

    @State private var viewModel: BrowserViewModel

    init(
        store: ClipboardStore,
        onSelect: @escaping (Int64, ClipboardContent) -> Void,
        onCopyOnly: @escaping (Int64, ClipboardContent) -> Void,
        onDismiss: @escaping () -> Void,
        initialSearchQuery: String = ""
    ) {
        self.store = store
        self.onSelect = onSelect
        self.onCopyOnly = onCopyOnly
        self.onDismiss = onDismiss
        self.initialSearchQuery = initialSearchQuery
        _viewModel = State(initialValue: BrowserViewModel(
            client: ClipboardStoreBrowserClient(store: store),
            onSelect: onSelect,
            onCopyOnly: onCopyOnly,
            onDismiss: onDismiss
        ))
    }

    var body: some View {
        let displayVersion = store.displayVersion
        let contentRevision = store.contentRevision
        let isPanelVisible = store.isPanelVisible

        return BrowserView(viewModel: viewModel, displayVersion: displayVersion)
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
