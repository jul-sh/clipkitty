import SwiftUI
import ClipKittyRust

struct BrowserSearchBar<FilterPopoverContent: View>: View {
    @Binding var searchText: String
    let filterLabel: String
    let searchSpinnerVisible: Bool
    let selectedItemAvailable: Bool
    let isFilterPopoverPresented: Binding<Bool>
    let focusTarget: FocusState<BrowserView.FocusTarget?>.Binding
    let onMoveSelection: (Int) -> Void
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    let onOpenFilter: (_ viaKeyboard: Bool) -> Void
    let onOpenActions: (_ viaKeyboard: Bool) -> Void
    let onDelete: () -> Void
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
                .tint(.primary)
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
                        onOpenActions(true)
                    }
                    return .handled
                }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
                .onKeyPress(.tab) {
                    onOpenFilter(true)
                    return .handled
                }
                .onKeyPress(characters: .decimalDigits, phases: .down) { keyPress in
                    onHandleNumberKey(keyPress)
                }
                .onKeyPress(.delete) {
                    guard selectedItemAvailable else { return .ignored }
                    onDelete()
                    return .handled
                }
                .onKeyPress(.deleteForward) {
                    guard selectedItemAvailable else { return .ignored }
                    onDelete()
                    return .handled
                }

            if searchSpinnerVisible {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }

            Button(action: { onOpenFilter(false) }) {
                HStack(spacing: 4) {
                    Text(filterLabel)
                        .font(.system(size: 13))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .subtleHoverCapsuleWithBorder()
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

}
