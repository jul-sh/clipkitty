import ClipKittyBrowser
import ClipKittyMacPlatform
import ClipKittyRust
import SwiftUI

struct BrowserSearchBar: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var runtimeState = AppRuntimeState.shared
    @Environment(\.colorScheme) private var colorScheme
    @Binding var searchText: String
    let appliedFilter: BrowserFilterDescriptor?
    let contentState: BrowserContentState
    let selectedItemAvailable: Bool
    let hasPendingEdit: Bool
    let focusTarget: FocusState<BrowserView.FocusTarget?>.Binding
    let onMoveSelection: (Int) -> Void
    let onConfirm: () -> Void
    let onAcceptPendingFilter: () -> Void
    let onDismiss: () -> Void
    let onClearFilter: () -> Void
    let onOpenActions: (_ viaKeyboard: Bool) -> Void
    let onDelete: () -> Void
    let onDiscardEdit: () -> Void
    let onSaveEdit: () -> Void
    let onHandleNumberKey: (KeyPress) -> KeyPress.Result

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(settings.appFont(size: runtimeState.scaled(17), weight: .medium))

            if let appliedFilter {
                AppliedFilterChip(descriptor: appliedFilter, onRemove: onClearFilter)
            }

            TextField("Clipboard History Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(settings.appFont(size: runtimeState.scaled(17)))
                .tint(.primary)
                .focused(focusTarget, equals: .search)
                .id(colorScheme)
                .accessibilityIdentifier("SearchField")
                // Suppress system text-suggestion / Writing Tools popovers
                // that would otherwise overlay the result list when focus
                // returns to the search field.
                .autocorrectionDisabled()
                .textContentType(.none)
                .modifier(DisableWritingTools())
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
                .onKeyPress("s", phases: .down) { keyPress in
                    guard keyPress.modifiers.contains(.command), hasPendingEdit else {
                        return .ignored
                    }
                    onSaveEdit()
                    return .handled
                }
                .onKeyPress(.escape) {
                    if hasPendingEdit {
                        onDiscardEdit()
                    } else {
                        onDismiss()
                    }
                    return .handled
                }
                .onKeyPress(.tab) {
                    // Tab accepts the visible filter suggestion, autocomplete
                    // style (a no-op without one). Always handled either way:
                    // the panel is modal-like, so Tab must not move focus out
                    // of the search field.
                    onAcceptPendingFilter()
                    return .handled
                }
                .onKeyPress(characters: .decimalDigits, phases: .down) { keyPress in
                    onHandleNumberKey(keyPress)
                }
                .onKeyPress(.delete, phases: .down) { _ in
                    guard selectedItemAvailable else { return .ignored }
                    onDelete()
                    return .handled
                }
                .onKeyPress(.deleteForward, phases: .down) { _ in
                    guard selectedItemAvailable else { return .ignored }
                    onDelete()
                    return .handled
                }

            switch contentState {
            case .loading(_, _, .runningShowingSpinner):
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            case .idle,
                 .loading(_, _, .debouncing),
                 .loading(_, _, .runningWaitingForSpinner),
                 .loaded,
                 .failed:
                EmptyView()
            }
        }
        // Keep optional controls from resizing the row when they appear. The
        // height scales with the search text so larger accessibility sizes
        // still have enough room for both the field and the filter chip.
        .frame(height: runtimeState.scaled(24))
        .padding(.horizontal, 17)
        .padding(.vertical, 15)
    }
}

/// The active filter rendered inside the search bar chrome, removable via its
/// close control (or Backspace in the empty field).
private struct AppliedFilterChip: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var runtimeState = AppRuntimeState.shared
    let descriptor: BrowserFilterDescriptor
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: descriptor.symbolName)
                .font(.system(size: runtimeState.scaled(10), weight: .semibold))
            Text(descriptor.title)
                .font(settings.appFont(size: runtimeState.scaled(12), weight: .semibold))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: runtimeState.scaled(8), weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Remove filter"))
            .accessibilityIdentifier("AppliedFilterChipRemove")
        }
        .foregroundStyle(.primary)
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("AppliedFilterChip")
    }
}

private struct DisableWritingTools: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.1, *) {
            content.writingToolsBehavior(.disabled)
        } else {
            content
        }
    }
}
