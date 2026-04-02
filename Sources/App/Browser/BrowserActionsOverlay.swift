import SwiftUI

struct BrowserActionsOverlay: View {
    @Bindable var viewModel: BrowserViewModel
    let focusSearchField: () -> Void
    let focusTarget: FocusState<BrowserView.FocusTarget?>.Binding

    private var actions: [BrowserActionItem] {
        BrowserActionItem.items(for: viewModel.selectedItem?.itemMetadata.tags ?? [])
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: {
                if case .actions = viewModel.overlayState {
                    return true
                }
                return false
            },
            set: { newValue in
                if !newValue {
                    viewModel.closeOverlay()
                }
            }
        )
    }

    private var menuHighlight: Binding<MenuHighlightState> {
        Binding(
            get: {
                guard case let .actions(highlight) = viewModel.overlayState else {
                    return .none
                }
                return highlight
            },
            set: { newHighlight in
                viewModel.setActionsOverlayState(newHighlight)
            }
        )
    }

    var body: some View {
        Button {
            if case .actions = viewModel.overlayState {
                viewModel.closeOverlay()
            } else {
                // Mouse click opens with no highlight - hover will control it
                viewModel.openActionsOverlay(highlight: .none)
            }
        } label: {
            Text("⌘K Actions")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .subtleHover()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ActionsButton")
        .popover(isPresented: isPresented, arrowEdge: .top) {
            BrowserActionMenu(
                items: actions,
                highlight: menuHighlight,
                focusSearchField: focusSearchField,
                focusTarget: focusTarget,
                performAction: { action in
                    guard let itemId = viewModel.selectedItemId else { return }
                    viewModel.performAction(
                        action,
                        itemId: itemId,
                        dismissOverlay: viewModel.closeOverlay
                    )
                },
                dismiss: viewModel.closeOverlay
            )
        }
    }
}
