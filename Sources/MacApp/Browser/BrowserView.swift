import AppKit
import ClipKittyBrowser
import ClipKittyMacPlatform
import ClipKittyRust
import KeyboardShortcuts
import Observation
import SwiftUI

struct BrowserView: View {
    @Bindable var viewModel: BrowserViewModel
    let displayVersion: Int
    let isPanelVisible: () -> Bool

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var runtimeState = AppRuntimeState.shared
    @State private var commandKeyEventMonitor: Any?
    @FocusState private var focusTarget: FocusTarget?

    enum FocusTarget: Hashable {
        case search
        case actionsDropdown
    }

    var body: some View {
        VStack(spacing: 0) {
            BrowserSearchBar(
                searchText: Binding(
                    get: { viewModel.searchText },
                    set: { viewModel.updateSearchText($0) }
                ),
                appliedFilter: viewModel.appliedFilterDescriptor,
                contentState: viewModel.contentState,
                // Row-only shortcuts (Cmd+K, delete item) must not fire while
                // the pending filter chip is the keyboard target.
                selectedItemAvailable: {
                    switch viewModel.keyboardTarget {
                    case .pendingFilterChip: return false
                    case .results: return viewModel.selectedItem != nil
                    }
                }(),
                hasPendingEdit: {
                    guard let selectedItemId = viewModel.selectedItemId else { return false }
                    if case let .dirty(dirtyId, _) = viewModel.editSession {
                        return dirtyId == selectedItemId
                    }
                    return false
                }(),
                focusTarget: $focusTarget,
                onMoveSelection: viewModel.moveSelection(by:),
                onConfirm: viewModel.confirmSelection,
                onAcceptPendingFilter: {
                    viewModel.applyPendingFilterSuggestion()
                    focusSearchField()
                },
                onDismiss: viewModel.dismiss,
                // Removing the chip must keep the keyboard in the search
                // field, matching the other button-driven flows.
                onClearFilter: {
                    viewModel.clearAppliedFilter()
                    focusSearchField()
                },
                onOpenActions: openActionsOverlay,
                onDelete: viewModel.deleteSelectedItem,
                onDiscardEdit: viewModel.discardCurrentEdit,
                onSaveEdit: {
                    viewModel.commitCurrentEdit()
                    focusSearchField()
                },
                onHandleNumberKey: handleNumberKey
            )

            Divider()

            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SelectedIndex_\(viewModel.selectedIndex ?? -1)")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color.clear
                .clipKittyWindowGlassBackground()
                .ignoresSafeArea(.all)
        )
        .overlay(alignment: .bottom) {
            if let message = viewModel.mutationFailureMessage {
                mutationFailureBanner(message: message)
                    .padding(.bottom, 12)
            }
        }
        .ignoresSafeArea(edges: .top)
        .onAppear {
            installCommandKeyEventMonitor()
            focusSearchField()
        }
        .onDisappear {
            removeCommandKeyEventMonitor()
        }
        .onChange(of: displayVersion) { _, _ in
            focusSearchField()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.contentState {
        case let .failed(_, message, _):
            BrowserPreviewPane.error(message)
        case .idle, .loading, .loaded:
            HStack(spacing: 0) {
                BrowserResultsList(
                    viewModel: viewModel,
                    displayVersion: displayVersion,
                    focusSearchField: focusSearchField
                )
                .frame(width: runtimeState.scaled(324))

                Divider()

                BrowserPreviewPane(
                    viewModel: viewModel,
                    focusSearchField: focusSearchField,
                    focusTarget: $focusTarget
                )
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Opens actions overlay
    /// - Parameter viaKeyboard: If true (keyboard trigger), highlights first item for immediate arrow nav.
    ///                          If false (mouse trigger), no initial highlight - hover will control it.
    private func openActionsOverlay(viaKeyboard: Bool) {
        guard viewModel.selectedItem != nil else { return }
        if case .actions = viewModel.overlayState, viaKeyboard {
            viewModel.closeOverlay()
            return
        }
        let highlight: MenuHighlightState = viaKeyboard ? .index(0) : .none
        viewModel.openActionsOverlay(highlight: highlight)
        if viaKeyboard {
            focusActionsDropdown()
        }
    }

    private func handleNumberKey(_ keyPress: KeyPress) -> KeyPress.Result {
        guard let number = Int(keyPress.characters),
              number >= 1 && number <= 9,
              keyPress.modifiers.contains(.command),
              handleCommandNumberShortcut(number)
        else {
            return .ignored
        }
        return .handled
    }

    private func handleCommandNumberShortcut(_ number: Int) -> Bool {
        // Numbers always address rows, even while the pending filter chip is
        // the keyboard target: selecting a row hands the keyboard back to the
        // results, so the confirm activates the item, not the filter.
        let index = number - 1
        guard viewModel.itemIds.indices.contains(index) else { return false }
        let itemId = viewModel.itemIds[index]
        viewModel.select(itemId: itemId, origin: .keyboard)
        viewModel.confirmSelection()
        return true
    }

    private func setFocus(to target: FocusTarget, delay: Duration = .milliseconds(1)) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            focusTarget = target
        }
    }

    private func focusSearchField() {
        setFocus(to: .search)
    }

    private func focusActionsDropdown() {
        setFocus(to: .actionsDropdown, delay: .milliseconds(50))
    }

    @MainActor
    private func installCommandKeyEventMonitor() {
        guard commandKeyEventMonitor == nil else { return }
        commandKeyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isPanelVisible() else { return event }

            if let number = commandNumber(from: event) {
                return handleCommandNumberShortcut(number) ? nil : event
            }

            // Backspace in the empty search field removes the applied filter
            // chip. ⌥⌫ and ⌘⌫ count too: their word/line deletes have nothing
            // left to act on in an empty field, so they fall through to the
            // chip like a plain ⌫. Handled here because the field editor
            // consumes the key before SwiftUI's onKeyPress sees it. The
            // field-editor check keeps preview-pane editing (a plain
            // NSTextView) unaffected.
            let backspaceModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if backspaceModifiers.isSubset(of: [.option, .command]),
               event.keyCode == 51, // ⌫
               !event.isARepeat,
               let editor = event.window?.firstResponder as? NSTextView,
               editor.isFieldEditor,
               viewModel.searchText.isEmpty,
               viewModel.appliedFilterDescriptor != nil
            {
                viewModel.clearAppliedFilter()
                return nil
            }

            // Configurable delete-item shortcut (default ⌘-). Suppressed while
            // the pending filter chip is the keyboard target — row-only
            // shortcuts must not fire at the chip.
            switch AppSettings.shared.deleteItemShortcutSetting {
            case let .enabled(shortcut):
                if KeyboardShortcuts.Shortcut(event: event) == shortcut,
                   !event.isARepeat,
                   viewModel.selectedItem != nil,
                   case .results = viewModel.keyboardTarget
                {
                    viewModel.deleteSelectedItem()
                    return nil
                }
            case .disabled:
                break
            }

            // While a delete is pending, Cmd+Z intentionally undoes the item
            // delete instead of text undo; otherwise the event passes through
            // unchanged so the field editor keeps its text undo.
            if backspaceModifiers == .command,
               event.charactersIgnoringModifiers == "z",
               case .deleting(.pending) = viewModel.mutationState
            {
                viewModel.undoPendingDelete()
                return nil
            }

            return event
        }
    }

    @MainActor
    private func removeCommandKeyEventMonitor() {
        guard let commandKeyEventMonitor else { return }
        NSEvent.removeMonitor(commandKeyEventMonitor)
        self.commandKeyEventMonitor = nil
    }

    private func commandNumber(from event: NSEvent) -> Int? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command else { return nil }

        switch event.keyCode {
        case 18: return 1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        default: return nil
        }
    }

    private func mutationFailureBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(settings.appFont(size: 13))
                .lineLimit(2)
                .foregroundStyle(.primary)
            Button(String(localized: "Dismiss")) {
                viewModel.dismissMutationFailure()
            }
            .buttonStyle(.plain)
            .font(settings.appFont(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(BannerBackgroundModifier())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .accessibilityIdentifier("MutationFailureBanner")
    }
}

private struct BannerBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

/// Window corner radius for known macOS versions to match Spotlight's appearance.
/// No public API exposes this, so we cap to known versions and fall back to native rounding.
var systemWindowCornerRadius: CGFloat? {
    let v = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    return (26 ... 27).contains(v) ? 26 : nil
}
