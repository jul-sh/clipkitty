import SwiftUI
import ClipKittyRust

struct BrowserFilterOverlay: View {
    @Bindable var viewModel: BrowserViewModel
    let options: [(ContentTypeFilter, String)]
    let focusTarget: FocusState<BrowserView.FocusTarget?>.Binding
    let focusSearchField: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, entry in
                let (option, label) = entry
                if index == 1 {
                    Divider().padding(.horizontal, 4).padding(.vertical, 3)
                }
                Button {
                    viewModel.setContentTypeFilter(option)
                    viewModel.closeOverlay()
                    focusSearchField()
                } label: {
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundStyle(highlightedIndex == index ? .white : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(highlightedIndex == index ? Color.accentColor : Color.clear)
                        }
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
            viewModel.updateFilterHighlight(min(highlightedIndex + 1, options.count - 1))
            return .handled
        }
        .onKeyPress(.return, phases: .down) { _ in
            let selected = options[highlightedIndex]
            viewModel.setContentTypeFilter(selected.0)
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
}
