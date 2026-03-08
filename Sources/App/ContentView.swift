import SwiftUI
import AppKit
import ClipKittyRust
import STTextKitPlus
import os.log
import UniformTypeIdentifiers

/// Max time to show stale content before clearing to spinner during slow loads.
/// Used for both preview item loading and search result loading.
private let staleContentTimeout: Duration = .milliseconds(150)

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

private enum FilterPopoverState: Equatable {
    case hidden
    case visible(highlightedIndex: Int)
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
    @State private var didApplyInitialSearch = false
    @State private var lastItemsSignature: [Int64] = []  // Track when items change to suppress animation
    @State private var selectedItemLoadGeneration = 0
    @State private var searchSpinner: SpinnerState = .idle
    @State private var previewSpinner: SpinnerState = .idle
    @State private var lastPreviewSelection: PreviewSelection?
    @State private var prefetchCache: [Int64: ClipboardItem] = [:]  // Cache for prefetched adjacent items
    @State private var hasUserNavigated = false
    @State private var filterPopover: FilterPopoverState = .hidden
    @State private var actionsPopover: ActionsPopoverState = .hidden
    @State private var commandNumberEventMonitor: Any?
    /// Prefetch match data beyond the currently visible rows so scrolling rarely lands on lazy items.
    private let matchDataPrefetchBuffer = 20
    enum FocusTarget: Hashable {
        case search
        case filterDropdown
        case actionsDropdown
    }
    @FocusState private var focusTarget: FocusTarget?

    private var filterPopoverBinding: Binding<Bool> {
        Binding(
            get: { if case .visible = filterPopover { return true } else { return false } },
            set: { if !$0 { filterPopover = .hidden } }
        )
    }

    private var actionsPopoverBinding: Binding<Bool> {
        Binding(
            get: { if case .hidden = actionsPopover { return false } else { return true } },
            set: { if !$0 { actionsPopover = .hidden } }
        )
    }

    /// Computed on every access - acceptable for small result sets (typical: <100 items).
    /// If performance becomes an issue with large result sets, consider caching with onChange(of: store.state).
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

    private struct PreviewSelection {
        let item: ClipboardItem
        let matchData: MatchData?
    }

    private enum PreviewPaneState {
        case emptyResults
        case noSelection
        case loading(stale: PreviewSelection?)
        case loaded(PreviewSelection)
    }

    /// Get match data for a specific item from the current result set.
    private func matchDataForItem(_ itemId: Int64) -> MatchData? {
        switch store.state {
        case .results(_, let items, _), .resultsLoading(_, let items):
            return items.first { $0.itemMetadata.itemId == itemId }?.matchData
        default:
            return nil
        }
    }

    /// Coherent preview state: text content and highlights always come from the same item ID.
    private var previewSelection: PreviewSelection? {
        guard let item = selectedItem else { return nil }
        return makePreviewSelection(for: item)
    }

    private var previewPaneState: PreviewPaneState {
        if let previewSelection {
            return .loaded(previewSelection)
        }
        if itemIds.isEmpty {
            return .emptyResults
        }
        if selectedItemId != nil {
            return .loading(stale: lastPreviewSelection)
        }
        return .noSelection
    }

    private var isPreviewSpinnerVisible: Bool {
        if case .visible = previewSpinner {
            return true
        }
        return false
    }

    private func makePreviewSelection(for item: ClipboardItem) -> PreviewSelection {
        PreviewSelection(
            item: item,
            matchData: matchDataForItem(item.itemMetadata.itemId)
        )
    }

    private var firstItemId: Int64? {
        itemIds.first
    }

    private var itemCount: Int {
        itemIds.count
    }

