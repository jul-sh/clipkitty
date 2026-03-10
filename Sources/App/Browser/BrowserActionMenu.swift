import SwiftUI
import ClipKittyRust

@MainActor
enum BrowserActionItem: Equatable {
    case delete
    case bookmark
    case unbookmark
    case copyOnly
    case defaultAction

    static func items(for tags: [ItemTag]) -> [BrowserActionItem] {
        var items: [BrowserActionItem] = []
        if tags.contains(.bookmark) {
            items.append(.unbookmark)
        } else {
            items.append(.bookmark)
        }
        if case .autoPaste = AppSettings.shared.pasteMode {
            items.append(.copyOnly)
        }
        items.append(.defaultAction)
        items.append(.delete)
        return items
    }

    var label: String {
        switch self {
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

    var identifier: String {
        switch self {
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

    var systemImageName: String {
        switch self {
        case .defaultAction:
            switch AppSettings.shared.pasteMode {
            case .autoPaste:
                return "doc.on.clipboard"
            case .copyOnly, .noPermission:
                return "doc.on.doc"
            }
        case .copyOnly:
            return "doc.on.doc"
        case .bookmark:
            return "bookmark"
        case .unbookmark:
            return "bookmark.slash"
        case .delete:
            return "trash"
        }
    }

    var isDestructive: Bool {
        if case .delete = self {
            return true
        }
        return false
    }

    static func showsDivider(before index: Int, in items: [BrowserActionItem]) -> Bool {
        guard items.indices.contains(index), index > 0 else { return false }
        return items[index].isDestructive
    }
}

enum BrowserActionMenuInteraction {
    case pointer
    case keyboard(
        focusOnAppear: () -> Void,
        dismissToSearch: () -> Void,
        tabToSearch: () -> Void
    )
}

struct BrowserActionMenu: View {
    let items: [BrowserActionItem]
    @Binding var highlight: MenuHighlightState
    let interaction: BrowserActionMenuInteraction
    let performAction: (BrowserActionItem) -> Void
    let dismiss: () -> Void

    var body: some View {
        let baseMenu = VStack(spacing: 2) {
            actionsList(highlight: highlight)
        }
        .padding(10)
        .frame(width: 160)

        switch interaction {
        case .pointer:
            baseMenu
        case .keyboard(let focusOnAppear, let dismissToSearch, let tabToSearch):
            baseMenu
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.upArrow) {
                    moveHighlight(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveHighlight(by: 1)
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { _ in
                    activateHighlightedAction()
                    return .handled
                }
                .onKeyPress(.escape) {
                    dismiss()
                    dismissToSearch()
                    return .handled
                }
                .onKeyPress(.tab) {
                    dismiss()
                    tabToSearch()
                    return .handled
                }
                .onAppear(perform: focusOnAppear)
        }
    }

    @ViewBuilder
    private func actionsList(highlight: MenuHighlightState) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { index, action in
            if BrowserActionItem.showsDivider(before: index, in: items) {
                Divider()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
            }

            ActionOptionRow(
                label: action.label,
                actionID: action.identifier,
                systemImageName: action.systemImageName,
                isHighlighted: isHighlighted(index: index, in: highlight),
                isDestructive: action.isDestructive
            ) {
                performAction(action)
            }
        }
    }

    private func moveHighlight(by offset: Int) {
        let highlightedIndex = nextIndex(from: highlight, offset: offset, upperBound: items.count - 1)
        highlight = .index(highlightedIndex)
    }

    private func activateHighlightedAction() {
        guard case .index(let highlightedIndex) = highlight else { return }
        guard items.indices.contains(highlightedIndex) else { return }
        let action = items[highlightedIndex]
        performAction(action)
    }

    private func isHighlighted(index: Int, in highlight: MenuHighlightState) -> Bool {
        if case .index(let highlightedIndex) = highlight {
            return highlightedIndex == index
        }
        return false
    }

    private func nextIndex(from highlight: MenuHighlightState, offset: Int, upperBound: Int) -> Int {
        let startingIndex: Int
        switch highlight {
        case .none:
            startingIndex = offset >= 0 ? -1 : upperBound + 1
        case .index(let index):
            startingIndex = index
        }
        return max(0, min(upperBound, startingIndex + offset))
    }
}
