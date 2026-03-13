import AppKit
import ClipKittyRust
import Observation
import SwiftUI

struct BrowserView: View {
    @Bindable var viewModel: BrowserViewModel
    let displayVersion: Int

    @State private var commandNumberEventMonitor: Any?
    @FocusState private var focusTarget: FocusTarget?

    enum FocusTarget: Hashable {
        case search
        case filterDropdown
        case actionsDropdown
    }

    private static let filterOptions: [(ContentTypeFilter, String)] = [
        (.all, String(localized: "All")),
        (.text, String(localized: "Text")),
        (.images, String(localized: "Images")),
        (.links, String(localized: "Links")),
        (.colors, String(localized: "Colors")),
        (.files, String(localized: "Files")),
    ]

    var body: some View {
        VStack(spacing: 0) {
            BrowserSearchBar(
                searchText: Binding(
                    get: { viewModel.searchText },
                    set: { viewModel.updateSearchText($0) }
                ),
                filterLabel: filterLabel,
                searchSpinnerVisible: viewModel.searchSpinnerVisible,
                selectedItemAvailable: viewModel.selectedItem != nil,
                hasPendingEdit: viewModel.selectedItemHasPendingEdit,
                isFilterPopoverPresented: Binding(
                    get: {
                        if case .filter = viewModel.session.overlays {
                            return true
                        }
                        return false
                    },
                    set: { isPresented in
                        if !isPresented {
                            viewModel.closeOverlay()
                        }
                    }
                ),
                focusTarget: $focusTarget,
                onMoveSelection: viewModel.moveSelection(by:),
                onConfirm: viewModel.confirmSelection,
                onDismiss: viewModel.dismiss,
                onOpenFilter: openFilterOverlay,
                onOpenActions: openActionsOverlay,
                onDelete: viewModel.deleteSelectedItem,
                onDiscardEdit: viewModel.discardCurrentEdit,
                onSaveEdit: {
                    viewModel.commitCurrentEdit()
                    focusSearchField()
                },
                onHandleNumberKey: handleNumberKey
            ) {
                BrowserFilterOverlay(
                    viewModel: viewModel,
                    options: Self.filterOptions,
                    focusTarget: $focusTarget,
                    focusSearchField: focusSearchField
                )
            }

            Divider()

            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SelectedIndex_\(viewModel.selectedIndex ?? -1)")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color.clear
                .browserGlassBackground()
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
            installCommandNumberEventMonitor()
            focusSearchField()
        }
        .onDisappear {
            removeCommandNumberEventMonitor()
        }
    }

    private var filterLabel: String {
        if viewModel.selectedTagFilter == .bookmark {
            return String(localized: "Bookmarks")
        }
        return Self.filterOptions.first(where: { $0.0 == viewModel.contentTypeFilter })?.1
            ?? String(localized: "All")
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.session.query {
        case let .failed(_, message, _):
            BrowserPreviewPane.error(message)
        case .idle, .pending, .ready:
            HStack(spacing: 0) {
                BrowserResultsList(
                    viewModel: viewModel,
                    displayVersion: displayVersion,
                    focusSearchField: focusSearchField
                )
                .frame(width: 324)

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

    private var currentFilterIndex: Int {
        if viewModel.selectedTagFilter == .bookmark {
            return 1 // Bookmarks is at index 1
        } else if viewModel.contentTypeFilter == .all {
            return 0 // All is at index 0
        } else {
            // Categories start at index 2 (All=0, Bookmarks=1, then categories)
            // filterOptions[0] is All, filterOptions[1+] are categories
            // Use enumerated() to get offset within the slice, not the original array index
            let categoryOffset = Self.filterOptions.dropFirst().enumerated()
                .first(where: { $0.element.0 == viewModel.contentTypeFilter })?.offset
            return (categoryOffset ?? 0) + 2
        }
    }

    /// Opens filter overlay
    /// - Parameter viaKeyboard: If true (keyboard trigger), highlights current selection for immediate arrow nav.
    ///                          If false (mouse trigger), no initial highlight - hover will control it.
    private func openFilterOverlay(viaKeyboard: Bool) {
        let highlight: FilterOverlayState = viaKeyboard ? .index(currentFilterIndex) : .none
        viewModel.openFilterOverlay(highlight: highlight)
        if viaKeyboard {
            focusFilterDropdown()
        }
    }

    /// Opens actions overlay
    /// - Parameter viaKeyboard: If true (keyboard trigger), highlights first item for immediate arrow nav.
    ///                          If false (mouse trigger), no initial highlight - hover will control it.
    private func openActionsOverlay(viaKeyboard: Bool) {
        guard viewModel.selectedItem != nil else { return }
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
        let index = number - 1
        guard viewModel.itemIds.indices.contains(index) else { return false }
        let itemId = viewModel.itemIds[index]
        viewModel.select(itemId: itemId, origin: .user)
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

    private func focusFilterDropdown() {
        setFocus(to: .filterDropdown, delay: .milliseconds(50))
    }

    private func focusActionsDropdown() {
        setFocus(to: .actionsDropdown, delay: .milliseconds(50))
    }

    @MainActor
    private func installCommandNumberEventMonitor() {
        guard commandNumberEventMonitor == nil else { return }
        commandNumberEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let number = commandNumber(from: event) else {
                return event
            }
            return handleCommandNumberShortcut(number) ? nil : event
        }
    }

    @MainActor
    private func removeCommandNumberEventMonitor() {
        guard let commandNumberEventMonitor else { return }
        NSEvent.removeMonitor(commandNumberEventMonitor)
        self.commandNumberEventMonitor = nil
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
                .font(.custom(FontManager.sansSerif, size: 13))
                .lineLimit(2)
                .foregroundStyle(.primary)
            Button(String(localized: "Dismiss")) {
                viewModel.dismissMutationFailure()
            }
            .buttonStyle(.plain)
            .font(.custom(FontManager.sansSerif, size: 13).weight(.semibold))
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

private extension View {
    @ViewBuilder
    func browserGlassBackground() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .rect)
        } else {
            background(.regularMaterial)
        }
    }
}
