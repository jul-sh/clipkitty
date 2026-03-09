import SwiftUI

struct BrowserActionsOverlay: View {
    @Bindable var viewModel: BrowserViewModel
    let focusSearchField: () -> Void
    let focusActionsDropdown: () -> Void

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
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
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
        Button {
            performAction(action)
        } label: {
            Text(label(for: action))
                .font(.system(size: 13))
                .foregroundStyle(highlightedIndex == index ? .white : action == .delete ? .red : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(highlightedIndex == index ? (action == .delete ? Color.red.opacity(0.8) : Color.accentColor) : Color.clear)
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Action_\(identifier(for: action))")
    }

    private func confirmButton(
        label: String,
        actionID: String,
        highlighted: Bool,
        destructive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(highlighted ? .white : destructive ? .red : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(highlighted ? (destructive ? Color.red.opacity(0.8) : Color.accentColor) : Color.clear)
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Action_\(actionID)")
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
