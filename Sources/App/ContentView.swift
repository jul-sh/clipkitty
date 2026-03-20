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
        BrowserView(viewModel: viewModel, displayVersion: store.displayVersion)
            .onAppear {
                viewModel.onAppear(initialSearchQuery: initialSearchQuery)
            }
            .onChange(of: store.displayVersion) { _, _ in
                viewModel.handleDisplayReset(initialSearchQuery: initialSearchQuery)
            }
    }
}
