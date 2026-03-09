import SwiftUI
import AppKit
import Observation
import ClipKittyRust

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
        (.all, String(localized: "All Types")),
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
                filter: viewModel.contentTypeFilter,
                filterOptions: Self.filterOptions,
                searchSpinnerVisible: viewModel.searchSpinnerVisible,
                selectedItemAvailable: viewModel.selectedItem != nil,
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
                onOpenDeleteConfirm: { viewModel.openDeleteConfirmation() },
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

    @ViewBuilder
    private var content: some View {
        switch viewModel.session.query {
        case .failed(_, let message):
            BrowserPreviewPane.error(message)
        case .idle, .searching, .ready:
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
                    focusActionsDropdown: focusActionsDropdown
                )
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func openFilterOverlay() {
        let index = Self.filterOptions.firstIndex(where: { $0.0 == viewModel.contentTypeFilter }) ?? 0
        viewModel.openFilterOverlay(highlightedIndex: index)
        focusFilterDropdown()
    }

    private func openActionsOverlay() {
        guard viewModel.selectedItem != nil else { return }
        viewModel.openActionsOverlay(highlightedIndex: BrowserActionsOverlay.defaultActionIndex)
        focusActionsDropdown()
    }

    private func handleNumberKey(_ keyPress: KeyPress) -> KeyPress.Result {
        guard let number = Int(keyPress.characters),
              number >= 1 && number <= 9,
              keyPress.modifiers.contains(.command),
              handleCommandNumberShortcut(number) else {
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
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .accessibilityIdentifier("MutationFailureBanner")
    }
}

private extension View {
    @ViewBuilder
    func browserGlassBackground() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .rect)
        } else {
            self.background(.regularMaterial)
        }
    }
}
