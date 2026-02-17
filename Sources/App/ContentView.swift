import SwiftUI
import AppKit
import ClipKittyRust
import os.log
import UniformTypeIdentifiers

struct ContentView: View {
    var store: ClipboardStore
    let onSelect: (Int64, ClipboardContent) -> Void
    let onCopyOnly: (Int64, ClipboardContent) -> Void
    let onDismiss: () -> Void
    var initialSearchQuery: String = ""

    @State private var selectedItemId: Int64?
    @State private var selectedItem: ClipboardItem?
    @State private var searchText: String = ""
    @State private var didApplyInitialSearch = false
    @State private var lastItemsSignature: [Int64] = []  // Track when items change to suppress animation
    @State private var showSearchSpinner = false
    @State private var searchSpinnerTask: Task<Void, Never>?
    @State private var showPreviewSpinner = false
    @State private var previewSpinnerTask: Task<Void, Never>?
    @State private var hasUserNavigated = false
    @State private var showFilterPopover = false
    @State private var showDeleteConfirmation = false
    @State private var highlightedFilterIndex: Int = 0
    @State private var showActionsPopover = false
    @State private var highlightedActionIndex: Int = 0
    enum FocusTarget: Hashable {
        case search
        case filterDropdown
        case actionsDropdown
    }
    @FocusState private var focusTarget: FocusTarget?

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
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
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

        .alert("Delete Item", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteSelectedItem()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let item = selectedItem {
                Text("Delete \"\(item.itemMetadata.snippet)\"?")
            }
        }

