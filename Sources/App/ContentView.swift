import ClipKittyRust
import SwiftUI

@MainActor
final class BrowserViewContext {
    let viewModel: BrowserViewModel
    let focusBridge = BrowserFocusBridge()

    init(
        store: ClipboardStore,
        onSelect: @escaping (Int64, ClipboardContent) -> Void,
        onCopyOnly: @escaping (Int64, ClipboardContent) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        viewModel = BrowserViewModel(
            client: ClipboardStoreBrowserClient(store: store),
            onSelect: onSelect,
            onCopyOnly: onCopyOnly,
            onDismiss: onDismiss
        )
    }
}

struct ContentView: View {
    let store: ClipboardStore
    let context: BrowserViewContext
    var initialSearchQuery: String = ""

    var body: some View {
        BrowserView(
            viewModel: context.viewModel,
            focusBridge: context.focusBridge,
            displayVersion: store.displayVersion
        )
            .onAppear {
                context.viewModel.onAppear(initialSearchQuery: initialSearchQuery)
                context.focusBridge.request(.search)
            }
            .onChange(of: store.displayVersion) { _, _ in
                context.viewModel.handleDisplayReset(initialSearchQuery: initialSearchQuery)
                context.focusBridge.request(.search)
            }
    }
}
