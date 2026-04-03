import SwiftUI

struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(SceneState.self) private var sceneState

    var body: some View {
        Group {
            switch sizeClass {
            case .regular:
                RegularShell()
            default:
                CompactShell()
            }
        }
        .onChange(of: sizeClass) { oldValue, newValue in
            switch (oldValue, newValue) {
            case (.regular, .compact):
                // Regular → compact: carry detail selection into the navigation stack.
                if case let .selected(itemId) = sceneState.detailSelection {
                    sceneState.previewItemId = itemId
                    sceneState.detailSelection = .none
                }
            case (.compact, .regular):
                // Compact → regular: restore detail pane from the navigation stack.
                if let itemId = sceneState.previewItemId {
                    sceneState.detailSelection = .selected(itemId: itemId)
                    sceneState.previewItemId = nil
                }
            default:
                break
            }
        }
    }
}
