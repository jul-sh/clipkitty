import SwiftUI

struct BrowserActionsOverlay: View {
    @Bindable var viewModel: BrowserViewModel
    let focusSearchField: () -> Void
    let focusActionsDropdown: () -> Void

    private let firstActionIndex = 0

    private var actions: [BrowserActionItem] {
        BrowserActionItem.items(for: viewModel.selectedItem?.itemMetadata.tags ?? [])
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: {
                if case .actions = viewModel.session.overlays {
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
                guard case .actions(let highlight) = viewModel.session.overlays else {
                    return .index(firstActionIndex)
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
            if case .actions = viewModel.session.overlays {
                viewModel.closeOverlay()
            } else {
                viewModel.openActionsOverlay(highlightedIndex: firstActionIndex)
                focusActionsDropdown()
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
                interaction: .keyboard(
                    focusOnAppear: focusActionsDropdown,
                    dismissToSearch: focusSearchField,
                    tabToSearch: focusSearchField
                ),
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
