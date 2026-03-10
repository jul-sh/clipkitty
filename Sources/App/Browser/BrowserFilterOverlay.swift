import SwiftUI
import ClipKittyRust

struct BrowserFilterOverlay: View {
    @Bindable var viewModel: BrowserViewModel
    let options: [(ContentTypeFilter, String)]
    let focusTarget: FocusState<BrowserView.FocusTarget?>.Binding
    let focusSearchField: () -> Void

    /// Total items: options (All + categories) + Bookmarks
    /// Order: All, Bookmarks, Text, Images, Links, Colors, Files
    /// Index 0 = All, Index 1 = Bookmarks, Index 2+ = remaining categories
    private var totalItemCount: Int {
        options.count + 1 // +1 for Bookmarks
    }

    private var highlight: FilterOverlayState {
        guard case .filter(let state) = viewModel.session.overlays else { return .none }
        return state
    }

    var body: some View {
        VStack(spacing: 2) {
            // First item: All (from options[0])
            if let firstOption = options.first {
                filterButton(
                    label: firstOption.1,
                    index: 0,
                    action: {
                        viewModel.setTagFilter(nil)
                        viewModel.setContentTypeFilter(firstOption.0)
                    },
                    isSelected: viewModel.selectedTagFilter == nil && viewModel.contentTypeFilter == firstOption.0
                )
            }

            Divider().padding(.horizontal, 4).padding(.vertical, 3)

            // Second item: Bookmarks
            filterButton(
                label: String(localized: "Bookmarks"),
                index: 1,
                action: {
                    if viewModel.selectedTagFilter == .bookmark {
                        viewModel.setTagFilter(nil)
                    } else {
                        viewModel.setTagFilter(.bookmark)
                    }
                },
                isSelected: viewModel.selectedTagFilter == .bookmark
            )

            Divider().padding(.horizontal, 4).padding(.vertical, 3)

            // Remaining categories (skip first which is "All")
            ForEach(Array(options.dropFirst().enumerated()), id: \.offset) { index, entry in
                let (option, label) = entry
                filterButton(
                    label: label,
                    index: index + 2, // +2 because All=0, Bookmarks=1
                    action: {
                        viewModel.setTagFilter(nil)
                        viewModel.setContentTypeFilter(option)
                    },
                    isSelected: viewModel.selectedTagFilter == nil && viewModel.contentTypeFilter == option
                )
            }
        }
        .padding(10)
        .frame(width: 160)
        .focusable()
        .focused(focusTarget, equals: .filterDropdown)
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
            activateHighlightedItem()
            return .handled
        }
        .onKeyPress(.escape) {
            viewModel.closeOverlay()
            focusSearchField()
            return .handled
        }
        .onKeyPress(.tab) {
            viewModel.closeOverlay()
            focusSearchField()
            return .handled
        }
    }

    private func moveHighlight(by offset: Int) {
        let currentIndex: Int
        switch highlight {
        case .none:
            currentIndex = offset >= 0 ? -1 : totalItemCount
        case .index(let index):
            currentIndex = index
        }
        let newIndex = max(0, min(totalItemCount - 1, currentIndex + offset))
        viewModel.setFilterOverlayState(.index(newIndex))
    }

    private func activateHighlightedItem() {
        guard case .index(let index) = highlight else {
            viewModel.closeOverlay()
            focusSearchField()
            return
        }
        performAction(at: index)
        viewModel.closeOverlay()
        focusSearchField()
    }

    private func performAction(at index: Int) {
        switch index {
        case 0:
            // All
            if let firstOption = options.first {
                viewModel.setTagFilter(nil)
                viewModel.setContentTypeFilter(firstOption.0)
            }
        case 1:
            // Bookmarks
            if viewModel.selectedTagFilter == .bookmark {
                viewModel.setTagFilter(nil)
            } else {
                viewModel.setTagFilter(.bookmark)
            }
        default:
            // Categories (index 2+ maps to options[index-1])
            let categoryIndex = index - 1
            if options.indices.contains(categoryIndex) {
                viewModel.setTagFilter(nil)
                viewModel.setContentTypeFilter(options[categoryIndex].0)
            }
        }
    }

    private func filterButton(
        label: String,
        index: Int,
        action: @escaping () -> Void,
        isSelected: Bool
    ) -> some View {
        let isHighlighted: Bool
        if case .index(let highlightedIndex) = highlight {
            isHighlighted = highlightedIndex == index
        } else {
            isHighlighted = false
        }

        return FilterRowButton(
            label: label,
            isHighlighted: isHighlighted,
            isSelected: isSelected,
            onHover: { isHovered in
                if isHovered {
                    viewModel.setFilterOverlayState(.index(index))
                }
            }
        ) {
            action()
            viewModel.closeOverlay()
            focusSearchField()
        }
    }
}

/// Filter row button with hover state.
/// Supports highlighted state for keyboard navigation.
private struct FilterRowButton: View {
    let label: String
    let isHighlighted: Bool
    let isSelected: Bool
    let onHover: (Bool) -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(isHighlighted ? .white : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(isHighlighted ? Color.accentColor : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { onHover($0) }
    }
}
