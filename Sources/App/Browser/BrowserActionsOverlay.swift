import SwiftUI

/// Reusable action button with hover state for popover menus
private struct ActionButton: View {
    let label: String
    let actionID: String
    var isHighlighted: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background {
                    if isHighlighted {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(isDestructive ? Color.red.opacity(0.8) : Color.accentColor)
                    } else {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("Action_\(actionID)")
    }

    private var foregroundColor: Color {
        if isHighlighted { return .white }
        if isDestructive { return .red }
        return .secondary
    }
}

struct BrowserActionsOverlay: View {
    @Bindable var viewModel: BrowserViewModel
    let focusSearchField: () -> Void
    let focusActionsDropdown: () -> Void
    @State private var isButtonHovered = false

    private enum ActionItem: Equatable {
        case delete
        case bookmark
        case unbookmark
        case copyOnly
        case defaultAction
    }

    private var actions: [ActionItem] {
        var items: [ActionItem] = []
        if let selectedItem = viewModel.selectedItem,
           selectedItem.itemMetadata.tags.contains(.bookmark) {
            items.append(.unbookmark)
        } else {
            items.append(.bookmark)
        }
        if case .autoPaste = AppSettings.shared.pasteMode {
            items.append(.copyOnly)
        }
        items.append(.delete)
        items.append(.defaultAction)
        return items
    }

    private var firstActionIndex: Int {
        0
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
                .background(RoundedRectangle(cornerRadius: 6).fill(isButtonHovered ? Color.primary.opacity(0.06) : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isButtonHovered = $0 }
        .accessibilityIdentifier("ActionsButton")
        .popover(isPresented: isPresented, arrowEdge: .top) {
            popoverContent
        }
    }

    private var popoverContent: some View {
        let highlightedIndex = overlayState.highlightedIndex
        return VStack(spacing: 2) {
            switch overlayState {
            case .actions:
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    actionButton(action: action, highlightedIndex: highlightedIndex, index: index)
                }
            case .confirmDelete:
                Text("Delete?")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)

                confirmButton(
                    label: String(localized: "Delete"),
                    actionID: "Delete",
                    highlighted: highlightedIndex == 0,
                    destructive: true
                ) {
                    viewModel.deleteSelectedItem()
                    viewModel.closeOverlay()
                }

                confirmButton(
                    label: String(localized: "Cancel"),
                    actionID: "Cancel",
                    highlighted: highlightedIndex == 1,
                    destructive: false
                ) {
                    viewModel.openActionsOverlay(highlightedIndex: firstActionIndex)
                }
            }
        }
        .padding(10)
        .frame(width: 160)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            switch overlayState {
            case .actions:
                viewModel.updateActionsHighlight(max(highlightedIndex - 1, 0))
            case .confirmDelete:
                viewModel.updateActionsHighlight(max(highlightedIndex - 1, 0))
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            switch overlayState {
            case .actions:
                viewModel.updateActionsHighlight(min(highlightedIndex + 1, actions.count - 1))
            case .confirmDelete:
                viewModel.updateActionsHighlight(min(highlightedIndex + 1, 1))
            }
            return .handled
        }
        .onKeyPress(.return, phases: .down) { _ in
            switch overlayState {
            case .actions:
                performAction(actions[highlightedIndex])
            case .confirmDelete:
                if highlightedIndex == 0 {
                    viewModel.deleteSelectedItem()
                    viewModel.closeOverlay()
                } else {
                    viewModel.openActionsOverlay(highlightedIndex: firstActionIndex)
                }
            }
            return .handled
        }
        .onKeyPress(.escape) {
            switch overlayState {
            case .confirmDelete:
                viewModel.openActionsOverlay(highlightedIndex: firstActionIndex)
            case .actions:
                viewModel.closeOverlay()
                focusSearchField()
            }
            return .handled
        }
        .onKeyPress(.tab) {
            viewModel.closeOverlay()
            focusSearchField()
            return .handled
        }
        .onAppear {
            if case .actions = overlayState {
                viewModel.updateActionsHighlight(firstActionIndex)
            }
            focusActionsDropdown()
        }
    }

    private func actionButton(action: ActionItem, highlightedIndex: Int, index: Int) -> some View {
        ActionButton(
            label: label(for: action),
            actionID: identifier(for: action),
            isHighlighted: highlightedIndex == index,
            isDestructive: action == .delete,
            action: { performAction(action) }
        )
    }

    private func confirmButton(
        label: String,
        actionID: String,
        highlighted: Bool,
        destructive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        ActionButton(
            label: label,
            actionID: actionID,
            isHighlighted: highlighted,
            isDestructive: destructive,
            action: action
        )
    }

    private func performAction(_ action: ActionItem) {
        switch action {
        case .defaultAction:
            viewModel.closeOverlay()
            viewModel.confirmSelection()
        case .copyOnly:
            viewModel.closeOverlay()
            viewModel.copyOnlySelection()
        case .bookmark:
            viewModel.closeOverlay()
            viewModel.addTagToSelectedItem(.bookmark)
        case .unbookmark:
            viewModel.closeOverlay()
            viewModel.removeTagFromSelectedItem(.bookmark)
        case .delete:
            viewModel.openDeleteConfirmation(highlightedIndex: 0)
        }
    }

    private func label(for action: ActionItem) -> String {
        switch action {
        case .defaultAction:
            return AppSettings.shared.pasteMode.buttonLabel
        case .copyOnly:
            return String(localized: "Copy")
        case .bookmark:
            return String(localized: "Bookmark")
        case .unbookmark:
            return String(localized: "Unbookmark")
        case .delete:
            return String(localized: "Delete")
        }
    }

    private func identifier(for action: ActionItem) -> String {
        switch action {
        case .defaultAction:
            return AppSettings.shared.pasteMode.buttonLabel
        case .copyOnly:
            return "Copy"
        case .bookmark:
            return "Bookmark"
        case .unbookmark:
            return "Unbookmark"
        case .delete:
            return "Delete"
        }
    }

    private var overlayState: ActionsOverlayState {
        guard case .actions(let state) = viewModel.session.overlays else {
            return .actions(highlightedIndex: firstActionIndex)
        }
        return state
    }
}