    /// Computed on every access - acceptable for small result sets (typical: <100 items).
    /// O(n) search through itemIds array, but n is small in practice.
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
        }
        // MARK: - onChange Handlers (Ordered by Dependency)
        // 1. Display reset (highest priority - resets all other state)
        .onChange(of: store.displayVersion) { _, _ in
            // Reset local state when store signals a display reset
            hasUserNavigated = false
            prefetchCache.removeAll()
            // But preserve initial search if it was just applied
            if didApplyInitialSearch && !initialSearchQuery.isEmpty {
                didApplyInitialSearch = false // Allow reset next time
            } else {
                searchText = ""
            }
            filterPopover = .hidden
            actionsPopover = .hidden
            // Select first item whenever display resets (re-open)
            if let firstId = firstItemId {
                loadItem(id: firstId)
            } else {
                selectedItemId = nil
                selectedItem = nil
                lastPreviewSelection = nil
            }
            focusSearchField()
        }
        // 2. Store state changes (updates available items and spinners)
        .onChange(of: store.state) { _, newState in
            // Validate selection - ensure selected item still exists in results
            if let selectedItemId, !itemIds.contains(selectedItemId) {
                self.selectedItemId = firstItemId
                self.selectedItem = nil
                self.lastPreviewSelection = nil
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

            if case .results = newState,
               let selectedItemId,
               matchDataForItem(selectedItemId) == nil {
                store.loadMatchDataForItems(itemIds: [selectedItemId])
            }
        }
        // 3. Search query changes (triggers store refresh)
        .onChange(of: searchText) { _, newValue in
            hasUserNavigated = false
            prefetchCache.removeAll()
            store.setSearchQuery(newValue)
        }
        // 4. Filter changes (triggers store refresh and resets selection)
        .onChange(of: store.contentTypeFilter) { _, _ in
            // Reset selection when filter changes
            hasUserNavigated = false
            prefetchCache.removeAll()
            selectedItemId = firstItemId
            selectedItem = nil
            lastPreviewSelection = nil
        }
        // 5. Item list changes (validates selection position)
        .onChange(of: itemIds) { oldOrder, newOrder in
            // Select first item by default if nothing is selected
            guard let selectedItemId else {
                self.selectedItemId = firstItemId
                hasUserNavigated = false
                return
            }
            // Check if item still exists in new order
            if !newOrder.contains(selectedItemId) {
                self.selectedItemId = firstItemId
                self.selectedItem = nil
                self.lastPreviewSelection = nil
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
                self.lastPreviewSelection = nil
                hasUserNavigated = false
            }
        }
        // 6. Selection ID changes (triggers item fetch)
        .onChange(of: selectedItemId) { _, newId in
            // Fetch full item when selection changes
            guard let newId else {
                selectedItemLoadGeneration += 1
                selectedItem = nil
                lastPreviewSelection = nil
                return
            }
            store.loadMatchDataForItems(itemIds: [newId])
            refreshSelectedItem(for: newId)
        }
        // 7. Selected item changes (updates preview spinner)
        .onChange(of: selectedItem) { _, newItem in
            if let newItem {
                lastPreviewSelection = makePreviewSelection(for: newItem)
            }
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
    }

    // MARK: - Selection Management

    /// Select an item. Preview loading happens in `onChange(of: selectedItemId)`.
    private func loadItem(id: Int64) {
        selectedItemId = id
    }

    /// Load the selected preview item, ignoring completions for stale selections.
    /// Uses prefetch cache for instant display when navigating to adjacent items.
    private func refreshSelectedItem(for id: Int64) {
        selectedItemLoadGeneration += 1
        let generation = selectedItemLoadGeneration

        // Fast path 1: first item is already available from search results
        if let firstItem = stateFirstItem, firstItem.itemMetadata.itemId == id {
            selectedItem = firstItem
            prefetchAdjacentItems(around: id)
            return
        }

        // Fast path 2: item is in prefetch cache
        if let cachedItem = prefetchCache[id] {
            selectedItem = cachedItem
            prefetchAdjacentItems(around: id)
            return
        }

        // Slow path: fetch from store
        // Keep old preview visible briefly, then clear to trigger spinner
        Task {
            // Start timeout task to clear stale preview
            let timeoutTask = Task {
                try? await Task.sleep(for: staleContentTimeout)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if selectedItemLoadGeneration == generation && selectedItemId == id {
                        selectedItem = nil
                    }
                }
            }

            let item = await store.fetchItem(id: id)
            timeoutTask.cancel()

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard selectedItemLoadGeneration == generation, selectedItemId == id else { return }
                selectedItem = item
                if item != nil {
                    prefetchAdjacentItems(around: id)
                }
            }
        }
    }

    /// Prefetch items adjacent to the given ID for instant navigation.
    private func prefetchAdjacentItems(around id: Int64) {
        guard let currentIndex = itemIds.firstIndex(of: id) else { return }

        // Prefetch prev and next items
        var toPrefetch: [Int64] = []
        if currentIndex > 0 {
            let prevId = itemIds[currentIndex - 1]
            if prefetchCache[prevId] == nil && stateFirstItem?.itemMetadata.itemId != prevId {
                toPrefetch.append(prevId)
            }
        }
        if currentIndex < itemIds.count - 1 {
            let nextId = itemIds[currentIndex + 1]
            if prefetchCache[nextId] == nil && stateFirstItem?.itemMetadata.itemId != nextId {
                toPrefetch.append(nextId)
            }
        }

        guard !toPrefetch.isEmpty else { return }

        Task {
            for itemId in toPrefetch {
                guard !Task.isCancelled else { return }
                if let item = await store.fetchItem(id: itemId) {
                    await MainActor.run {
                        // Only cache if still relevant (item still in list)
                        if itemIds.contains(itemId) {
                            prefetchCache[itemId] = item
                        }
                    }
                }
            }
        }
    }

    /// Schedule a spinner to show after staleContentTimeout if a condition persists.
    private func debouncedSpinnerTask(
        action: @escaping @MainActor @Sendable () -> Void
    ) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(for: staleContentTimeout)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private func setFocus(to target: FocusTarget, delay: Duration = .milliseconds(1)) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            focusTarget = target
        }
    }

    private func focusSearchField() {
        setFocus(to: .search, delay: .milliseconds(1))
    }

    private func focusFilterDropdown() {
        setFocus(to: .filterDropdown, delay: .milliseconds(50))
    }

    private func focusActionsDropdown() {
        setFocus(to: .actionsDropdown, delay: .milliseconds(50))
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
        lastPreviewSelection = nil
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
                .onKeyPress(.return, phases: .down) { _ in
                    confirmSelection()
                    return .handled
                }
                .onKeyPress("k", phases: .down) { keyPress in
                    if keyPress.modifiers.contains(.command) {
                        guard selectedItem != nil else { return .handled }
                        if case .hidden = actionsPopover {
                            let actions = actionItems
                            actionsPopover = .showingActions(highlightedIndex: actions.count - 1)
                            focusActionsDropdown()
                        } else {
                            actionsPopover = .hidden
                        }
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
                .onKeyPress(.tab) {
                    let allOptions = Self.filterOptions
                    let index = allOptions.firstIndex(where: { $0.0 == store.contentTypeFilter }) ?? 0
                    filterPopover = .visible(highlightedIndex: index)
                    focusFilterDropdown()
                    return .handled
                }
                .onKeyPress(characters: .decimalDigits, phases: .down) { keyPress in
                    handleNumberKey(keyPress)
                }
                .onKeyPress(.delete) {
                    guard selectedItemId != nil else { return .ignored }
                    actionsPopover = .showingDeleteConfirm(highlightedIndex: 0)
                    focusActionsDropdown()
                    return .handled
                }
                .onKeyPress(.deleteForward) {
                    guard selectedItemId != nil else { return .ignored }
                    actionsPopover = .showingDeleteConfirm(highlightedIndex: 0)
                    focusActionsDropdown()
                    return .handled
                }

            if case .visible = searchSpinner {
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
        case .all: return String(localized: "All Types")
        case .text: return String(localized: "Text")
        case .images: return String(localized: "Images")
        case .links: return String(localized: "Links")
        case .colors: return String(localized: "Colors")
        case .files: return String(localized: "Files")
        }
    }

    private var filterDropdown: some View {
        Button {
            let allOptions = Self.filterOptions
            let index = allOptions.firstIndex(where: { $0.0 == store.contentTypeFilter }) ?? 0
            if case .visible = filterPopover {
                filterPopover = .hidden
            } else {
                filterPopover = .visible(highlightedIndex: index)
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
        .popover(isPresented: filterPopoverBinding, arrowEdge: .bottom) {
            filterPopoverContent
        }
    }

    private static let filterOptions: [(ContentTypeFilter, String)] = {
        var options: [(ContentTypeFilter, String)] = [
            (.all, String(localized: "All Types")),
            (.text, String(localized: "Text")),
            (.images, String(localized: "Images")),
            (.links, String(localized: "Links")),
            (.colors, String(localized: "Colors")),
        ]
        options.append((.files, String(localized: "Files")))
        return options
    }()

    private var filterPopoverContent: some View {
        let options = Self.filterOptions
        let highlightedIndex: Int
        if case .visible(let idx) = filterPopover {
            highlightedIndex = idx
        } else {
            highlightedIndex = 0
        }
        return VStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, entry in
                let (option, label) = entry
                if index == 1 {
                    Divider().padding(.horizontal, 4).padding(.vertical, 3)
                }
                FilterOptionRow(
                    label: label,
                    isSelected: store.contentTypeFilter == option,
                    isHighlighted: highlightedIndex == index,
                    action: {
                        store.setContentTypeFilter(option)
                        filterPopover = .hidden
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
            if case .visible(let idx) = filterPopover {
                filterPopover = .visible(highlightedIndex: max(idx - 1, 0))
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if case .visible(let idx) = filterPopover {
                filterPopover = .visible(highlightedIndex: min(idx + 1, options.count - 1))
            }
            return .handled
        }
        .onKeyPress(.return, phases: .down) { _ in
            let selected = options[highlightedIndex]
            store.setContentTypeFilter(selected.0)
            filterPopover = .hidden
            focusSearchField()
            return .handled
        }
        .onKeyPress(.escape) {
            filterPopover = .hidden
            focusSearchField()
            return .handled
        }
        .onKeyPress(.tab) {
            filterPopover = .hidden
            focusSearchField()
            return .handled
        }
        .onAppear {
            let allOptions = Self.filterOptions
            let index = allOptions.firstIndex(where: { $0.0 == store.contentTypeFilter }) ?? 0
            filterPopover = .visible(highlightedIndex: index)
            focusFilterDropdown()
        }
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

    /// Called when an item row appears. Prefetches match data for nearby rows that are still lazy.
    private func onItemAppear(index: Int) {
        let startIndex = max(0, index - matchDataPrefetchBuffer)
        let endIndex = min(itemCount - 1, index + matchDataPrefetchBuffer)
        guard startIndex <= endIndex else { return }

        let idsToLoad = (startIndex...endIndex).compactMap { itemId(at: $0) }
        guard !idsToLoad.isEmpty else { return }

        store.loadMatchDataForItems(itemIds: idsToLoad)
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
                    .onAppear { onItemAppear(index: index) }
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
        Group {
            switch previewPaneState {
            case .loaded(let selection):
                VStack(spacing: 0) {
                    previewContent(for: selection.item, matchData: selection.matchData)
                    Divider()
                    metadataFooter(for: selection.item)
                }
            case .loading(let stale):
                ZStack {
                    if let stale {
                        previewContent(for: stale.item, matchData: stale.matchData)
                            .allowsHitTesting(false)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if isPreviewSpinnerVisible {
                        ProgressView()
                    }
                }
            case .emptyResults:
                emptyStateView
            case .noSelection:
                Text("No item selected")
                    .font(.custom(FontManager.sansSerif, size: 16))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.black.opacity(0.05))
    }

    @ViewBuilder
    private func previewContent(for item: ClipboardItem, matchData: MatchData?) -> some View {
        switch item.content {
        case .text, .color:
            TextPreviewView(
                text: item.content.textContent,
                fontName: FontManager.mono,
                fontSize: 15,
                highlights: matchData?.fullContentHighlights ?? [],
                densestHighlightStart: matchData?.densestHighlightStart ?? 0
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

    private func metadataFooter(for item: ClipboardItem) -> some View {
        HStack(spacing: 12) {
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
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 17)
        .padding(.vertical, 11)
        .background(.black.opacity(0.05))
    }

    private func buttonLabel(for item: ClipboardItem) -> String {
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
                    Text(Utilities.formatBytes(Int64(file.fileSize)))
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
        let highlights = HighlightStyler.exactHighlights(in: text, queryWords: queryWords)
        guard !highlights.isEmpty else {
            return Text(text).font(font).foregroundColor(color)
        }

        return Text(HighlightStyler.attributedText(text, highlights: highlights))
            .font(font)
            .foregroundColor(color)
    }

}

// MARK: - Text Preview (AppKit)

struct TextPreviewView: NSViewRepresentable {
    let text: String
    let fontName: String
    let fontSize: CGFloat
    var highlights: [HighlightRange] = []
    var densestHighlightStart: UInt64 = 0

    private enum ScrollTarget {
        case top
        case highlight(NSRange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        // NSTextView() defaults to TextKit 2 on macOS 12+.
        // IMPORTANT: never access .layoutManager — that silently downgrades to TextKit 1.
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
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
        textView.setAccessibilityIdentifier("PreviewTextView")

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
        // computes geometry against the correct width.
        textView.textContainer?.containerSize = NSSize(
            width: containerWidth,
            height: .greatestFiniteMagnitude
        )
        textView.frame = NSRect(x: 0, y: 0, width: containerWidth, height: textView.frame.height)

        let coordinator = context.coordinator
        let textChanged = textView.string != text
        let highlightsChanged = coordinator.lastHighlights != highlights
        let contentWidthChanged = abs(coordinator.lastContentWidth - containerWidth) > 0.5
        coordinator.lastContentWidth = containerWidth

        guard textChanged || highlightsChanged || contentWidthChanged else { return }
        if textChanged || contentWidthChanged {
            coordinator.needsGeometrySync = true
        }

        if textChanged {
            // Text content changed — replace storage attributes (font, color, paragraph style only).
            // Highlights are applied as rendering attributes, not storage attributes.
            //
            // Memory consideration: For very large text (>100KB), NSAttributedString allocation
            // can be expensive. TextKit 2 handles large documents efficiently via lazy layout,
            // but the initial attributed string creation is still proportional to text size.
            // Consider implementing a size limit or truncation if clipboard items exceed ~1MB.
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping

            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ])

            textView.textStorage?.setAttributedString(attributed)
        }

        let tlm = textView.textLayoutManager
        if textChanged || highlightsChanged {
            // Convert highlights to NSTextRanges for the layout manager
            let newMatchRanges = resolveTextRanges(highlights: highlights, text: text, layoutManager: tlm)
            let oldMatchRanges = coordinator.currentMatchRanges

            coordinator.currentMatchRanges = newMatchRanges
            coordinator.lastHighlights = highlights

            if let tlm {
                if textChanged {
                    // Full text replacement — apply all new highlights from scratch
                    for match in newMatchRanges {
                        tlm.setRenderingAttributes(
                            HighlightStyler.renderingAttributes(for: match.kind),
                            for: match.range
                        )
                    }
                } else {
                    // Only highlights changed — diff and invalidate minimally.
                    // Remove old rendering attributes for ranges no longer highlighted
                    let newSet = Set(newMatchRanges.map { MatchRangeKey($0) })
                    for old in oldMatchRanges where !newSet.contains(MatchRangeKey(old)) {
                        tlm.invalidateRenderingAttributes(for: old.range)
                    }

                    // Apply new rendering attributes
                    let oldSet = Set(oldMatchRanges.map { MatchRangeKey($0) })
                    for new in newMatchRanges where !oldSet.contains(MatchRangeKey(new)) {
                        tlm.setRenderingAttributes(
                            HighlightStyler.renderingAttributes(for: new.kind),
                            for: new.range
                        )
                    }
                }
            }
        }

        let scrollTarget: ScrollTarget
        if highlights.isEmpty {
            scrollTarget = .top
        } else {
            let targetHighlight = highlights.first { $0.start == densestHighlightStart } ?? highlights[0]
            scrollTarget = .highlight(targetHighlight.nsRange(in: text))
        }

        scroll(
            textView: textView,
            target: scrollTarget,
            coordinator: coordinator
        )
    }

    // MARK: - Highlight Resolution

    /// Convert [HighlightRange] to [(NSTextRange, HighlightKind)] using the text layout manager.
    private func resolveTextRanges(
        highlights: [HighlightRange],
        text: String,
        layoutManager: NSTextLayoutManager?
    ) -> [MatchRange] {
        guard let tlm = layoutManager,
              let tcm = tlm.textContentManager else { return [] }

        return highlights.compactMap { highlight in
            let nsRange = highlight.nsRange(in: text)
            guard nsRange.location != NSNotFound else { return nil }

            guard let start = tcm.location(tcm.documentRange.location, offsetBy: nsRange.location),
                  let end = tcm.location(start, offsetBy: nsRange.length) else { return nil }

            guard let textRange = NSTextRange(location: start, end: end) else { return nil }
            return MatchRange(range: textRange, kind: highlight.kind,
                              scalarStart: highlight.start, scalarEnd: highlight.end)
        }
    }

    // MARK: - Scroll

    private func scroll(
        textView: NSTextView,
        target: ScrollTarget,
        coordinator: Coordinator
    ) {
        coordinator.scrollGeneration += 1
        let generation = coordinator.scrollGeneration

        performScrollAttempt(
            textView: textView,
            target: target,
            generation: generation,
            coordinator: coordinator,
            attempt: 0
        )
    }

    /// Attempt to scroll to the target position, retrying if layout is not ready.
    /// TextKit 2's lazy layout may not have computed text segment frames immediately,
    /// so we retry with increasing delays up to a maximum number of attempts.
    private func performScrollAttempt(
        textView: NSTextView,
        target: ScrollTarget,
        generation: Int,
        coordinator: Coordinator,
        attempt: Int
    ) {
        // Retry delays: 0ms, 16ms, 32ms, 64ms (total max ~112ms, about 7 frames at 60fps)
        let maxAttempts = 4
        let delayMs = attempt == 0 ? 0 : (16 * (1 << (attempt - 1)))

        let work = { [weak textView] in
            guard let textView else { return }
            guard coordinator.scrollGeneration == generation else { return }
            guard let scrollView = textView.enclosingScrollView else {
                // View hierarchy not ready yet - retry
                if attempt < maxAttempts - 1 {
                    self.performScrollAttempt(
                        textView: textView,
                        target: target,
                        generation: generation,
                        coordinator: coordinator,
                        attempt: attempt + 1
                    )
                }
                return
            }
            guard scrollView.contentSize.width > 0 else {
                if attempt < maxAttempts - 1 {
                    self.performScrollAttempt(
                        textView: textView,
                        target: target,
                        generation: generation,
                        coordinator: coordinator,
                        attempt: attempt + 1
                    )
                }
                return
            }

            if coordinator.needsGeometrySync {
                self.syncTextViewGeometry(textView: textView, containerWidth: scrollView.contentSize.width)
                coordinator.needsGeometrySync = false
            }

            switch target {
            case .top:
                let currentOrigin = scrollView.contentView.bounds.origin
                let newOrigin = NSPoint(x: currentOrigin.x, y: 0)
                guard abs(currentOrigin.y - newOrigin.y) >= 1 else { return }

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                scrollView.contentView.scroll(to: newOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                CATransaction.commit()
                return
            case .highlight:
                break
            }

            guard let tlm = textView.textLayoutManager,
                  let tcm = tlm.textContentManager else { return }
            guard case .highlight(let targetNSRange) = target else { return }

            // Convert NSRange to NSTextRange
            guard let start = tcm.location(tcm.documentRange.location, offsetBy: targetNSRange.location),
                  let end = tcm.location(start, offsetBy: targetNSRange.length),
                  let targetTextRange = NSTextRange(location: start, end: end) else { return }

            // Ensure layout for just this range
            tlm.ensureLayout(for: targetTextRange)

            // Get the frame of the highlight using STTextKitPlus
            // TextKit 2 may return nil if layout isn't fully computed yet
            guard let rect = tlm.textSegmentFrame(in: targetTextRange, type: .highlight) else {
                // Layout not ready - retry with exponential backoff
                if attempt < maxAttempts - 1 {
                    self.performScrollAttempt(
                        textView: textView,
                        target: target,
                        generation: generation,
                        coordinator: coordinator,
                        attempt: attempt + 1
                    )
                }
                return
            }

            // Convert rect to scroll view coordinates.
            let highlightRect = rect.offsetBy(dx: textView.textContainerInset.width, dy: textView.textContainerInset.height)
            var documentHeight: CGFloat = 0
            tlm.enumerateTextLayoutFragments(from: tlm.documentRange.endLocation,
                                              options: [.reverse, .ensuresLayout]) { fragment in
                documentHeight = fragment.layoutFragmentFrame.maxY
                return false  // stop after first (last) fragment
            }

            let visibleHeight = scrollView.documentVisibleRect.height
            let targetOffsetY = highlightRect.midY - (visibleHeight / 3)
            let contentHeight = max(
                textView.bounds.height,
                documentHeight + textView.textContainerInset.height * 2
            )
            let maxScrollY = max(0, contentHeight - visibleHeight)
            let clampedY = min(max(0, targetOffsetY), maxScrollY)

            let currentOrigin = scrollView.contentView.bounds.origin
            let newOrigin = NSPoint(x: currentOrigin.x, y: clampedY)
            guard abs(currentOrigin.y - newOrigin.y) >= 1 else { return }

            // Perform scroll with animations explicitly disabled
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scrollView.contentView.scroll(to: newOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            CATransaction.commit()
        }

        if delayMs == 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
        }
    }

    private func syncTextViewGeometry(textView: NSTextView, containerWidth: CGFloat) {
        textView.textContainer?.containerSize = NSSize(
            width: containerWidth,
            height: .greatestFiniteMagnitude
        )
        textView.frame = NSRect(x: 0, y: 0, width: containerWidth, height: textView.frame.height)

        guard let scrollView = textView.enclosingScrollView else {
            return
        }

        let targetHeight = max(
            scrollView.contentSize.height,
            documentHeight(for: textView) + textView.textContainerInset.height * 2
        )
        textView.frame = NSRect(x: 0, y: 0, width: containerWidth, height: targetHeight)
    }

    private func documentHeight(for textView: NSTextView) -> CGFloat {
        guard let tlm = textView.textLayoutManager else { return 0 }

        var documentHeight: CGFloat = 0
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.endLocation,
            options: [.reverse, .ensuresLayout]
        ) { fragment in
            documentHeight = fragment.layoutFragmentFrame.maxY
            return false
        }
        return documentHeight
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Supporting Types

    /// A resolved match: the original scalar indices (for identity) plus the TextKit 2 range (for operations).
    struct MatchRange {
        let range: NSTextRange
        let kind: HighlightKind
        let scalarStart: UInt64
        let scalarEnd: UInt64
    }

    /// Hashable key for efficient Set-based diffing of match ranges.
    private struct MatchRangeKey: Hashable {
        let scalarStart: UInt64
        let scalarEnd: UInt64
        let kind: HighlightKind

        init(_ match: MatchRange) {
            self.scalarStart = match.scalarStart
            self.scalarEnd = match.scalarEnd
            self.kind = match.kind
        }
    }

    class Coordinator {
        var lastHighlights: [HighlightRange] = []
        /// Current match ranges for diffing on next update.
        var currentMatchRanges: [MatchRange] = []
        var scrollGeneration: Int = 0
        var lastContentWidth: CGFloat = 0
        var needsGeometrySync: Bool = false
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
    let matchData: MatchData?
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
        if let matchText = matchData?.text, !matchText.isEmpty {
            return matchText
        }
        return metadata.snippet
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
            if let lineNumber = matchData?.lineNumber, lineNumber > 1 {
                Text("L\(lineNumber):")
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
///
/// Uses HighlightStyler for all index calculations with proper Unicode scalar handling.
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
                // Use HighlightStyler for correct Unicode scalar handling
                let (prefix, match, suffix) = HighlightStyler.splitText(text, highlight: firstHighlight)
                let suffixStartScalarIndex = Int(firstHighlight.end)

                // 1. PREFIX: Truncates on the left ("...text")
                if !prefix.isEmpty {
                    Text(prefix)
                        .font(font)
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                // 2. HIGHLIGHT: High priority ensures it claims space first
                highlightedMatchView(match: match, kind: firstHighlight.kind)

                // 3. SUFFIX: Truncates on the right ("text...")
                // Apply any additional highlights that fall within suffix
                if !suffix.isEmpty {
                    suffixView(suffix: suffix, suffixStartScalarIndex: suffixStartScalarIndex)
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

    /// Build the highlighted match view with optional underline
    @ViewBuilder
    private func highlightedMatchView(match: String, kind: HighlightKind) -> some View {
        let baseView = Text(match)
            .font(font)
            .foregroundColor(textColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
            .background(HighlightStyler.color(for: kind))

        if HighlightStyler.usesUnderline(kind) {
            baseView.underline()
        } else {
            baseView
        }
    }

    /// Build suffix view with any additional highlights
    @ViewBuilder
    private func suffixView(suffix: String, suffixStartScalarIndex: Int) -> some View {
        // Check for additional highlights in the suffix (beyond the first one)
        // Use Unicode scalar count for correct bounds checking
        let suffixScalarCount = suffix.unicodeScalars.count
        let additionalHighlights = highlights.dropFirst().filter { h in
            HighlightStyler.highlightInSuffix(h, suffixStartScalarIndex: suffixStartScalarIndex, suffixScalarCount: suffixScalarCount)
        }

        if additionalHighlights.isEmpty {
            Text(suffix)
        } else {
            // Use HighlightStyler for correct Unicode scalar handling
            Text(HighlightStyler.attributedSuffix(suffix, suffixStartScalarIndex: suffixStartScalarIndex, highlights: Array(additionalHighlights)))
        }
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
private func selectionBackground() -> some View {
    Color.accentColor
        .opacity(0.9)
        .saturation(0.78)
        .brightness(-0.06)
}

// MARK: - Highlight Kind Color Mapping

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
