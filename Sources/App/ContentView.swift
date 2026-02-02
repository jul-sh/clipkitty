import SwiftUI
import AppKit
import ClipKittyRust
import ColorCode
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

/// Unified list item that can represent either browse mode (ItemMetadata) or search mode (ItemMatch)
struct ListItem: Equatable, Identifiable {
    let itemId: Int64
    let icon: ItemIcon
    let preview: String
    let sourceApp: String?
    let sourceAppBundleId: String?
    let timestampUnix: Int64
    let matchData: MatchData?  // Only present in search mode

    var id: Int64 { itemId }
    var stableId: String { String(itemId) }

    init(metadata: ItemMetadata) {
        self.itemId = metadata.itemId
        self.icon = metadata.icon
        self.preview = metadata.preview
        self.sourceApp = metadata.sourceApp
        self.sourceAppBundleId = metadata.sourceAppBundleId
        self.timestampUnix = metadata.timestampUnix
        self.matchData = nil
    }

    init(match: ItemMatch) {
        self.itemId = match.itemMetadata.itemId
        self.icon = match.itemMetadata.icon
        self.preview = match.itemMetadata.preview
        self.sourceApp = match.itemMetadata.sourceApp
        self.sourceAppBundleId = match.itemMetadata.sourceAppBundleId
        self.timestampUnix = match.itemMetadata.timestampUnix
        self.matchData = match.matchData
    }
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
    @State private var showSearchSpinner: Bool = false
    @State private var lastItemsSignature: [Int64] = []  // Track when items change to suppress animation
    @FocusState private var isSearchFocused: Bool

    private var listItems: [ListItem] {
        switch store.state {
        case .loaded(let items, _):
            return items.map { ListItem(metadata: $0) }
        case .searching(_, let searchState):
            switch searchState {
            case .loading(let previous):
                return previous.map { ListItem(match: $0) }
            case .results(let results, _):
                return results.map { ListItem(match: $0) }
            }
        default:
            return []
        }
    }

    private var selectedListItem: ListItem? {
        guard let selectedItemId else { return nil }
        return listItems.first { $0.itemId == selectedItemId }
    }

    private var selectedIndex: Int? {
        guard let selectedItemId else { return nil }
        return listItems.firstIndex { $0.itemId == selectedItemId }
    }

