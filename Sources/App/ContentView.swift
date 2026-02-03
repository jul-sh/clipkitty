import SwiftUI
import AppKit
import ClipKittyRust
import os.log
import UniformTypeIdentifiers

private let perfLog = OSLog(subsystem: "com.clipkitty.app", category: "UI")

private func measure<T>(_ label: String, _ block: () -> T) -> T {
    let start = CFAbsoluteTimeGetCurrent()
    let result = block()
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
    os_log(.default, log: perfLog, "%{public}s: %.2fms", label, elapsed)
    return result
}

struct ContentView: View {
    var store: ClipboardStore
    let onSelect: (Int64, ClipboardContent) -> Void
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
    @FocusState private var isSearchFocused: Bool

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

    /// Get highlights for the selected item from results
    /// Returns empty array for empty query or if item not found
    private var selectedItemHighlights: [HighlightRange] {
        guard let selectedItemId else { return [] }
        switch store.state {
        case .results(_, let items, _), .resultsLoading(_, let items):
            return items.first { $0.itemMetadata.itemId == selectedItemId }?
                .matchData.fullContentHighlights ?? []
        case .loading, .error:
            return []
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
                selectedItemId = firstId
                // Use first item from state if available (avoids extra fetch)
                if let firstItem = stateFirstItem, firstItem.itemMetadata.itemId == firstId {
                    selectedItem = firstItem
                } else {
                    // Fallback: fetch the item - onChange won't fire for initial value
                    Task {
                        selectedItem = await store.fetchItem(id: firstId)
                    }
                }
            }
            // Initialize items signature for animation tracking
            lastItemsSignature = itemIds
            focusSearchField()
        }
        .onChange(of: store.displayVersion) { _, _ in
            // Reset local state when store signals a display reset
            // But preserve initial search if it was just applied
            if didApplyInitialSearch && !initialSearchQuery.isEmpty {
                didApplyInitialSearch = false // Allow reset next time
            } else {
                searchText = ""
            }
            // Select first item whenever display resets (re-open)
            let firstId = firstItemId
            selectedItemId = firstId
            // Use first item from state if available (avoids extra fetch)
            if let firstId, let firstItem = stateFirstItem, firstItem.itemMetadata.itemId == firstId {
                selectedItem = firstItem
            } else {
                selectedItem = nil
                // Fallback: fetch the first item
                if let firstId {
                    Task {
                        selectedItem = await store.fetchItem(id: firstId)
                    }
                }
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
                searchSpinnerTask = Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                    if case .resultsLoading = store.state {
                        showSearchSpinner = true
                    }
                }
            } else {
                showSearchSpinner = false
            }
        }
        .onChange(of: searchText) { _, newValue in
            store.setSearchQuery(newValue)
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
            // Show preview spinner after 100ms if item is still loading
            previewSpinnerTask?.cancel()
            if newItem == nil && selectedItemId != nil {
                previewSpinnerTask = Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                    // Only show if item is still loading
                    if selectedItem == nil && selectedItemId != nil {
                        showPreviewSpinner = true
                    }
                }
            } else {
                showPreviewSpinner = false
            }
        }
        .onChange(of: itemIds) { oldOrder, newOrder in
            // Select first item by default if nothing is selected
            guard let selectedItemId else {
                self.selectedItemId = firstItemId
                return
            }
            // Reset selection to first if the selected item's position changed
            // This ensures search results always start from the first match
            let oldIndex = oldOrder.firstIndex(of: selectedItemId)
            let newIndex = newOrder.firstIndex(of: selectedItemId)
            if oldIndex != newIndex {
                self.selectedItemId = firstItemId
                self.selectedItem = nil
            }
        }
    }

    // MARK: - Selection Management

    private func focusSearchField() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(10))
            isSearchFocused = true
        }
    }

    private func moveSelection(by offset: Int) {
        measure("moveSelection") {
            guard let currentIndex = selectedIndex else {
                selectedItemId = firstItemId
                return
            }
            let newIndex = max(0, min(itemCount - 1, currentIndex + offset))
            selectedItemId = itemId(at: newIndex)
        }
    }

    private func confirmSelection() {
        guard let item = selectedItem else { return }
        onSelect(item.itemMetadata.itemId, item.content)
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
                .focused($isSearchFocused)
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
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
                .onKeyPress(characters: .decimalDigits, phases: .down) { keyPress in
                    handleNumberKey(keyPress)
                }

            if showSearchSpinner {
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
                        onTap: {
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
                // Content - wrapped in NonDraggableView to allow text selection
                Group {
                    switch item.content {
                    case .text, .color, .email, .phone:
                        // Use AppKit text view - SwiftUI Text with AttributedString is slow
                        TextPreviewView(
                            text: item.contentPreview,
                            fontName: FontManager.mono,
                            fontSize: 15,
                            highlights: selectedItemHighlights
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    default:
                        ScrollView(.vertical, showsIndicators: true) {
                            switch item.content {
                            case .image(let data, let description):
                                if let nsImage = NSImage(data: Data(data)) {
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

                            case .link(let url, let metadataState):
                                // Link preview - fetch metadata on-demand if pending
                                linkPreview(url: url, metadataState: metadataState, itemId: item.itemMetadata.itemId)

                            case .text, .color, .email, .phone:
                                EmptyView()
                            }
                        }
                    }
                }

                Divider()

                // Metadata footer
                HStack(spacing: 12) {
                    Label(item.timeAgo, systemImage: "clock")
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
                        }
                    }
                    Spacer()
                    Button(buttonLabel) {
                        confirmSelection()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 17)
                .padding(.vertical, 11)
                .background(.black.opacity(0.05))
            } else if itemIds.isEmpty {
                emptyStateView
            } else if showPreviewSpinner {
                // Item is selected but still loading (after 100ms debounce)
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedItemId != nil {
                // Item is selected but loading hasn't taken long enough to show spinner
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

    private var buttonLabel: String {
        AppSettings.shared.shouldShowPasteLabel ? "⏎ paste" : "⏎ copy"
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "clipboard")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(store.currentQuery.isEmpty ? "No clipboard history" : "No results")
                .font(.custom(FontManager.sansSerif, size: 15))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - Text Preview (AppKit)

struct TextPreviewView: NSViewRepresentable {
    let text: String
    let fontName: String
    let fontSize: CGFloat
    var highlights: [HighlightRange] = []

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

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        // Only update if text or highlights changed
        let currentText = textView.string
        if currentText != text || context.coordinator.lastHighlights != highlights {
            context.coordinator.lastHighlights = highlights

            if highlights.isEmpty {
                // Clear any previous highlighting by setting plain string
                textView.string = text
                textView.font = font
                textView.textColor = .labelColor
                // Remove any lingering background colors from previous search
                if let textStorage = textView.textStorage, textStorage.length > 0 {
                    textStorage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: textStorage.length))
                }
            } else {
                // Apply Rust-computed highlights
                let attributed = NSMutableAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor
                ])
                let highlightColor = NSColor.yellow.withAlphaComponent(0.4)
                for range in highlights {
                    let nsRange = range.nsRange
                    if nsRange.location + nsRange.length <= attributed.length {
                        attributed.addAttribute(.backgroundColor, value: highlightColor, range: nsRange)
                    }
                }
                textView.textStorage?.setAttributedString(attributed)
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
        // Start with a minimal placeholder metadata
        if let urlObj = URL(string: url) {
            let metadata = LPLinkMetadata()
            metadata.originalURL = urlObj
            metadata.url = urlObj
            linkView.metadata = metadata
        }
        return linkView
    }

    func updateNSView(_ linkView: LPLinkView, context: Context) {
        guard let urlObj = URL(string: url) else { return }

        // Build metadata from our state
        let metadata = LPLinkMetadata()
        metadata.originalURL = urlObj
        metadata.url = urlObj

        switch metadataState {
        case .loaded(let title, _, let imageData):
            if let title {
                metadata.title = title
            }
            if let imageData, let nsImage = NSImage(data: imageData) {
                metadata.imageProvider = NSItemProvider(object: nsImage)
            }
        case .pending, .failed:
            // Just show URL for pending/failed states
            break
        }

        // Only update if metadata actually changed
        if context.coordinator.lastURL != url ||
           context.coordinator.lastMetadataState != metadataState {
            context.coordinator.lastURL = url
            context.coordinator.lastMetadataState = metadataState
            linkView.metadata = metadata
        }
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
    let onTap: () -> Void

    // Fixed height for exactly 1 line of text at font size 15
    private let rowHeight: CGFloat = 32

    // MARK: - Display Text (Unified Logic)

    private let maxDisplayChars = 200
    private let maxRustSnippet = 400  // Rust's SNIPPET_CONTEXT_CHARS * 2

    /// Computed prefix - shows line number and/or ellipsis if snippet doesn't start at beginning
    private var snippetPrefix: (prefix: String, offset: Int) {
        guard let matchData else { return ("", 0) }

        let line = matchData.lineNumber
        // lineNumber == 0 means no highlights (browsing), lineNumber >= 1 means search match
        guard line >= 1 else { return ("", 0) }

        // Check if snippet starts at content beginning (first highlight near start)
        let matchStart = matchData.fullContentHighlights.first?.start ?? 0
        if matchStart < 20 && line == 1 {
            return ("", 0)  // Near start of first line - no prefix needed
        }

        // Build prefix: line number if not on first line, otherwise just ellipsis
        let prefix = line > 1 ? "L\(line): …" : "…"
        return (prefix, prefix.count)
    }

    /// Display text with prefix/suffix ellipsis as needed
    private var displaySnippet: String {
        // Use matchData.text if present, otherwise metadata.snippet
        let sourceText = matchData?.text.isEmpty == false ? matchData!.text : metadata.snippet
        let (prefix, _) = snippetPrefix

        // Available space for content
        let availableChars = maxDisplayChars - prefix.count

        // Truncate if needed, add trailing ellipsis
        if sourceText.count > availableChars {
            return prefix + String(sourceText.prefix(availableChars)) + "…"
        }

        // Add trailing ellipsis if source was already truncated by Rust
        let needsTrailingEllipsis = sourceText.count >= maxRustSnippet
        return prefix + sourceText + (needsTrailingEllipsis ? "…" : "")
    }

    /// Highlights for display - adjusted for prefix offset
    private var displayHighlights: [HighlightRange] {
        guard let matchData, !matchData.highlights.isEmpty else { return [] }

        let (_, prefixOffset) = snippetPrefix
        let offset = UInt64(prefixOffset)

        // Adjust highlights for prefix
        return matchData.highlights.map {
            HighlightRange(start: $0.start + offset, end: $0.end + offset)
        }
    }

    // Define exactly what constitutes a "change" for SwiftUI diffing
    // Note: onTap closure is intentionally excluded from equality comparison
    nonisolated static func == (lhs: ItemRow, rhs: ItemRow) -> Bool {
        return lhs.isSelected == rhs.isSelected &&
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
                        let color = colorFromRGBA(rgba)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: color))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                            )
                    case .symbol(let iconType):
                        if case .link = iconType,
                           let browserURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://")!) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: browserURL.path))
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
                    // Skip badge for symbol links (browser icon is already shown)
                    let showBadge: Bool = {
                        switch metadata.icon {
                        case .symbol(let iconType):
                            return iconType != .link
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

            // Text content - use AppKit for fast highlighting
            HighlightedTextView(
                text: displaySnippet,
                highlights: displayHighlights,
                isSelected: isSelected
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            .layoutPriority(1)


        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background {
            if isSelected {
                Color.accentColor
                    .opacity(0.9)
                    .saturation(0.9)
                    .brightness(-0.06)
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
        .accessibilityLabel(displaySnippet)
        #if SANDBOXED
        .accessibilityHint("Double tap to copy")
        #else
        .accessibilityHint("Double tap to paste")
        #endif
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func colorFromRGBA(_ rgba: UInt32) -> NSColor {
        let r = CGFloat((rgba >> 24) & 0xFF) / 255.0
        let g = CGFloat((rgba >> 16) & 0xFF) / 255.0
        let b = CGFloat((rgba >> 8) & 0xFF) / 255.0
        let a = CGFloat(rgba & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - AppKit Highlighted Text (Fast)

/// AppKit-based text view for fast search highlighting
/// NSTextField is much faster than SwiftUI Text with AttributedString
struct HighlightedTextView: NSViewRepresentable {
    let text: String
    let highlights: [HighlightRange]
    let isSelected: Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        // Allow field to expand to fill available width
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // Skip update if nothing changed (prevents flash on re-render)
        let coord = context.coordinator
        guard text != coord.lastText || highlights != coord.lastHighlights || isSelected != coord.lastIsSelected else {
            return
        }
        coord.lastText = text
        coord.lastHighlights = highlights
        coord.lastIsSelected = isSelected

        let font = NSFont(name: FontManager.sansSerif, size: 15) ?? NSFont.systemFont(ofSize: 15)
        let textColor: NSColor = isSelected ? .white : .labelColor

        // Always use attributed string for consistent rendering between browse and search modes
        let mutable = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: textColor
        ])

        // Apply highlights if present
        if !highlights.isEmpty {
            let highlightColor = NSColor.yellow.withAlphaComponent(0.4)
            for range in highlights {
                let nsRange = range.nsRange
                if nsRange.location + nsRange.length <= mutable.length {
                    mutable.addAttribute(.backgroundColor, value: highlightColor, range: nsRange)
                }
            }
        }

        field.attributedStringValue = mutable
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var lastText: String = ""
        var lastHighlights: [HighlightRange] = []
        var lastIsSelected: Bool = false
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
