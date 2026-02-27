import SwiftUI
import AppKit
import ClipKittyRust
import os.log
import UniformTypeIdentifiers

/// Notification posted when the panel is about to hide, allowing pending edits to be saved.
extension Notification.Name {
    static let clipKittyWillHide = Notification.Name("clipKittyWillHide")
}

private enum SpinnerState: Equatable {
    case idle
    case debouncing(task: Task<Void, Never>)
    case visible

    static func == (lhs: SpinnerState, rhs: SpinnerState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.visible, .visible), (.debouncing, .debouncing):
            return true
        default:
            return false
        }
    }

    mutating func cancel() {
        if case .debouncing(let task) = self {
            task.cancel()
        }
        self = .idle
    }
}

private enum ActionsPopoverState: Equatable {
    case hidden
    case showingActions(highlightedIndex: Int)
    case showingDeleteConfirm(highlightedIndex: Int)
}

struct ContentView: View {
    var store: ClipboardStore
    let onSelect: (Int64, ClipboardContent) -> Void
    let onCopyOnly: (Int64, ClipboardContent) -> Void
    let onDismiss: () -> Void
    var initialSearchQuery: String = ""

    @State private var selectedItemId: Int64?
    @State private var selectedItem: ClipboardItem?
    @State private var searchText: String = ""
    @State private var activeFilter: ContentTypeFilter? = nil
    @State private var autocompleteState: AutocompleteState = .hidden
    @State private var didApplyInitialSearch = false
    @State private var lastItemsSignature: [Int64] = []  // Track when items change to suppress animation
    @State private var searchSpinner: SpinnerState = .idle
    @State private var previewSpinner: SpinnerState = .idle
    @State private var hasUserNavigated = false
    @State private var actionsPopover: ActionsPopoverState = .hidden
    @State private var commandNumberEventMonitor: Any?

    /// Which item's text editor currently has keyboard focus.
    enum EditFocusState: Equatable {
        case idle
        case focused(itemId: Int64)
    }
    @State private var editFocus: EditFocusState = .idle
    /// Per-item cache of unsaved edited text. Cleared on window hide.
    @State private var pendingEdits: [Int64: String] = [:]

    enum FocusTarget: Hashable {
        case search
        case actionsDropdown
    }
    @FocusState private var focusTarget: FocusTarget?

    private var actionsPopoverBinding: Binding<Bool> {
        Binding(
            get: { if case .hidden = actionsPopover { return false } else { return true } },
            set: { if !$0 { actionsPopover = .hidden } }
        )
    }

    private var itemIds: [Int64] {
        switch store.state {
        case .results(_, let items, _), .resultsLoading(_, let items):
            return items.map { $0.itemMetadata.itemId }
        case .loading, .error:
            return []
        }
    }

    /// The first item from results (avoids separate fetch)
    private var stateFirstItem: ClipboardItem? {
        switch store.state {
        case .results(_, _, let firstItem):
            return firstItem
        case .resultsLoading, .loading, .error:
            return nil
        }
    }

    /// Get match data for the selected item from results
    private var selectedItemMatchData: MatchData? {
        guard let selectedItemId else { return nil }
        switch store.state {
        case .results(_, let items, _), .resultsLoading(_, let items):
            return items.first { $0.itemMetadata.itemId == selectedItemId }?.matchData
        case .loading, .error:
            return nil
        }
    }

    private var firstItemId: Int64? {
        itemIds.first
    }

    private var itemCount: Int {
        itemIds.count
    }

    private var selectedIndex: Int? {
        guard let selectedItemId else { return nil }
        return itemIds.firstIndex(of: selectedItemId)
    }

    private func itemId(at index: Int) -> Int64? {
        guard index >= 0 && index < itemIds.count else { return nil }
        return itemIds[index]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                searchBar
                Divider()
                content
            }