    /// The order signature of displayed items - changes when items are reordered
    private var itemsOrderSignature: [Int64] {
        listItems.map { $0.itemId }
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
            if selectedItemId == nil {
                selectedItemId = listItems.first?.itemId
            }
            // Initialize items signature for animation tracking
            lastItemsSignature = listItems.map { $0.itemId }
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
            selectedItemId = listItems.first?.itemId
            selectedItem = nil
            focusSearchField()
        }
        .onChange(of: store.state) { _, newState in
            // Validate selection - ensure selected item still exists in results
            if let selectedItemId, !listItems.contains(where: { $0.itemId == selectedItemId }) {
                self.selectedItemId = listItems.first?.itemId
                self.selectedItem = nil
            }

            // Show spinner only after 200ms delay to avoid flicker on fast searches
            let isLoading: Bool = {
                if case .searching(_, let searchState) = newState {
                    switch searchState {
                    case .loading:
                        return true
                    case .results:
                        return false
                    }
                }
                return false
            }()

            if isLoading {
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    // Only show if still loading
                    if case .searching(_, let searchState) = store.state {
                        switch searchState {
                        case .loading:
                            showSearchSpinner = true
                        case .results:
                            break
                        }
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
                let query = searchText.isEmpty ? nil : searchText
                selectedItem = await store.fetchItem(id: newId, searchQuery: query)
            }
        }
        .onChange(of: itemsOrderSignature) { oldOrder, newOrder in
            // Select first item by default if nothing is selected
            guard let selectedItemId else {
                self.selectedItemId = listItems.first?.itemId
                return
            }
            // Reset selection to first if the selected item's position changed
            let oldIndex = oldOrder.firstIndex(of: selectedItemId)
            let newIndex = newOrder.firstIndex(of: selectedItemId)
            if oldIndex != newIndex {
                self.selectedItemId = listItems.first?.itemId
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
                selectedItemId = listItems.first?.itemId
                return
            }
            let newIndex = max(0, min(listItems.count - 1, currentIndex + offset))
            selectedItemId = listItems[newIndex].itemId
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
        guard index < listItems.count else { return .ignored }

        selectedItemId = listItems[index].itemId
        confirmSelection()
        return .handled
    }

    private func indexForItem(_ itemId: Int64?) -> Int? {
        guard let itemId else { return nil }
        return listItems.firstIndex { $0.itemId == itemId }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            loadingView
        case .error(let message):
            errorView(message)
        case .loaded, .searching:
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

    private var itemList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(listItems.enumerated()), id: \.element.itemId) { index, listItem in
                    ItemRow(
                        listItem: listItem,
                        isSelected: listItem.itemId == selectedItemId,
                        searchQuery: searchText,
                        onTap: {
                            selectedItemId = listItem.itemId
                            focusSearchField()
                        }
                    )
                    .equatable()
                    .accessibilityIdentifier("ItemRow_\(index)")
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .onAppear {
                        if index == listItems.count - 10 {
                            store.loadMoreItems()
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .animation(nil, value: listItems.map { $0.itemId })
            .modifier(HideScrollIndicatorsWhenOverlay())
            .onChange(of: searchText) { _, _ in
                // Scroll to top when search query changes (no animation)
                if let firstItemId = listItems.first?.itemId {
                    proxy.scrollTo(firstItemId, anchor: .top)
                }
            }
            .onChange(of: selectedItemId) { oldItemId, newItemId in
                guard let newItemId else { return }

                let currentSignature = listItems.map { $0.itemId }
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
                    case .text, .color, .email, .phone, .address, .date, .transit:
                        // Use AppKit text view - SwiftUI Text with AttributedString is slow
                        TextPreviewView(
                            text: item.contentPreview,
                            fontName: FontManager.mono,
                            fontSize: 15,
                            highlights: item.previewHighlights
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
                                // Link preview - fetch metadata on-demand if needed
                                linkPreview(url: url, metadataState: metadataState)
                                    .task(id: item.stableId) {
                                        store.fetchLinkMetadataIfNeeded(for: item)
                                    }

                            case .text, .color, .email, .phone, .address, .date, .transit:
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
            } else if listItems.isEmpty {
                emptyStateView
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
            let emptyStateMessage: String = {
                switch store.state {
                case .searching(let query, _) where !query.isEmpty:
                    return "No results"
                default:
                    return "No clipboard history"
                }
            }()

            Text(emptyStateMessage)
                .font(.custom(FontManager.sansSerif, size: 15))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func linkPreview(url: String, metadataState: LinkMetadataState) -> some View {
        VStack(spacing: 16) {
            // OG Image if available
            if let imageData = metadataState.imageData,
               let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                // Placeholder based on metadata state
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 120)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "link")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            switch metadataState {
                            case .pending:
                                Text("Loading preview…")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            case .failed:
                                Text("Preview unavailable")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            case .loaded:
                                EmptyView()
                            }
                        }
                    }
            }

            // Title and URL
            VStack(alignment: .leading, spacing: 8) {
                if let title = metadataState.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                Text(url)
                    .font(.custom(FontManager.mono, size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(16)
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

// MARK: - Item Row

struct ItemRow: View, Equatable {
    let listItem: ListItem
    let isSelected: Bool
    let searchQuery: String
    let onTap: () -> Void

    // Fixed height for exactly 1 line of text at font size 15
    private let rowHeight: CGFloat = 32

    /// Display text - uses Rust-computed match text with line number if available
    private var displayText: String {
        // In search mode, use the match text with line number prefix
        if let matchData = listItem.matchData {
            if matchData.lineNumber > 1 {
                return "L\(matchData.lineNumber): \(matchData.text)"
            }
            return matchData.text
        }
        // In browse mode, just use the preview
        return listItem.preview
    }

    /// Highlights for display - from Rust-computed match data
    private var displayHighlights: [HighlightRange] {
        guard let matchData = listItem.matchData else { return [] }
        // Adjust for line number prefix if present
        if matchData.lineNumber > 1 {
            let prefix = "L\(matchData.lineNumber): "
            let offset = UInt64(prefix.count)
            return matchData.highlights.map {
                HighlightRange(start: $0.start + offset, end: $0.end + offset)
            }
        }
        return matchData.highlights
    }

    // Define exactly what constitutes a "change" for SwiftUI diffing
    // Note: onTap closure is intentionally excluded from equality comparison
    nonisolated static func == (lhs: ItemRow, rhs: ItemRow) -> Bool {
        return lhs.isSelected == rhs.isSelected &&
               lhs.listItem == rhs.listItem &&
               lhs.searchQuery == rhs.searchQuery
    }

    var body: some View {
        // 1. Wrap the content inside a Button
        Button(action: onTap) {
            HStack(spacing: 6) {
            // Content type icon with source app badge overlay
            ZStack(alignment: .bottomTrailing) {
                // Main icon: image thumbnail, browser icon for links, color swatch, or SF symbol
                Group {
                    switch listItem.icon {
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

                // Badge: Source app icon (skip for links since browser icon is already shown)
                if case .symbol(let iconType) = listItem.icon, iconType != .link,
                   let bundleID = listItem.sourceAppBundleId,
                   let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable()
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                        .offset(x: 4, y: 4)
                }
            }
            .frame(width: 38, height: 38)
            .allowsHitTesting(false)

            // Text content - use AppKit for fast highlighting
            HighlightedTextView(
                text: displayText,
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
        .accessibilityLabel(displayText)
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
        let font = NSFont(name: FontManager.sansSerif, size: 15) ?? NSFont.systemFont(ofSize: 15)
        let textColor: NSColor = isSelected ? .white : .labelColor

        if highlights.isEmpty {
            field.stringValue = text
            field.font = font
            field.textColor = textColor
        } else {
            // Apply Rust-computed highlights
            let mutable = NSMutableAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: textColor
            ])
            let highlightColor = NSColor.yellow.withAlphaComponent(0.4)
            for range in highlights {
                let nsRange = range.nsRange
                if nsRange.location + nsRange.length <= mutable.length {
                    mutable.addAttribute(.backgroundColor, value: highlightColor, range: nsRange)
                }
            }
            field.attributedStringValue = mutable
        }
    }
}

// MARK: - Hide Scroll Indicators When System Uses Overlay Style

/// Hides scroll indicators when the system preference is "Show scroll bars: When scrolling" (overlay style).
/// Detects scrolling via ScrollView geometry and shows indicators only while actively scrolling.
/// This prevents the brief scrollbar flash when the panel appears.
private struct HideScrollIndicatorsWhenOverlay: ViewModifier {
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
        } else {
            content
        }
    }
}