        .onAppear {
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
        .onChange(of: store.displayVersion) { _, _ in
            // Reset local state when store signals a display reset
            hasUserNavigated = false
            // But preserve initial search if it was just applied
            if didApplyInitialSearch && !initialSearchQuery.isEmpty {
                didApplyInitialSearch = false // Allow reset next time
            } else {
                searchText = ""
            }
            showFilterPopover = false
            showActionsPopover = false
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
            searchSpinnerTask?.cancel()
            if case .resultsLoading = newState {
                searchSpinnerTask = debouncedSpinnerTask {
                    if case .resultsLoading = self.store.state { self.showSearchSpinner = true }
                }
            } else {
                showSearchSpinner = false
            }
        }
        .onChange(of: searchText) { _, newValue in
            hasUserNavigated = false
            store.setSearchQuery(newValue)
        }
        .onChange(of: store.contentTypeFilter) { _, _ in
            // Reset selection when filter changes
            hasUserNavigated = false
            selectedItemId = firstItemId
            selectedItem = nil
        }
        .onChange(of: selectedItemId) { _, newId in
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
            previewSpinnerTask?.cancel()
            if newItem == nil && selectedItemId != nil {
                previewSpinnerTask = debouncedSpinnerTask {
                    if self.selectedItem == nil && self.selectedItemId != nil { self.showPreviewSpinner = true }
                }
            } else {
                showPreviewSpinner = false
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

    private func focusFilterDropdown() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            focusTarget = .filterDropdown
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
        onSelect(item.itemMetadata.itemId, item.content)
    }

    private func copyOnlySelection() {
        guard let item = selectedItem else { return }
        onCopyOnly(item.itemMetadata.itemId, item.content)
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

        store.delete(itemId: id)
        selectedItemId = nextId
        selectedItem = nil
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.custom(FontManager.sansSerif, size: 17).weight(.medium))

            TextField("Clipboard History Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.custom(FontManager.sansSerif, size: 17))
                .tint(.primary)
                .focused($focusTarget, equals: .search)
                .accessibilityIdentifier("SearchField")
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { keyPress in
                    if keyPress.modifiers.contains(.option) {
                        guard selectedItem != nil else { return .handled }
                        let actions = actionItems
                        highlightedActionIndex = actions.count - 1
                        showActionsPopover = true
                        focusActionsDropdown()
                        return .handled
                    }
                    confirmSelection()
                    return .handled
                }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
                .onKeyPress(.tab) {
                    let allOptions = Self.filterOptions
                    highlightedFilterIndex = allOptions.firstIndex(where: { $0.0 == store.contentTypeFilter }) ?? 0
                    showFilterPopover = true
                    focusFilterDropdown()
                    return .handled
                }
                .onKeyPress(characters: .decimalDigits, phases: .down) { keyPress in
                    handleNumberKey(keyPress)
                }
                .onKeyPress(.delete) {
                    guard selectedItemId != nil else { return .ignored }
                    showDeleteConfirmation = true
                    return .handled
                }
                .onKeyPress(.deleteForward) {
                    guard selectedItemId != nil else { return .ignored }
                    showDeleteConfirmation = true
                    return .handled
                }

            if showSearchSpinner {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }

            filterDropdown
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
    }

    // MARK: - Filter Dropdown

    private var filterLabel: String {
        switch store.contentTypeFilter {
        case .all: return "All Types"
        case .text: return "Text"
        case .images: return "Images"
        case .links: return "Links"
        case .colors: return "Colors"
        case .files: return "Files"
        }
    }

    private var filterDropdown: some View {
        Button {
            let allOptions = Self.filterOptions
            highlightedFilterIndex = allOptions.firstIndex(where: { $0.0 == store.contentTypeFilter }) ?? 0
            showFilterPopover.toggle()
            if showFilterPopover {
                focusFilterDropdown()
            }
        } label: {
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
        .popover(isPresented: $showFilterPopover, arrowEdge: .bottom) {
            filterPopoverContent
        }
    }

    private static let filterOptions: [(ContentTypeFilter, String)] = {
        var options: [(ContentTypeFilter, String)] = [
            (.all, "All Types"),
            (.text, "Text"),
            (.images, "Images"),
            (.links, "Links"),
            (.colors, "Colors"),
        ]
        options.append((.files, "Files"))
        return options
    }()

    private var filterPopoverContent: some View {
        let options = Self.filterOptions
        return VStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, entry in
                let (option, label) = entry
                if index == 1 {
                    Divider().padding(.horizontal, 4).padding(.vertical, 3)
                }
                FilterOptionRow(
                    label: label,
                    isSelected: store.contentTypeFilter == option,
                    isHighlighted: highlightedFilterIndex == index,
                    action: {
                        store.setContentTypeFilter(option)
                        showFilterPopover = false
                        focusSearchField()
                    }
                )
            }
        }
        .padding(10)
        .frame(width: 160)
        .focusable()
        .focused($focusTarget, equals: .filterDropdown)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            highlightedFilterIndex = max(highlightedFilterIndex - 1, 0)
            return .handled
        }
        .onKeyPress(.downArrow) {
            highlightedFilterIndex = min(highlightedFilterIndex + 1, options.count - 1)
            return .handled
        }
        .onKeyPress(.return, phases: .down) { _ in
            let selected = options[highlightedFilterIndex]
            store.setContentTypeFilter(selected.0)
            showFilterPopover = false
            focusSearchField()
            return .handled
        }
        .onKeyPress(.escape) {
            showFilterPopover = false
            focusSearchField()
            return .handled
        }
        .onKeyPress(.tab) {
            showFilterPopover = false
            focusSearchField()
            return .handled
        }
        .onAppear {
            let allOptions = Self.filterOptions
            highlightedFilterIndex = allOptions.firstIndex(where: { $0.0 == store.contentTypeFilter }) ?? 0
            focusFilterDropdown()
        }
    }

