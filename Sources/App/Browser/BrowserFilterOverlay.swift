import SwiftUI
import ClipKittyRust

struct BrowserFilterOverlay: View {
    @Bindable var viewModel: BrowserViewModel
    let options: [(ContentTypeFilter, String)]
    let focusTarget: FocusState<BrowserView.FocusTarget?>.Binding
    let focusSearchField: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            Button {
                if viewModel.selectedTagFilter == .pinned {
                    viewModel.setTagFilter(nil)
                } else {
                    viewModel.setTagFilter(.pinned)
                }
                viewModel.closeOverlay()
                focusSearchField()
            } label: {
                rowLabel(
                    "Pinned",
                    highlighted: highlightedIndex == 0,
                    selected: viewModel.selectedTagFilter == .pinned
                )
            }
            .buttonStyle(.plain)

            Divider().padding(.horizontal, 4).padding(.vertical, 3)

            ForEach(Array(options.enumerated()), id: \.offset) { index, entry in
                let (option, label) = entry
                Button {
                    viewModel.setContentTypeFilter(option)
                    viewModel.closeOverlay()
                    focusSearchField()
                } label: {
                    rowLabel(
                        label,
                        highlighted: highlightedIndex == index + 1,
                        selected: viewModel.selectedTagFilter == nil && viewModel.contentTypeFilter == option
                    )
                }
                .buttonStyle(.plain)
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
            viewModel.updateFilterHighlight(min(highlightedIndex + 1, options.count))
            return .handled
        }
        .onKeyPress(.return, phases: .down) { _ in
            if highlightedIndex == 0 {
                if viewModel.selectedTagFilter == .pinned {
                    viewModel.setTagFilter(nil)
                } else {
                    viewModel.setTagFilter(.pinned)
                }
            } else {
                let selected = options[highlightedIndex - 1]
                viewModel.setContentTypeFilter(selected.0)
            }
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
