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
            viewModel.updateFilterHighlight(max(highlightedIndex - 1, 0))
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.updateFilterHighlight(min(highlightedIndex + 1, totalItemCount - 1))
            return .handled
        }
        .onKeyPress(.return, phases: .down) { _ in
            selectHighlightedItem()
            viewModel.closeOverlay()
            focusSearchField()
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

    private var highlightedIndex: Int {
        guard case .filter(let state) = viewModel.session.overlays else { return 0 }
        return state.highlightedIndex
    }

    private func selectHighlightedItem() {
        switch highlightedIndex {
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
            let categoryIndex = highlightedIndex - 1
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
        Button {
            action()
            viewModel.closeOverlay()
            focusSearchField()
        } label: {
            rowLabel(
                label,
                highlighted: highlightedIndex == index,
                selected: isSelected
            )
        }
        .buttonStyle(.plain)
    }

    private func rowLabel(_ label: String, highlighted: Bool, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 13))
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundStyle(highlighted ? .white : .secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .fill(highlighted ? Color.accentColor : Color.clear)
        }
    }
}