    private func handleNumberKey(_ keyPress: KeyPress) -> KeyPress.Result {
        guard let number = Int(keyPress.characters),
              number >= 1 && number <= 9,
              keyPress.modifiers.contains(.command) else {
            return .ignored
        }

        let index = number - 1
        guard index < itemCount else { return .ignored }

        selectedItemId = itemId(at: index)
        confirmSelection()
        return .handled
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
            } else if showPreviewSpinner {
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
            TextPreviewView(
                text: item.textContent,
                fontName: FontManager.mono,
                fontSize: 15,
                highlights: selectedItemMatchData?.fullContentHighlights ?? [],
                densestHighlightStart: selectedItemMatchData?.densestHighlightStart ?? 0
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image(let data, let description):
            ScrollView(.vertical, showsIndicators: true) {
                imagePreview(data: data, description: description)
            }
        case .link(let url, let metadataState):
            ScrollView(.vertical, showsIndicators: true) {
                linkPreview(url: url, metadataState: metadataState, itemId: item.itemMetadata.itemId)
            }
        case .file(_, let files):
            FilePreviewView(files: files)
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

    private func metadataFooter(for item: ClipboardItem) -> some View {
        HStack(spacing: 12) {
            Label(item.timeAgo, systemImage: "clock")
                .lineLimit(1)
            if let app = item.sourceApp {
                HStack(spacing: 4) {
                    if let bundleID = item.sourceAppBundleID,
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
            Spacer(minLength: 0)
            actionsButton
                .fixedSize()
            Button(buttonLabel(for: item)) { confirmSelection() }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .fixedSize()
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 17)
        .padding(.vertical, 11)
        .background(.black.opacity(0.05))
    }

    private func buttonLabel(for item: ClipboardItem) -> String {
        return AppSettings.shared.shouldShowPasteLabel ? "⏎ paste" : "⏎ copy"
    }

    // MARK: - Actions Dropdown

    private enum ActionItem: Equatable {
        case defaultAction  // copy or paste based on settings
        case copyOnly       // only shown when default is paste
        case delete
    }

    private var actionItems: [ActionItem] {
        var items: [ActionItem] = [.delete]
        if AppSettings.shared.shouldShowPasteLabel {
            items.append(.copyOnly)
        }
        items.append(.defaultAction)
        return items
    }

    private func actionLabel(for action: ActionItem) -> String {
        switch action {
        case .defaultAction:
            return AppSettings.shared.shouldShowPasteLabel ? "Paste" : "Copy"
        case .copyOnly:
            return "Copy"
        case .delete:
            return "Delete"
        }
    }

    private func actionShortcut(for action: ActionItem) -> String? {
        switch action {
        case .defaultAction: return "⏎"
        case .copyOnly: return nil
        case .delete: return "⌫"
        }
    }

    private var actionsButton: some View {
        Button {
            let actions = actionItems
            highlightedActionIndex = actions.count - 1
            showActionsPopover.toggle()
            if showActionsPopover {
                focusActionsDropdown()
            }
        } label: {
            Text("⌥⏎ Actions")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ActionsButton")
        .popover(isPresented: $showActionsPopover, arrowEdge: .top) {
            actionsPopoverContent
        }
    }

    private var actionsPopoverContent: some View {
        let actions = actionItems
        return VStack(spacing: 2) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                if action == .delete && index < actions.count - 1 {
                    ActionOptionRow(
                        label: actionLabel(for: action),
                        shortcut: actionShortcut(for: action),
                        isHighlighted: highlightedActionIndex == index,
                        isDestructive: true,
                        action: { performAction(action) }
                    )
                    Divider().padding(.horizontal, 4).padding(.vertical, 3)
                } else {
                    ActionOptionRow(
                        label: actionLabel(for: action),
                        shortcut: actionShortcut(for: action),
                        isHighlighted: highlightedActionIndex == index,
                        isDestructive: action == .delete,
                        action: { performAction(action) }
                    )
                }
            }
        }
        .padding(10)
        .frame(width: 160)
        .focusable()
        .focused($focusTarget, equals: .actionsDropdown)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            highlightedActionIndex = max(highlightedActionIndex - 1, 0)
            return .handled
        }
        .onKeyPress(.downArrow) {
            highlightedActionIndex = min(highlightedActionIndex + 1, actions.count - 1)
            return .handled
        }
        .onKeyPress(.return, phases: .down) { _ in
            let action = actions[highlightedActionIndex]
            performAction(action)
            return .handled
        }
        .onKeyPress(.escape) {
            showActionsPopover = false
            focusSearchField()
            return .handled
        }
        .onKeyPress(.tab) {
            showActionsPopover = false
            focusSearchField()
            return .handled
        }
        .onAppear {
            let actions = actionItems
            highlightedActionIndex = actions.count - 1
            focusActionsDropdown()
        }
    }

    private func performAction(_ action: ActionItem) {
        showActionsPopover = false
        switch action {
        case .defaultAction:
            confirmSelection()
        case .copyOnly:
            copyOnlySelection()
        case .delete:
            showDeleteConfirmation = true
            focusSearchField()
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
            return "No clipboard history"
        } else {
            return "No results"
        }
    }

    @ViewBuilder
    private func linkPreview(url: String, metadataState: LinkMetadataState, itemId: Int64) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Native link preview using LPLinkView
            LinkPreviewView(url: url, metadataState: metadataState)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 100, maxHeight: 300)

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
                Text(file.filename)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)

