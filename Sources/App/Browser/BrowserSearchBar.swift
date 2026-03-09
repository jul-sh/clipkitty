import SwiftUI
import ClipKittyRust

struct BrowserSearchBar<FilterPopoverContent: View>: View {
    @Binding var searchText: String
    let filter: ContentTypeFilter
    let filterOptions: [(ContentTypeFilter, String)]
    let searchSpinnerVisible: Bool
    let selectedItemAvailable: Bool
    let isFilterPopoverPresented: Binding<Bool>
    let focusTarget: FocusState<BrowserView.FocusTarget?>.Binding
    let onMoveSelection: (Int) -> Void
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    let onOpenFilter: () -> Void
    let onOpenActions: () -> Void
    let onOpenDeleteConfirm: () -> Void
    let onHandleNumberKey: (KeyPress) -> KeyPress.Result
    @ViewBuilder let filterPopoverContent: () -> FilterPopoverContent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.custom(FontManager.sansSerif, size: 17).weight(.medium))

            TextField("Clipboard History Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.custom(FontManager.sansSerif, size: 17))
                .tint(.accentColor)
                .focused(focusTarget, equals: .search)
                .accessibilityIdentifier("SearchField")
                .onKeyPress(.upArrow) {
                    onMoveSelection(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    onMoveSelection(1)
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { _ in
                    onConfirm()
                    return .handled
                }
                .onKeyPress("k", phases: .down) { keyPress in
                    guard keyPress.modifiers.contains(.command) else {
                        return .ignored
                    }
                    if selectedItemAvailable {
                        onOpenActions()
                    }
                    return .handled
                }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
                .onKeyPress(.tab) {
                    onOpenFilter()
                    return .handled
                }
                .onKeyPress(characters: .decimalDigits, phases: .down) { keyPress in
                    onHandleNumberKey(keyPress)
                }
                .onKeyPress(.delete) {
                    guard selectedItemAvailable else { return .ignored }
                    onOpenDeleteConfirm()
                    return .handled
                }
                .onKeyPress(.deleteForward) {
                    guard selectedItemAvailable else { return .ignored }
                    onOpenDeleteConfirm()
                    return .handled
                }

            if searchSpinnerVisible {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }

            Button(action: onOpenFilter) {
                HStack(spacing: 4) {
                    Text(filterLabel)
                        .font(.system(size: 13))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("FilterDropdown")
            .popover(isPresented: isFilterPopoverPresented, arrowEdge: .bottom) {
                filterPopoverContent()
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
    }

    private var filterLabel: String {
        filterOptions.first(where: { $0.0 == filter })?.1 ?? String(localized: "All Types")
    }
}