            // Autocomplete dropdown — rendered above all content to receive clicks
            if case .visible(let suggestions, let highlightedIndex) = autocompleteState {
                AutocompleteDropdownView(
                    suggestions: suggestions,
                    highlightedIndex: highlightedIndex,
                    searchText: searchText,
                    onSelect: { suggestion in
                        activeFilter = suggestion.filter
                        searchText = ""
                        autocompleteState = .hidden
                    }
                )
                .padding(.top, 50) // Below the search bar
                .padding(.leading, 57) // Align with text field (17 padding + 40 icon area)
            }
        }
        // Hidden element for UI testing - exposes selected index
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SelectedIndex_\(selectedIndex ?? -1)")
        // 1. Force the VStack to fill the entire available space
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        // 2 & 3. Isolate the glass effect into its own background layer
        // and apply ignoresSafeArea ONLY to the background.
        .background(
            Color.clear
                .clipKittyGlassBackground()
                .ignoresSafeArea(.all)
        )

        // 2. Ignore ONLY the top safe area for the main content.
        // This fixes the white gap at the top without breaking the scrollbars!
        .ignoresSafeArea(edges: .top)

        .onAppear {
            installCommandNumberEventMonitor()

            // Apply initial search query if provided (for CI screenshots)
            if !initialSearchQuery.isEmpty && !didApplyInitialSearch {
                searchText = initialSearchQuery
                didApplyInitialSearch = true
            } else {
                searchText = ""
            }
            // Select first item if nothing selected
            if selectedItemId == nil, let firstId = firstItemId {
                loadItem(id: firstId)
            }
            // Initialize items signature for animation tracking
            lastItemsSignature = itemIds
            focusSearchField()
        }
        .onDisappear {
            removeCommandNumberEventMonitor()
            discardAllEdits()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipKittyWillHide)) { _ in
            discardAllEdits()
        }
        .onChange(of: store.displayVersion) { _, _ in
            // Reset local state when store signals a display reset
            hasUserNavigated = false
            pendingEdits.removeAll()
            editFocus = .idle
            // But preserve initial search if it was just applied
            if didApplyInitialSearch && !initialSearchQuery.isEmpty {
                didApplyInitialSearch = false // Allow reset next time
            } else {
                searchText = ""
            }
            autocompleteState = .hidden
            actionsPopover = .hidden
            // Select first item whenever display resets (re-open)
            if let firstId = firstItemId {
                loadItem(id: firstId)
            } else {
                selectedItemId = nil
                selectedItem = nil
            }
            focusSearchField()
        }
        .onChange(of: store.state) { _, newState in
            // Validate selection - ensure selected item still exists in results
            if let selectedItemId, !itemIds.contains(selectedItemId) {
                self.selectedItemId = firstItemId
                self.selectedItem = nil
            }

            // If first item is available from state and matches selection, use it
            if let firstItem = stateFirstItem,
               let selectedId = selectedItemId,
               firstItem.itemMetadata.itemId == selectedId,
               self.selectedItem == nil {
                self.selectedItem = firstItem
            }

            // Show spinner after 100ms if still loading
            searchSpinner.cancel()
            if case .resultsLoading = newState {
                let task = debouncedSpinnerTask {
                    if case .resultsLoading = self.store.state { self.searchSpinner = .visible }
                }
                searchSpinner = .debouncing(task: task)
            } else {
                searchSpinner = .idle
            }
        }
        .onChange(of: searchText) { _, newValue in
            hasUserNavigated = false
            store.setSearchQuery(newValue)
        }
        .onChange(of: activeFilter) { _, newFilter in
            hasUserNavigated = false
            store.setContentTypeFilter(newFilter ?? .all)
        }
        .onChange(of: store.contentTypeFilter) { _, _ in
            // Reset selection when filter changes
            hasUserNavigated = false
            selectedItemId = firstItemId
            selectedItem = nil
        }
        .onChange(of: selectedItemId) { oldId, newId in
            if case .focused(let focusedId) = editFocus, focusedId != newId {
                editFocus = .idle
            }
            // Fetch full item when selection changes
            guard let newId else {
                selectedItem = nil
                return
            }
            Task {
                selectedItem = await store.fetchItem(id: newId)
            }
        }
        .onChange(of: selectedItem) { _, newItem in
            previewSpinner.cancel()
            if newItem == nil && selectedItemId != nil {
                let task = debouncedSpinnerTask {
                    if self.selectedItem == nil && self.selectedItemId != nil { self.previewSpinner = .visible }
                }
                previewSpinner = .debouncing(task: task)
            } else {
                previewSpinner = .idle
            }
        }
        .onChange(of: itemIds) { oldOrder, newOrder in
            // Select first item by default if nothing is selected
            guard let selectedItemId else {
                self.selectedItemId = firstItemId
                hasUserNavigated = false
                return
            }
            // Reset selection to first if the selected item's position changed
            // This ensures search results always start from the first match
            let oldIndex = oldOrder.firstIndex(of: selectedItemId)
            let newIndex = newOrder.firstIndex(of: selectedItemId)
            if oldIndex != newIndex {
                self.selectedItemId = firstItemId
                self.selectedItem = nil
                hasUserNavigated = false
            }
        }
    }

    // MARK: - Selection Management

    /// Select an item and load it, preferring cached stateFirstItem to avoid extra fetch.
    private func loadItem(id: Int64) {
        selectedItemId = id
        if let firstItem = stateFirstItem, firstItem.itemMetadata.itemId == id {
            selectedItem = firstItem
        } else {
            selectedItem = nil
            Task { selectedItem = await store.fetchItem(id: id) }
        }
    }

    /// Schedule a spinner to show after 100ms debounce if a condition persists.
    private func debouncedSpinnerTask(
        action: @escaping @MainActor @Sendable () -> Void
    ) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private func focusSearchField() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(10))
            focusTarget = .search
        }
    }

    private func focusActionsDropdown() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            focusTarget = .actionsDropdown
        }
    }

    private func moveSelection(by offset: Int) {
        hasUserNavigated = true
        guard let currentIndex = selectedIndex else {
            selectedItemId = firstItemId
            return
        }
        let newIndex = max(0, min(itemCount - 1, currentIndex + offset))
        selectedItemId = itemId(at: newIndex)
    }

    private func confirmSelection() {
        guard let item = selectedItem else { return }
        let content = effectiveContent(for: item)
        commitCurrentEdit()
        onSelect(item.itemMetadata.itemId, content)
    }

    private func copyOnlySelection() {
        guard let item = selectedItem else { return }
        let content = effectiveContent(for: item)
        commitCurrentEdit()
        onCopyOnly(item.itemMetadata.itemId, content)
    }

    /// Returns the effective content for an item, accounting for pending edits.
    private func effectiveContent(for item: ClipboardItem) -> ClipboardContent {
        if let editedText = pendingEdits[item.itemMetadata.itemId] {
            return .text(value: editedText)
        }
        return item.content
    }

    private func deleteSelectedItem() {
        guard let id = selectedItemId, let currentIndex = selectedIndex else { return }

        // Compute next selection before deleting
        let nextId: Int64?
        if currentIndex + 1 < itemCount {
            nextId = itemId(at: currentIndex + 1)
        } else if currentIndex > 0 {
            nextId = itemId(at: currentIndex - 1)
        } else {
            nextId = nil
        }

        pendingEdits.removeValue(forKey: id)
        store.delete(itemId: id)
        selectedItemId = nextId
        selectedItem = nil
    }

    /// Called on each text change in the preview pane.
    /// Tracks the edit as pending - will be saved as new item when app closes.
    private func onTextEdit(_ newText: String, for itemId: Int64, originalText: String) {
        if newText == originalText {
            pendingEdits.removeValue(forKey: itemId)
        } else {
            pendingEdits[itemId] = newText
        }
    }

    /// Called when editing focus state changes.
    private func onEditingStateChange(_ isEditing: Bool, for itemId: Int64) {
        if isEditing {
            editFocus = .focused(itemId: itemId)
        } else if case .focused(let id) = editFocus, id == itemId {
            editFocus = .idle
        }
    }

    /// Discards the currently selected item's pending edit.
    private func discardCurrentEdit() {
        if let id = selectedItemId {
            pendingEdits.removeValue(forKey: id)
        }
        editFocus = .idle
    }

    /// Discards ALL pending edits. Called on window hide.
    private func discardAllEdits() {
        pendingEdits.removeAll()
        editFocus = .idle
    }

    /// Commits the currently selected item's edit as a new clipboard item.
    private func commitCurrentEdit() {
        guard let id = selectedItemId,
              let editedText = pendingEdits.removeValue(forKey: id),
              !editedText.isEmpty else {
            editFocus = .idle
            return
        }
        editFocus = .idle
        Task {
            let newItemId = await store.saveEditedText(text: editedText)
            if newItemId > 0 {
                searchText = ""
                store.setSearchQuery("")
                selectedItemId = newItemId
                ToastWindow.shared.show(message: String(localized: "Saved as new item"))
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.custom(FontManager.sansSerif, size: 17).weight(.medium))

            SmartSearchField(
                textQuery: $searchText,
                activeFilter: $activeFilter,
                autocompleteState: $autocompleteState,
                onMoveSelection: { moveSelection(by: $0) },
                onConfirmSelection: { confirmSelection() },
                onDismiss: { onDismiss() },
                onShowActions: {
                    guard selectedItem != nil else { return }
                    if case .hidden = actionsPopover {
                        let actions = actionItems
                        actionsPopover = .showingActions(highlightedIndex: actions.count - 1)
                        focusActionsDropdown()
                    } else {
                        actionsPopover = .hidden
                    }
                },
                onShowDelete: {
                    guard selectedItemId != nil else { return }
                    actionsPopover = .showingDeleteConfirm(highlightedIndex: 0)
                    focusActionsDropdown()
                }
            )
            .focused($focusTarget, equals: .search)
            .onKeyPress(characters: .decimalDigits, phases: .down) { keyPress in
                handleNumberKey(keyPress)
            }

            if case .visible = searchSpinner {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
    }

    private func handleNumberKey(_ keyPress: KeyPress) -> KeyPress.Result {
        guard let number = Int(keyPress.characters),
              number >= 1 && number <= 9,
              keyPress.modifiers.contains(.command) else {
            return .ignored
        }

        return handleCommandNumberShortcut(number) ? .handled : .ignored
    }

    @MainActor
    private func installCommandNumberEventMonitor() {
        guard commandNumberEventMonitor == nil else { return }
        commandNumberEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Backspace on empty search field removes the active filter.
            // Handled here because SwiftUI's .onKeyPress(.delete) does not fire
            // on an empty TextField.
            if event.keyCode == 51, // 51 = backspace key
               searchText.isEmpty,
               activeFilter != nil,
               focusTarget == .search {
                activeFilter = nil
                return nil
            }

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

    @discardableResult
    private func handleCommandNumberShortcut(_ number: Int) -> Bool {
        let index = number - 1
        guard index < itemCount else { return false }

        selectedItemId = itemId(at: index)
        confirmSelection()
        return true
    }

    private func indexForItem(_ itemId: Int64?) -> Int? {
        guard let itemId else { return nil }
        return itemIds.firstIndex(of: itemId)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            loadingView
        case .error(let message):
            errorView(message)
        case .results, .resultsLoading:
            splitView
        }
    }

    private var loadingView: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .frame(maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.custom(FontManager.sansSerif, size: 15))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var splitView: some View {
        HStack(spacing: 0) {
            itemList
                .frame(width: 324)

            Divider()

            previewPane
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Item List

    /// Row data for display - preserves matchData during loading to prevent text flash
    private var displayRows: [(metadata: ItemMetadata, matchData: MatchData?)] {
        switch store.state {
        case .results(_, let items, _), .resultsLoading(_, let items):
            return items.map { ($0.itemMetadata, $0.matchData) }
        case .loading, .error:
            return []
        }
    }

    private var itemList: some View {
        ScrollViewReader { proxy in
            List {
                // Single ForEach maintains view identity across state transitions
                ForEach(Array(displayRows.enumerated()), id: \.element.metadata.itemId) { index, row in
                    ItemRow(
                        metadata: row.metadata,
                        matchData: row.matchData,
                        isSelected: row.metadata.itemId == selectedItemId,
                        hasUserNavigated: hasUserNavigated,
                        isEditingPreview: {
                            let id = row.metadata.itemId
                            let isFocused = editFocus == .focused(itemId: id)
                            return (isFocused || pendingEdits[id] != nil) && id == selectedItemId
                        }(),
                        hasPendingEdit: pendingEdits[row.metadata.itemId] != nil,
                        onTap: {
                            hasUserNavigated = true
                            selectedItemId = row.metadata.itemId
                            focusSearchField()
                        }
                    )
                    .equatable()
                    .accessibilityIdentifier("ItemRow_\(index)")
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .animation(nil, value: itemIds)
            .modifier(HideScrollIndicatorsWhenOverlay(displayVersion: store.displayVersion))
            .onChange(of: searchText) { _, _ in
                // Scroll to top when search query changes (no animation)
                if let firstItemId = itemIds.first {
                    proxy.scrollTo(firstItemId, anchor: .top)
                }
            }
            .onChange(of: selectedItemId) { oldItemId, newItemId in
                guard let newItemId else { return }

                let currentSignature = itemIds
                let itemsChanged = currentSignature != lastItemsSignature

                // Update signature for next comparison
                if itemsChanged {
                    lastItemsSignature = currentSignature
                }

                // Only animate if items didn't change (user is navigating within same list)
                let oldIndex = indexForItem(oldItemId)
                let newIndex = indexForItem(newItemId)
                let isBigJump = {
                    guard let oldIndex, let newIndex else { return false }
                    return abs(newIndex - oldIndex) > 1
                }()

                if !itemsChanged && isBigJump {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(newItemId, anchor: .center)
                    }
                } else {
                    proxy.scrollTo(newItemId, anchor: .center)
                }
            }
        }
    }

    // MARK: - Preview Pane

    private var previewPane: some View {
        VStack(spacing: 0) {
            if let item = selectedItem {
                previewContent(for: item)
                Divider()
                metadataFooter(for: item)
            } else if itemIds.isEmpty {
                emptyStateView
            } else if case .visible = previewSpinner {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedItemId != nil {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No item selected")
                    .font(.custom(FontManager.sansSerif, size: 16))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.black.opacity(0.05))
    }

    @ViewBuilder
    private func previewContent(for item: ClipboardItem) -> some View {
        switch item.content {
        case .text, .color:
            // Single unified view: editable with search highlighting via temporary attributes
            EditableTextPreview(
                text: pendingEdits[item.itemMetadata.itemId] ?? item.content.textContent,
                itemId: item.itemMetadata.itemId,
                fontName: FontManager.mono,
                fontSize: 15,
                highlights: selectedItemMatchData?.fullContentHighlights ?? [],
                densestHighlightStart: selectedItemMatchData?.densestHighlightStart ?? 0,
                originalText: item.content.textContent,
                onTextChange: { newText in
                    onTextEdit(newText, for: item.itemMetadata.itemId, originalText: item.content.textContent)
                },
                onEditingStateChange: { editing in
                    onEditingStateChange(editing, for: item.itemMetadata.itemId)
                },
                onCmdReturn: {
                    confirmSelection()
                },
                onSave: {
                    commitCurrentEdit()
                    focusSearchField()
                },
                onEscape: {
                    if hasPendingEditForSelectedItem {
                        discardCurrentEdit()
                        focusSearchField()
                    } else {
                        onDismiss()
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image(let data, let description, _):
            ScrollView(.vertical, showsIndicators: true) {
                imagePreview(data: data, description: description)
            }
        case .link(let url, let metadataState):
            ScrollView(.vertical, showsIndicators: true) {
                linkPreview(url: url, metadataState: metadataState, itemId: item.itemMetadata.itemId)
            }
        case .file(_, let files):
            FilePreviewView(files: files, searchQuery: searchText)
        }
    }

    @ViewBuilder
    private func imagePreview(data: Data, description: String) -> some View {
        if let nsImage = NSImage(data: data) {
            VStack(spacing: 8) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                if !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
    }

    /// Whether the current item has a pending edit that can be saved/discarded.
    private var hasPendingEditForSelectedItem: Bool {
        guard let selectedItemId else { return false }
        return pendingEdits[selectedItemId] != nil
    }

    private var isPreviewFocused: Bool {
        if case .focused(let id) = editFocus, id == selectedItemId {
            return true
        }
        return false
    }

    private func metadataFooter(for item: ClipboardItem) -> some View {
        HStack(spacing: 12) {
            if hasPendingEditForSelectedItem {
                Button(String(localized: "Esc Discard")) {
                    discardCurrentEdit()
                    focusSearchField()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .fixedSize()
                Button(String(localized: "⌘S Save")) {
                    commitCurrentEdit()
                    focusSearchField()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.4), lineWidth: 1)
                )
                .fixedSize()
                Spacer(minLength: 0)
                Button("\(isPreviewFocused ? "⌘" : "")↩ \(AppSettings.shared.pasteMode.editConfirmLabel)") {
                    confirmSelection()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .fixedSize()
            } else {
                Label(item.timeAgo, systemImage: "clock")
                    .lineLimit(1)
                if let app = item.itemMetadata.sourceApp {
                    HStack(spacing: 4) {
                        if let bundleID = item.itemMetadata.sourceAppBundleId,
                           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                                .resizable()
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "app")
                        }
                        Text(app)
                            .lineLimit(1)
                    }
                }
                actionsButton
                    .fixedSize()
                Spacer(minLength: 0)
                Button(buttonLabel(for: item)) { confirmSelection() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .fixedSize()
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 17)
        .padding(.vertical, 11)
        .background(.black.opacity(0.05))
    }

    private func buttonLabel(for item: ClipboardItem) -> String {
        let isEditing = editFocus == .focused(itemId: item.itemMetadata.itemId)
        if isEditing || pendingEdits[item.itemMetadata.itemId] != nil {
            return "⌘⏎ \(AppSettings.shared.pasteMode.buttonLabel)"
        }
        return "⏎ \(AppSettings.shared.pasteMode.buttonLabel)"
    }

    // MARK: - Actions Dropdown
    private enum ActionItem: Equatable {
        case defaultAction  // copy or paste based on settings
        case copyOnly       // only shown when default is paste
        case delete
    }

    private var actionItems: [ActionItem] {
        var items: [ActionItem] = [.delete]
        if case .autoPaste = AppSettings.shared.pasteMode {
            items.append(.copyOnly)
        }
        items.append(.defaultAction)
        return items
    }

    private func actionLabel(for action: ActionItem) -> String {
        switch action {
        case .defaultAction:
            return AppSettings.shared.pasteMode.buttonLabel
        case .copyOnly:
            return String(localized: "Copy")
        case .delete:
            return String(localized: "Delete")
        }
    }

    private func actionIdentifier(for action: ActionItem) -> String {
        switch action {
        case .defaultAction: return AppSettings.shared.pasteMode.buttonLabel
        case .copyOnly: return "Copy"
        case .delete: return "Delete"
        }
    }

    private var actionsButton: some View {
        Button {
            let actions = actionItems
            if case .hidden = actionsPopover {
                actionsPopover = .showingActions(highlightedIndex: actions.count - 1)
                focusActionsDropdown()
            } else {
                actionsPopover = .hidden
            }
        } label: {
            Text("⌘K Actions")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ActionsButton")
        .popover(isPresented: actionsPopoverBinding, arrowEdge: .top) {
            actionsPopoverContent
        }
    }

    private var actionsPopoverContent: some View {
        let actions = actionItems
        let confirmCount = 2
        let isShowingDeleteConfirm: Bool
        let highlightedIndex: Int

        switch actionsPopover {
        case .showingDeleteConfirm(let idx):
            isShowingDeleteConfirm = true
            highlightedIndex = idx
        case .showingActions(let idx):
            isShowingDeleteConfirm = false
            highlightedIndex = idx
        case .hidden:
            isShowingDeleteConfirm = false
            highlightedIndex = 0
        }

        let itemCount = isShowingDeleteConfirm ? confirmCount : actions.count

        return VStack(spacing: 2) {
            if isShowingDeleteConfirm {
                Text("Delete?")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                ActionOptionRow(
                    label: String(localized: "Delete"),
                    actionID: "Delete",
                    isHighlighted: highlightedIndex == 0,
                    isDestructive: true,
                    action: {
                        deleteSelectedItem()
                        actionsPopover = .hidden
                    }
                )
                ActionOptionRow(
                    label: String(localized: "Cancel"),
                    actionID: "Cancel",
                    isHighlighted: highlightedIndex == 1,
                    isDestructive: false,
                    action: {
                        actionsPopover = .showingActions(highlightedIndex: actions.count - 1)
                    }
                )
            } else {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    if action == .delete && index < actions.count - 1 {
                        ActionOptionRow(
                            label: actionLabel(for: action),
                            actionID: actionIdentifier(for: action),
                            isHighlighted: highlightedIndex == index,
                            isDestructive: true,
                            action: { performAction(action) }
                        )
                        Divider().padding(.horizontal, 4).padding(.vertical, 3)
                    } else {
                        ActionOptionRow(
                            label: actionLabel(for: action),
                            actionID: actionIdentifier(for: action),
                            isHighlighted: highlightedIndex == index,
                            isDestructive: action == .delete,
                            action: { performAction(action) }
                        )
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 160)
        .focusable()
        .focused($focusTarget, equals: .actionsDropdown)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            switch actionsPopover {
            case .showingActions(let idx):
                actionsPopover = .showingActions(highlightedIndex: max(idx - 1, 0))
            case .showingDeleteConfirm(let idx):
                actionsPopover = .showingDeleteConfirm(highlightedIndex: max(idx - 1, 0))
            case .hidden:
                break
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            switch actionsPopover {
            case .showingActions(let idx):
                actionsPopover = .showingActions(highlightedIndex: min(idx + 1, actions.count - 1))
            case .showingDeleteConfirm(let idx):
                actionsPopover = .showingDeleteConfirm(highlightedIndex: min(idx + 1, confirmCount - 1))
            case .hidden:
                break
            }
            return .handled
        }
        .onKeyPress(.return, phases: .down) { _ in
            switch actionsPopover {
            case .showingDeleteConfirm(let idx):
                if idx == 0 {
                    deleteSelectedItem()
                    actionsPopover = .hidden
                } else {
                    actionsPopover = .showingActions(highlightedIndex: actions.count - 1)
                }
            case .showingActions(let idx):
                let action = actions[idx]
                performAction(action)
            case .hidden:
                break
            }
            return .handled
        }
        .onKeyPress(.escape) {
            switch actionsPopover {
            case .showingDeleteConfirm:
                actionsPopover = .showingActions(highlightedIndex: actions.count - 1)
            case .showingActions, .hidden:
                actionsPopover = .hidden
                focusSearchField()
            }
            return .handled
        }
        .onKeyPress(.tab) {
            actionsPopover = .hidden
            focusSearchField()
            return .handled
        }
        .onAppear {
            switch actionsPopover {
            case .hidden, .showingActions:
                actionsPopover = .showingActions(highlightedIndex: actions.count - 1)
            case .showingDeleteConfirm:
                break
            }
            focusActionsDropdown()
        }
    }

    private func performAction(_ action: ActionItem) {
        switch action {
        case .defaultAction:
            actionsPopover = .hidden
            confirmSelection()
        case .copyOnly:
            actionsPopover = .hidden
            copyOnlySelection()
        case .delete:
            actionsPopover = .showingDeleteConfirm(highlightedIndex: 0)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "clipboard")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(emptyStateMessage)
                .font(.custom(FontManager.sansSerif, size: 15))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateMessage: String {
        if store.currentQuery.isEmpty && store.contentTypeFilter == .all {
            return String(localized: "No clipboard history")
        } else {
            return String(localized: "No results")
        }
    }

    @ViewBuilder
    private func linkPreview(url: String, metadataState: LinkMetadataState, itemId: Int64) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Native link preview using LPLinkView
            LinkPreviewView(url: url, metadataState: metadataState)
                .frame(maxWidth: .infinity)

            // Full URL with line wrapping
            Text(url)
                .font(.custom(FontManager.mono, size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(16)
        .task(id: itemId) {
            // Fetch metadata on-demand if pending
            guard case .pending = metadataState else { return }
            if let updatedItem = await store.fetchLinkMetadata(url: url, itemId: itemId) {
                selectedItem = updatedItem
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func clipKittyGlassBackground() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .rect)
        } else {
            self.background(.regularMaterial)
        }
    }
}

// MARK: - File Preview

struct FilePreviewView: View {
    let files: [FileEntry]
    var searchQuery: String = ""

    /// Query words for highlighting (lowercased, non-empty)
    private var queryWords: [String] {
        searchQuery.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                    fileRow(file)
                    if file.fileItemId != files.last?.fileItemId {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileRow(_ file: FileEntry) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                .resizable()
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                highlightedFileText(file.filename, font: .system(size: 14, weight: .medium), color: .primary)
                    .lineLimit(1)

                highlightedFileText(file.path, font: .system(size: 11), color: .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if file.fileSize > 0 {
                    Text(Self.formatFileSize(file.fileSize))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Highlight query word matches in file text
    private func highlightedFileText(_ text: String, font: Font, color: Color) -> Text {
        let words = queryWords
        guard !words.isEmpty else {
            return Text(text).font(font).foregroundColor(color)
        }

        // Find all match ranges (case-insensitive)
        let textLower = text.lowercased()
        var matchRanges: [(Int, Int)] = []
        for word in words {
            var searchStart = textLower.startIndex
            while let range = textLower.range(of: word, range: searchStart..<textLower.endIndex) {
                let start = textLower.distance(from: textLower.startIndex, to: range.lowerBound)
                let end = textLower.distance(from: textLower.startIndex, to: range.upperBound)
                matchRanges.append((start, end))
                searchStart = range.upperBound
            }
        }

        guard !matchRanges.isEmpty else {
            return Text(text).font(font).foregroundColor(color)
        }

        // Merge overlapping ranges
        matchRanges.sort { $0.0 < $1.0 }
        var merged: [(Int, Int)] = [matchRanges[0]]
        for r in matchRanges.dropFirst() {
            if r.0 <= merged.last!.1 {
                merged[merged.count - 1].1 = max(merged.last!.1, r.1)
            } else {
                merged.append(r)
            }
        }

        // Build Text with highlights
        var result = Text("")
        var pos = 0
        for (start, end) in merged {
            if pos < start {
                let plain = String(text[text.index(text.startIndex, offsetBy: pos)..<text.index(text.startIndex, offsetBy: start)])
                result = result + Text(plain).font(font).foregroundColor(color)
            }
            let highlighted = String(text[text.index(text.startIndex, offsetBy: start)..<text.index(text.startIndex, offsetBy: end)])
            result = result + Text(highlighted).font(font).foregroundColor(color)
                .bold()
                .underline()
            pos = end
        }
        if pos < text.count {
            let remaining = String(text[text.index(text.startIndex, offsetBy: pos)...])
            result = result + Text(remaining).font(font).foregroundColor(color)
        }
        return result
    }

    private static func formatFileSize(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024

        if gb >= 1 { return String(localized: "\(gb, specifier: "%.1f") GB") }
        if mb >= 1 { return String(localized: "\(mb, specifier: "%.1f") MB") }
        if kb >= 1 { return String(localized: "\(kb, specifier: "%.0f") KB") }
        return String(localized: "\(bytes) bytes")
    }
}

// MARK: - Text Preview (AppKit)

struct TextPreviewView: NSViewRepresentable {
    let text: String
    let fontName: String
    let fontSize: CGFloat
    var highlights: [HighlightRange] = []
    var densestHighlightStart: UInt64 = 0

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: 0)

        scrollView.documentView = textView
        return scrollView
    }

    /// Last known container width, persisted across view recreations so the
    /// first render already uses a good value instead of falling back to base font.
    private static var lastKnownContainerWidth: CGFloat = 0

    private func scaledFontSize(containerWidth: CGFloat) -> CGFloat {
        let lines = text.components(separatedBy: "\n")
        if lines.count >= 10 { return fontSize }

        let baseFont = NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let inset: CGFloat = 32 + 10 // textContainerInset.width * 2 + lineFragmentPadding * 2
        let availableWidth = containerWidth - inset
        if availableWidth <= 0 { return fontSize }

        let attributes: [NSAttributedString.Key: Any] = [.font: baseFont]
        var maxLineWidth: CGFloat = 0
        for line in lines {
            let lineWidth = (line as NSString).size(withAttributes: attributes).width
            if lineWidth >= availableWidth { return fontSize }
            maxLineWidth = max(maxLineWidth, lineWidth)
        }
        if maxLineWidth <= 0 { return fontSize }

        let scale = min(1.5, availableWidth / maxLineWidth) * 0.95
        return fontSize * scale
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        // Use live container width if available, otherwise fall back to persisted value
        let containerWidth = nsView.contentSize.width > 0
            ? nsView.contentSize.width
            : Self.lastKnownContainerWidth
        if nsView.contentSize.width > 0 {
            Self.lastKnownContainerWidth = nsView.contentSize.width
        }

        let scaledSize = scaledFontSize(containerWidth: containerWidth)
        let font = NSFont(name: fontName, size: scaledSize)
            ?? NSFont.monospacedSystemFont(ofSize: scaledSize, weight: .regular)

        // Settle container dimensions FIRST so that any deferred scroll
        // computes geometry against the correct width.  Previously this ran
        // *after* the text update and the async scroll was already scheduled,
        // causing intermittent stale-layout scrolls to the document bottom.
        textView.textContainer?.containerSize = NSSize(
            width: nsView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        textView.frame = NSRect(x: 0, y: 0, width: nsView.contentSize.width, height: textView.frame.height)

        // Only update if text or highlights changed
        let currentText = textView.string
        let shouldUpdate = currentText != text || context.coordinator.lastHighlights != highlights
        if shouldUpdate {
            context.coordinator.lastHighlights = highlights

            // Create paragraph style to ensure consistent word wrapping
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping

            if highlights.isEmpty {
                // Clear any previous highlighting by setting plain string with consistent style
                let attributed = NSMutableAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraphStyle
                ])
                textView.textStorage?.setAttributedString(attributed)
                // Scroll to top when no highlights
                textView.scrollToBeginningOfDocument(nil)
            } else {
                // Apply Rust-computed highlights
                let attributed = NSMutableAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraphStyle
                ])
                for range in highlights {
                    let nsRange = range.nsRange(in: text)
                    if nsRange.location != NSNotFound && nsRange.location + nsRange.length <= attributed.length {
                        let (bg, underline) = highlightStyle(for: range.kind)
                        attributed.addAttribute(.backgroundColor, value: bg, range: nsRange)
                        if underline {
                            attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: nsRange)
                        }
                    }
                }
                textView.textStorage?.setAttributedString(attributed)

                // Auto-scroll to the densest highlight region (offset computed by Rust)
                // Defer to next run loop to ensure layout is complete
                let targetHighlight = highlights.first { $0.start == densestHighlightStart } ?? highlights[0]
                let targetRange = targetHighlight.nsRange(in: text)
                DispatchQueue.main.async { [weak textView] in
                    guard let textView else { return }
                    guard let scrollView = textView.enclosingScrollView else { return }
                    textView.layoutManager?.ensureLayout(for: textView.textContainer!)

                    let glyphRange = textView.layoutManager?.glyphRange(forCharacterRange: targetRange, actualCharacterRange: nil) ?? targetRange
                    guard let rect = textView.layoutManager?.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer!) else { return }

                    // Convert rect to scroll view coordinates and check if already visible
                    let highlightRect = rect.offsetBy(dx: textView.textContainerInset.width, dy: textView.textContainerInset.height)
                    let visibleRect = scrollView.documentVisibleRect
                    if visibleRect.contains(highlightRect) {
                        return  // Already visible, no scroll needed
                    }

                    // Check if highlight is near the end of the document
                    let documentHeight = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
                    let highlightY = rect.origin.y + rect.height
                    let isNearEnd = documentHeight - highlightY < 100

                    // Perform scroll with animations explicitly disabled
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    if isNearEnd {
                        textView.scrollToEndOfDocument(nil)
                    } else {
                        let scrollRect = highlightRect.insetBy(dx: 0, dy: -50)
                        textView.scrollToVisible(scrollRect)
                    }
                    CATransaction.commit()
                }
            }
        }
    }


    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject {
        var lastHighlights: [HighlightRange] = []
    }
}

// MARK: - Editable Text Preview View

/// Custom NSTextView that handles Cmd+Return for paste action and tracks focus
private class EditablePreviewTextView: NSTextView {
    var onCmdReturn: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onSave: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 36: // Cmd+Return
                onCmdReturn?()
                return
            case 1: // Cmd+S
                onSave?()
                return
            default:
                break
            }
        }
        if event.keyCode == 53 { // Escape
            self.window?.makeFirstResponder(nil)
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocusChange?(true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            onFocusChange?(false)
        }
        return result
    }
}

/// Unified editable text view with search highlighting.
/// Highlights are applied directly to the attributed string for reliable rendering.
struct EditableTextPreview: NSViewRepresentable {
    let text: String
    let itemId: Int64
    let fontName: String
    let fontSize: CGFloat
    var highlights: [HighlightRange] = []
    var densestHighlightStart: UInt64 = 0
    var originalText: String = ""  // Original text for comparison
    var onTextChange: ((String) -> Void)?  // Called on each edit
    var onEditingStateChange: ((Bool) -> Void)?  // Called when editing state changes
    var onCmdReturn: (() -> Void)?  // Called when Cmd+Return pressed (paste)
    var onSave: (() -> Void)?  // Called when Cmd+S pressed (save edit)
    var onEscape: (() -> Void)?  // Called when Escape pressed

    /// Last known container width, persisted across view recreations
    private static var lastKnownContainerWidth: CGFloat = 0

    /// Horizontal inset for text container (left + right padding)
    private static let textContainerHorizontalInset: CGFloat = 32  // 16 * 2

    private func scaledFontSize(containerWidth: CGFloat) -> CGFloat {
        let lines = text.components(separatedBy: "\n")
        if lines.count >= 10 { return fontSize }

        let baseFont = NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let inset: CGFloat = 32 + 10 // textContainerInset.width * 2 + lineFragmentPadding * 2
        let availableWidth = containerWidth - inset
        if availableWidth <= 0 { return fontSize }

        let attributes: [NSAttributedString.Key: Any] = [.font: baseFont]
        var maxLineWidth: CGFloat = 0
        for line in lines {
            let lineWidth = (line as NSString).size(withAttributes: attributes).width
            if lineWidth >= availableWidth { return fontSize }
            maxLineWidth = max(maxLineWidth, lineWidth)
        }
        if maxLineWidth <= 0 { return fontSize }

        let scale = min(1.5, availableWidth / maxLineWidth) * 0.95
        return fontSize * scale
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let textView = EditablePreviewTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true  // Must be true for text to render properly
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: 0)

        // Set up delegate and callbacks (text will be set in updateNSView)
        textView.delegate = context.coordinator
        textView.onCmdReturn = onCmdReturn
        textView.onFocusChange = onEditingStateChange
        textView.onSave = onSave
        textView.onEscape = onEscape
        context.coordinator.onTextChange = onTextChange

        // Enable accessibility
        textView.setAccessibilityElement(true)
        textView.setAccessibilityRole(.textArea)
        textView.setAccessibilityIdentifier("PreviewTextView")

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        // Update callbacks
        context.coordinator.onTextChange = onTextChange
        if let editableTextView = textView as? EditablePreviewTextView {
            editableTextView.onCmdReturn = onCmdReturn
            editableTextView.onFocusChange = onEditingStateChange
            editableTextView.onSave = onSave
            editableTextView.onEscape = onEscape
        }

        // Check if item changed
        let itemChanged = context.coordinator.currentItemId != itemId

        // Calculate scaled font size
        let containerWidth = nsView.contentSize.width > 0
            ? nsView.contentSize.width
            : Self.lastKnownContainerWidth
        if nsView.contentSize.width > 0 {
            Self.lastKnownContainerWidth = nsView.contentSize.width
        }
        let scaledSize = scaledFontSize(containerWidth: containerWidth)
        let font = NSFont(name: fontName, size: scaledSize)
            ?? NSFont.monospacedSystemFont(ofSize: scaledSize, weight: .regular)

        // Track whether font size changed (for scaling updates)
        let fontSizeChanged = abs(context.coordinator.lastAppliedFontSize - scaledSize) > 0.1

        // Always update typing attributes so new characters use the scaled font
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let typingAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
        textView.typingAttributes = typingAttrs

        // Update text/font when item changes, font size changes, or text differs (and not editing)
        if itemChanged || fontSizeChanged {
            context.coordinator.currentItemId = itemId
            context.coordinator.lastAppliedFontSize = scaledSize
            if itemChanged {
                context.coordinator.isEditing = false
            }

            // Use attributed string to apply font properly
            // Use textView.string to preserve edits, or text if item changed
            let currentText = itemChanged ? text : textView.string
            let attributed = NSAttributedString(string: currentText, attributes: typingAttrs)
            textView.textStorage?.setAttributedString(attributed)
            if itemChanged {
                textView.scrollToBeginningOfDocument(nil)
            }
        } else if !context.coordinator.isEditing && textView.string != text {
            // Use attributed string to apply font properly
            let attributed = NSAttributedString(string: text, attributes: typingAttrs)
            textView.textStorage?.setAttributedString(attributed)
            context.coordinator.lastAppliedFontSize = scaledSize
        }

        // Apply highlights directly to attributed string (more reliable than temporary attributes)
        applyHighlights(
            to: textView,
            font: font,
            paragraphStyle: paragraphStyle,
            itemChanged: itemChanged,
            isEditing: context.coordinator.isEditing
        )

        // Update container size and frame
        let textContainerWidth = max(0, nsView.contentSize.width - Self.textContainerHorizontalInset)
        textView.textContainer?.containerSize = NSSize(
            width: textContainerWidth,
            height: .greatestFiniteMagnitude
        )
        textView.frame = NSRect(x: 0, y: 0, width: nsView.contentSize.width, height: textView.frame.height)
    }

    private func applyHighlights(
        to textView: NSTextView,
        font: NSFont,
        paragraphStyle: NSParagraphStyle,
        itemChanged: Bool,
        isEditing: Bool
    ) {
        // Skip highlight updates during active editing to avoid disrupting cursor position
        // Highlights will be reapplied when editing ends and item is selected again
        if isEditing { return }

        guard let textStorage = textView.textStorage else { return }

        let currentText = textView.string
        let textLength = (currentText as NSString).length

        // Build attributed string with highlights baked in (like TextPreviewView)
        // This is more reliable than temporary attributes for editable text
        let attributed = NSMutableAttributedString(string: currentText, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ])

        // Apply highlights directly to the attributed string
        for highlight in highlights {
            let nsRange = highlight.nsRange(in: currentText)
            guard nsRange.location != NSNotFound,
                  nsRange.length > 0,
                  nsRange.location + nsRange.length <= textLength else { continue }

            let (bgColor, shouldUnderline) = highlightStyle(for: highlight.kind)
            attributed.addAttribute(.backgroundColor, value: bgColor, range: nsRange)
            if shouldUnderline {
                attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: nsRange)
            }
        }

        // Only update if content or highlights actually changed
        let currentStorageString = textStorage.string
        let highlightsChanged = !highlights.isEmpty || (textLength > 0 && textStorage.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
        if currentStorageString != currentText || highlightsChanged || itemChanged {
            // Preserve selection before replacing
            let selectedRange = textView.selectedRange()
            textStorage.setAttributedString(attributed)
            // Restore selection if still valid
            if selectedRange.location + selectedRange.length <= textLength {
                textView.setSelectedRange(selectedRange)
            }
        }

        // Auto-scroll to densest highlight on item change
        if itemChanged && !highlights.isEmpty {
            let targetHighlight = highlights.first { $0.start == densestHighlightStart } ?? highlights[0]
            let targetRange = targetHighlight.nsRange(in: currentText)
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                guard let scrollView = textView.enclosingScrollView else { return }
                textView.layoutManager?.ensureLayout(for: textView.textContainer!)

                let glyphRange = textView.layoutManager?.glyphRange(forCharacterRange: targetRange, actualCharacterRange: nil) ?? targetRange
                guard let rect = textView.layoutManager?.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer!) else { return }

                let highlightRect = rect.offsetBy(dx: textView.textContainerInset.width, dy: textView.textContainerInset.height)
                let visibleRect = scrollView.documentVisibleRect
                if !visibleRect.contains(highlightRect) {
                    textView.scrollToVisible(highlightRect.insetBy(dx: 0, dy: -50))
                }
            }
        }
    }

    private func highlightStyle(for kind: HighlightKind) -> (NSColor, Bool) {
        switch kind {
        case .exact, .prefix:
            return (NSColor.systemOrange.withAlphaComponent(0.5), true)
        case .fuzzy:
            return (NSColor.systemYellow.withAlphaComponent(0.4), false)
        case .subsequence:
            return (NSColor.systemBlue.withAlphaComponent(0.3), false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var currentItemId: Int64 = 0
        var isEditing = false
        var lastAppliedFontSize: CGFloat = 0
        var onTextChange: ((String) -> Void)?

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
        }

        func textDidChange(_ notification: Notification) {
            // Called on each keystroke
            guard let textView = notification.object as? NSTextView else { return }
            onTextChange?(textView.string)
        }
    }
}

// MARK: - Link Preview (LPLinkView)

import LinkPresentation

/// Native link preview using LPLinkView
struct LinkPreviewView: NSViewRepresentable {
    let url: String
    let metadataState: LinkMetadataState

    func makeNSView(context: Context) -> LPLinkView {
        let linkView = LPLinkView()
        if let metadata = buildMetadata() {
            linkView.metadata = metadata
        }
        return linkView
    }

    func updateNSView(_ linkView: LPLinkView, context: Context) {
        guard context.coordinator.lastURL != url ||
              context.coordinator.lastMetadataState != metadataState else {
            return
        }
        context.coordinator.lastURL = url
        context.coordinator.lastMetadataState = metadataState

        if let metadata = buildMetadata() {
            linkView.metadata = metadata
        }
    }

    private func buildMetadata() -> LPLinkMetadata? {
        guard let urlObj = URL(string: url) else { return nil }
        let metadata = LPLinkMetadata()
        metadata.originalURL = urlObj
        metadata.url = urlObj

        if case .loaded(let title, _, let imageData) = metadataState {
            metadata.title = title
            if let imageData, let nsImage = NSImage(data: imageData) {
                metadata.imageProvider = NSItemProvider(object: nsImage)
            }
        }
        return metadata
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var lastURL: String?
        var lastMetadataState: LinkMetadataState?
    }
}

// MARK: - Item Row

struct ItemRow: View, Equatable {
    let metadata: ItemMetadata
    let matchData: MatchData?  // Only present in search mode
    let isSelected: Bool
    let hasUserNavigated: Bool
    let isEditingPreview: Bool  // True when user is editing text in preview pane
    let hasPendingEdit: Bool    // True when this item has unsaved text edits
    let onTap: () -> Void

    private var accentSelected: Bool { isSelected && hasUserNavigated && !isEditingPreview }

    // Fixed height for exactly 1 line of text at font size 15
    private let rowHeight: CGFloat = 32

    // MARK: - Display Text (Simplified - SwiftUI handles truncation)

    /// Text to display - uses matchData.text if in search mode, otherwise metadata.snippet
    /// SwiftUI's Three-Part HStack handles truncation with proper ellipsis via layout priorities
    private var displayText: String {
        matchData?.text.isEmpty == false ? matchData!.text : metadata.snippet
    }

    /// Highlights for display - passed directly from Rust (already adjusted for normalization)
    private var displayHighlights: [HighlightRange] {
        matchData?.highlights ?? []
    }


    // Define exactly what constitutes a "change" for SwiftUI diffing
    // Note: onTap closure is intentionally excluded from equality comparison
    nonisolated static func == (lhs: ItemRow, rhs: ItemRow) -> Bool {
        return lhs.isSelected == rhs.isSelected &&
               lhs.hasUserNavigated == rhs.hasUserNavigated &&
               lhs.isEditingPreview == rhs.isEditingPreview &&
               lhs.hasPendingEdit == rhs.hasPendingEdit &&
               lhs.metadata == rhs.metadata &&
               lhs.matchData == rhs.matchData
    }

    var body: some View {
        // 1. Wrap the content inside a Button
        Button(action: onTap) {
            HStack(spacing: 6) {
            // Content type icon with source app badge overlay
            ZStack(alignment: .bottomTrailing) {
                // Main icon: image thumbnail, browser icon for links, color swatch, or SF symbol
                Group {
                    switch metadata.icon {
                    case .thumbnail(let bytes):
                        if let nsImage = NSImage(data: Data(bytes)) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "photo")
                                .resizable()
                        }
                    case .colorSwatch(let rgba):
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: NSColor(
                                red: CGFloat((rgba >> 24) & 0xFF) / 255.0,
                                green: CGFloat((rgba >> 16) & 0xFF) / 255.0,
                                blue: CGFloat((rgba >> 8) & 0xFF) / 255.0,
                                alpha: CGFloat(rgba & 0xFF) / 255.0
                            )))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                            )
                    case .symbol(let iconType):
                        if case .link = iconType,
                           let browserURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://")!) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: browserURL.path))
                                .resizable()
                        } else if case .file = iconType,
                                  let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: finderURL.path))
                                .resizable()
                        } else {
                            Image(nsImage: NSWorkspace.shared.icon(for: iconType.utType))
                                .resizable()
                        }
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                // Badge: Source app icon
                // Show for symbols (except pure link icons) and thumbnails (images, links with images)
                if let bundleID = metadata.sourceAppBundleId,
                   let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    // Skip badge for symbol links/files (app icon is already shown)
                    let showBadge: Bool = {
                        switch metadata.icon {
                        case .symbol(let iconType):
                            return iconType != .link && iconType != .file
                        case .thumbnail, .colorSwatch:
                            return true
                        }
                    }()

                    if showBadge {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                            .resizable()
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                            .offset(x: 4, y: 4)
                    }
                }
            }
            .frame(width: 38, height: 38)
            .allowsHitTesting(false)

            // Line number (shown in search mode when line > 1)
            if let matchData, matchData.lineNumber > 1 {
                Text("L\(matchData.lineNumber):")
                    .font(.custom(FontManager.mono, size: 13))
                    .foregroundColor(accentSelected ? .white.opacity(0.7) : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .allowsHitTesting(false)
            }

            // Pending edit indicator
            if hasPendingEdit {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundColor(accentSelected ? .white.opacity(0.7) : .secondary)
                    .allowsHitTesting(false)
            }

            // Text content - SwiftUI Three-Part HStack with layout priorities
            HighlightedTextView(
                text: displayText,
                highlights: displayHighlights,
                accentSelected: accentSelected
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            .layoutPriority(1)


        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background {
            if isSelected && hasUserNavigated && isEditingPreview {
                // Editing state: darker grey background
                Color.primary.opacity(0.35)
            } else if accentSelected {
                selectionBackground()
            } else if isSelected {
                Color.primary.opacity(0.225)
            } else {
                Color.clear
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        }
        // 2. Apply the plain style so it behaves like a standard row instead of a system button
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayText)
        .accessibilityHint(AppSettings.shared.pasteMode == .autoPaste ? String(localized: "Double tap to paste") : String(localized: "Double tap to copy"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

}

// MARK: - Three-Part HStack Highlighted Text

/// SwiftUI-native text view using Three-Part HStack strategy for search highlighting.
/// Uses layout priorities to guarantee the first highlight is always visible while maximizing context.
/// - Prefix: Truncates from head (`.head`) showing "...text"
/// - Highlight: Has `.layoutPriority(1)` to claim space first, never pushed off-screen
/// - Suffix: Truncates from tail (`.tail`) showing "text..."
struct HighlightedTextView: View, Equatable {
    let text: String
    let highlights: [HighlightRange]
    let accentSelected: Bool

    // Define equality for SwiftUI diffing
    nonisolated static func == (lhs: HighlightedTextView, rhs: HighlightedTextView) -> Bool {
        lhs.text == rhs.text && lhs.highlights == rhs.highlights && lhs.accentSelected == rhs.accentSelected
    }

    private var textColor: Color {
        accentSelected ? .white : .primary
    }

    private var font: Font {
        .custom(FontManager.sansSerif, size: 15)
    }

    var body: some View {
        // Use firstTextBaseline so text aligns perfectly even with different weights
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let firstHighlight = highlights.first {
                let startIndex = Int(firstHighlight.start)
                let endIndex = Int(firstHighlight.end)

                // Clamp indices to valid range
                let safeStart = min(max(0, startIndex), text.count)
                let safeEnd = min(max(safeStart, endIndex), text.count)

                let prefixEnd = text.index(text.startIndex, offsetBy: safeStart)
                let matchStart = prefixEnd
                let matchEnd = text.index(text.startIndex, offsetBy: safeEnd)

                let prefix = String(text[..<prefixEnd])
                let match = String(text[matchStart..<matchEnd])
                let suffix = String(text[matchEnd...])

                // 1. PREFIX: Truncates on the left ("...text")
                if !prefix.isEmpty {
                    Text(prefix)
                        .font(font)
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                // 2. HIGHLIGHT: High priority ensures it claims space first
                Text(match)
                    .font(font)
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .truncationMode(.tail) // Fallback if highlight itself is wider than container
                    .layoutPriority(1)     // CRITICAL: Guarantees visibility
                    .background(highlightBackground(for: firstHighlight.kind))

                // 3. SUFFIX: Truncates on the right ("text...")
                // Apply any additional highlights that fall within suffix
                if !suffix.isEmpty {
                    suffixView(suffix: suffix, suffixStartIndex: safeEnd)
                        .font(font)
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

            } else {
                // No highlights - simple text with tail truncation
                Text(text)
                    .font(font)
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        // Ensure text aligns to the left if shorter than container
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Build suffix view with any additional highlights
    @ViewBuilder
    private func suffixView(suffix: String, suffixStartIndex: Int) -> some View {
        // Check for additional highlights in the suffix (beyond the first one)
        let additionalHighlights = highlights.dropFirst().filter { h in
            Int(h.start) >= suffixStartIndex && Int(h.start) < suffixStartIndex + suffix.count
        }

        if additionalHighlights.isEmpty {
            Text(suffix)
        } else {
            // Build attributed string for suffix with additional highlights
            Text(attributedSuffix(suffix: suffix, suffixStartIndex: suffixStartIndex, highlights: Array(additionalHighlights)))
        }
    }

    /// Create AttributedString for suffix with multiple highlights
    private func attributedSuffix(suffix: String, suffixStartIndex: Int, highlights: [HighlightRange]) -> AttributedString {
        var attributed = AttributedString(suffix)

        for highlight in highlights {
            let relativeStart = Int(highlight.start) - suffixStartIndex
            let relativeEnd = Int(highlight.end) - suffixStartIndex

            // Clamp to suffix bounds
            let safeStart = max(0, relativeStart)
            let safeEnd = min(suffix.count, relativeEnd)

            guard safeStart < safeEnd else { continue }

            let startIdx = attributed.index(attributed.startIndex, offsetByCharacters: safeStart)
            let endIdx = attributed.index(attributed.startIndex, offsetByCharacters: safeEnd)

            attributed[startIdx..<endIdx].backgroundColor = highlightBackground(for: highlight.kind)
            if highlight.kind == .subsequence {
                attributed[startIdx..<endIdx].underlineStyle = .single
            }
        }

        return attributed
    }
}

// MARK: - Action Option Row

private struct ActionOptionRow: View {
    let label: String
    let actionID: String
    var isHighlighted: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    if isHighlighted {
                        if isDestructive {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Color.red.opacity(0.8))
                        } else {
                            selectionBackground()
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("Action_\(actionID)")
    }

    private var foregroundColor: Color {
        if isHighlighted { return .white }
        if isDestructive { return .red }
        return .secondary
    }
}

// MARK: - Selection Background

/// Shared selection highlight matching Spotlight's style (H220 S68 B71)
@ViewBuilder
func selectionBackground() -> some View {
    Color.accentColor
        .opacity(0.9)
        .saturation(0.78)
        .brightness(-0.06)
}

// MARK: - Highlight Kind Color Mapping

/// NSColor styling for TextPreviewView (NSAttributedString path)
/// Returns (backgroundColor, shouldUnderline) based on match kind
private func highlightStyle(for kind: HighlightKind) -> (NSColor, Bool) {
    switch kind {
    case .exact, .prefix:
        return (NSColor.yellow.withAlphaComponent(0.4), false)
    case .fuzzy:
        return (NSColor.orange.withAlphaComponent(0.3), false)
    case .subsequence:
        return (NSColor.orange.withAlphaComponent(0.2), true)
    }
}

/// SwiftUI Color for HighlightedTextView (SwiftUI Text path)
private func highlightBackground(for kind: HighlightKind) -> Color {
    switch kind {
    case .exact, .prefix:
        return Color.yellow.opacity(0.4)
    case .fuzzy:
        return Color.orange.opacity(0.3)
    case .subsequence:
        return Color.orange.opacity(0.2)
    }
}

// MARK: - Hide Scroll Indicators When System Uses Overlay Style

/// Hides scroll indicators when the system preference is "Show scroll bars: When scrolling" (overlay style).
/// Detects scrolling via ScrollView geometry and shows indicators only while actively scrolling.
/// This prevents the brief scrollbar flash when the panel appears.
private struct HideScrollIndicatorsWhenOverlay: ViewModifier {
    let displayVersion: Int
    @State private var hasScrolled = false

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *), NSScroller.preferredScrollerStyle == .overlay {
            content
                .scrollIndicators(hasScrolled ? .automatic : .never)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, _ in
                    if !hasScrolled {
                        hasScrolled = true
                    }
                }
                .onChange(of: displayVersion) { _, _ in
                    hasScrolled = false
                }
        } else {
            content
        }
    }
}