                Text(file.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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

    private static func formatFileSize(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024

        if gb >= 1 { return String(format: "%.1f GB", gb) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        if kb >= 1 { return String(format: "%.0f KB", kb) }
        return "\(bytes) bytes"
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
        textView.isRichText = true  // Enable rich text for highlighting
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

    private func scaledFontSize(baseFont: NSFont, containerWidth: CGFloat) -> CGFloat {
        let lines = text.components(separatedBy: "\n")
        if lines.count >= 10 { return fontSize }

        let inset: CGFloat = 32 // textContainerInset.width * 2
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

        let scale = min(2.0, availableWidth / maxLineWidth)
        return fontSize * scale
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        let baseFont = NSFont(name: fontName, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let scaledSize = scaledFontSize(baseFont: baseFont, containerWidth: nsView.contentSize.width)
        let font = NSFont(name: fontName, size: scaledSize) ?? NSFont.monospacedSystemFont(ofSize: scaledSize, weight: .regular)

        // Only update if text or highlights changed
        let currentText = textView.string
        let shouldScroll = currentText != text || context.coordinator.lastHighlights != highlights
        if shouldScroll {
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
                    let nsRange = range.nsRange
                    if nsRange.location + nsRange.length <= attributed.length {
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
                let targetRange = targetHighlight.nsRange
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

        textView.textContainer?.containerSize = NSSize(
            width: nsView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        textView.frame = NSRect(x: 0, y: 0, width: nsView.contentSize.width, height: textView.frame.height)
    }


    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var lastHighlights: [HighlightRange] = []
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
                metadata.imageProvider = NSItemProvider(object: nsImage.croppedIfTooTall(maxRatio: 1.5))
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
    let onTap: () -> Void

    private var accentSelected: Bool { isSelected && hasUserNavigated }

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
            if accentSelected {
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
        .accessibilityHint(AppSettings.shared.shouldShowPasteLabel ? "Double tap to paste" : "Double tap to copy")
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

// MARK: - Filter Option Row

private struct FilterOptionRow: View {
    let label: String
    let isSelected: Bool
    var isHighlighted: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(isHighlighted ? .white : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    if isHighlighted {
                        selectionBackground()
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    } else {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(isSelected ? Color.primary.opacity(0.1) : isHovered ? Color.primary.opacity(0.05) : Color.clear)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Action Option Row

private struct ActionOptionRow: View {
    let label: String
    let shortcut: String?
    var isHighlighted: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(foregroundColor)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(isHighlighted ? Color.white.opacity(0.7) : Color.secondary.opacity(0.6))
                }
            }
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
        .accessibilityIdentifier("Action_\(label)")
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
private func selectionBackground() -> some View {
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
        if NSScroller.preferredScrollerStyle == .overlay {
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


// MARK: - Extensions

extension NSImage {
    /// Crops image from top if height/width > maxRatio.
    func croppedIfTooTall(maxRatio: CGFloat) -> NSImage {
        let size = self.size
        guard size.width > 0, size.height > 0, size.height / size.width > maxRatio else { return self }

        let newHeight = size.width * maxRatio
        let cropRect = NSRect(x: 0, y: size.height - newHeight, width: size.width, height: newHeight)

        let result = NSImage(size: cropRect.size)
        result.lockFocus()
        self.draw(in: NSRect(origin: .zero, size: cropRect.size), from: cropRect, operation: .copy, fraction: 1.0)
        result.unlockFocus()
        return result
    }
}
