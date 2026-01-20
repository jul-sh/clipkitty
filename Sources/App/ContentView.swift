import SwiftUI
import AppKit
import ClipKittyCore
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
    let onSelect: (ClipboardItem) -> Void
    let onDismiss: () -> Void
    var initialSearchQuery: String = ""

    @State private var selectedItemId: String?
    @State private var searchText: String = ""
    @State private var didApplyInitialSearch = false
    @State private var showSearchSpinner: Bool = false
    @FocusState private var isSearchFocused: Bool
    private var items: [ClipboardItem] {
        measure("items.get") {
            switch store.state {
            case .loaded(let items, _):
                return items
            case .searching(_, let searchState):
                switch searchState {
                case .loading(let previous):
                    return previous
                case .loadingMore(let results):
                    return results
                case .results(let results, _):
                    return results
                }
            default:
                return []
            }
        }
    }

    private var selectedItem: ClipboardItem? {
        measure("selectedItem.get") {
            guard let selectedItemId else { return nil }
            return items.first { $0.stableId == selectedItemId }
        }
    }

    private var selectedIndex: Int? {
        guard let selectedItemId else { return nil }
        return items.firstIndex { $0.stableId == selectedItemId }
    }

    /// The order signature of displayed items - changes when items are reordered
    private var itemsOrderSignature: [String] {
        items.map { $0.stableId }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            GeometryReader { _ in
                content
            }
            .clipped()
        }
        // Hidden element for UI testing - exposes selected index
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SelectedIndex_\(selectedIndex ?? -1)")
        // 1. Force the VStack to fill the entire available space
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        // 2. Apply the glass effect/background so it fills that infinite frame
        .clipKittyGlassBackground()

        // 3. Finally, ignore the safe area to push the background into the title bar
        .ignoresSafeArea(.all)

        .onAppear {
            // Apply initial search query if provided (for CI screenshots)
            if !initialSearchQuery.isEmpty && !didApplyInitialSearch {
                searchText = initialSearchQuery
                didApplyInitialSearch = true
            } else {
                searchText = ""
            }
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
            selectedItemId = nil
            focusSearchField()
        }
        .onChange(of: store.state) { _, newState in
            // Validate selection - ensure selected item still exists in results
            if let selectedItemId, !items.contains(where: { $0.stableId == selectedItemId }) {
                self.selectedItemId = items.first?.stableId
            }

            // Show spinner only after 200ms delay to avoid flicker on fast searches
            let isLoading: Bool = {
                if case .searching(_, let searchState) = newState {
                    switch searchState {
                    case .loading, .loadingMore:
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
                        case .loading, .loadingMore:
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
        .onChange(of: itemsOrderSignature) { oldOrder, newOrder in
            // Select first item by default if nothing is selected
            guard let selectedItemId else {
                self.selectedItemId = items.first?.stableId
                return
            }
            // Reset selection to first if the selected item's position changed
            let oldIndex = oldOrder.firstIndex(of: selectedItemId)
            let newIndex = newOrder.firstIndex(of: selectedItemId)
            if oldIndex != newIndex {
                self.selectedItemId = items.first?.stableId
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
                selectedItemId = items.first?.stableId
                return
            }
            let newIndex = max(0, min(items.count - 1, currentIndex + offset))
            selectedItemId = items[newIndex].stableId
        }
    }

    private func confirmSelection() {
        guard let item = selectedItem else { return }
        onSelect(item)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.custom(FontManager.sansSerif, size: 17).weight(.medium))

            TextField("Search clipboard history", text: $searchText)
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
        guard index < items.count else { return .ignored }

        selectedItemId = items[index].stableId
        confirmSelection()
        return .handled
    }

    private func indexForItem(_ itemId: String?) -> Int? {
        guard let itemId else { return nil }
        return items.firstIndex { $0.stableId == itemId }
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
                ForEach(Array(items.enumerated()), id: \.element.stableId) { index, item in
                    ItemRow(
                        item: item,
                        isSelected: item.stableId == selectedItemId,
                        searchQuery: searchText,
                        onTap: {
                            selectedItemId = item.stableId
                            focusSearchField()
                        }
                    )
                    .equatable()
                    .accessibilityIdentifier("ItemRow_\(index)")
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .onAppear {
                        if index == items.count - 10 {
                            store.loadMoreItems()
                            store.loadMoreSearchResults()
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: searchText) { _, _ in
                // Scroll to top when search query changes
                if let firstItemId = items.first?.stableId {
                    proxy.scrollTo(firstItemId, anchor: .top)
                }
            }
            .onChange(of: selectedItemId) { oldItemId, newItemId in
                guard let newItemId else { return }
                let oldIndex = indexForItem(oldItemId)
                let newIndex = indexForItem(newItemId)
                let shouldAnimate = {
                    guard let oldIndex, let newIndex else { return true }
                    return abs(newIndex - oldIndex) > 1
                }()

                if shouldAnimate {
                    withAnimation(.easeInOut(duration: 0.2)) {
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
                    case .text, .email, .phone, .address, .date, .transit:
                        // Use AppKit text view - SwiftUI Text with AttributedString is slow
                        TextPreviewView(
                            text: item.contentPreview,
                            fontName: FontManager.mono,
                            fontSize: 15,
                            searchQuery: searchText
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    default:
                        ScrollView(.vertical, showsIndicators: true) {
                            switch item.content {
                            case .image(let data, let description):
                                if let nsImage = NSImage(data: data) {
                                    VStack(spacing: 8) {
                                        Image(nsImage: nsImage)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(maxWidth: .infinity)
                                        Text(imageDescriptionAttributed(description))
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(16)
                                }

                            case .link(let url, let metadataState):
                                // Link preview - fetch metadata on-demand if needed
                                linkPreview(url: url, metadataState: metadataState)
                                    .task(id: item.stableId) {
                                        store.fetchLinkMetadataIfNeeded(for: item)
                                    }

                            case .text, .email, .phone, .address, .date, .transit:
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
                    Button(AppSettings.shared.pasteOnSelect ? "⏎ paste" : "⏎ copy") {
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
            } else if items.isEmpty {
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

    private func formatSize(_ chars: Int) -> String {
        if chars >= 1_000_000 {
            return String(format: "%.1fM", Double(chars) / 1_000_000)
        } else if chars >= 1000 {
            return String(format: "%.1fK", Double(chars) / 1000)
        }
        return "\(chars)"
    }

    private func imageDescriptionAttributed(_ text: String) -> AttributedString {
        guard !searchText.isEmpty else {
            return AttributedString(text)
        }
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let attributed = text.highlightedNSAttributedString(
            query: searchText,
            font: font,
            textColor: NSColor.secondaryLabelColor
        )
        return AttributedString(attributed)
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
    var searchQuery: String = ""

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

        // Only update if text or query changed
        let currentText = textView.string
        if currentText != text || context.coordinator.lastQuery != searchQuery {
            context.coordinator.lastQuery = searchQuery

            if searchQuery.isEmpty {
                // Clear any previous highlighting by setting plain string
                textView.string = text
                textView.font = font
                textView.textColor = .labelColor
                // Remove any lingering background colors from previous search
                if let textStorage = textView.textStorage, textStorage.length > 0 {
                    textStorage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: textStorage.length))
                }
            } else {
                let attributed = text.highlightedNSAttributedString(
                    query: searchQuery,
                    font: font,
                    textColor: .labelColor
                )
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
        var lastQuery: String = ""
    }
}

// MARK: - Item Row

struct ItemRow: View, Equatable {
    let item: ClipboardItem
    let isSelected: Bool
    let searchQuery: String
    let onTap: () -> Void

    // Fixed height for exactly 1 line of text at font size 15
    private let rowHeight: CGFloat = 32

    private var previewText: String {
        let displayText = item.displayText
        guard !searchQuery.isEmpty else { return displayText }

        // Search in full content (flattened) to find match position,
        // since displayText is truncated to 200 chars and may not contain the match
        let fullText = item.textContent

        // Helper to flatten text (replace newlines/tabs with spaces, collapse consecutive spaces)
        func flatten(_ text: String, maxChars: Int) -> String {
            var result = String()
            result.reserveCapacity(min(maxChars + 1, text.count))
            var lastWasSpace = false
            var count = 0
            for char in text {
                guard count < maxChars else { break }
                var c = char
                if c == "\n" || c == "\t" || c == "\r" { c = " " }
                if c == " " {
                    if lastWasSpace { continue }
                    lastWasSpace = true
                } else {
                    lastWasSpace = false
                }
                result.append(c)
                count += 1
            }
            return result
        }

        // Try exact match first
        if let range = fullText.range(of: searchQuery, options: .caseInsensitive) {
            let matchStart = fullText.distance(from: fullText.startIndex, to: range.lowerBound)
            // If match is early in the text, just return displayText (already flattened/truncated)
            if matchStart < 20 {
                return displayText
            }
            // Extract context around the match and flatten it
            let contextStart = max(0, matchStart - 10)
            let contextEnd = min(fullText.count, matchStart + 200)
            let startIndex = fullText.index(fullText.startIndex, offsetBy: contextStart)
            let endIndex = fullText.index(fullText.startIndex, offsetBy: contextEnd)
            let context = String(fullText[startIndex..<endIndex])
            return "…" + flatten(context, maxChars: 200)
        }

        // Fall back to first trigram match
        if searchQuery.count >= 3 {
            let chars = Array(searchQuery.lowercased())
            for i in 0..<(chars.count - 2) {
                let trigram = String(chars[i..<i+3])
                if let range = fullText.range(of: trigram, options: .caseInsensitive) {
                    let matchStart = fullText.distance(from: fullText.startIndex, to: range.lowerBound)
                    if matchStart < 20 {
                        return displayText
                    }
                    let contextStart = max(0, matchStart - 10)
                    let contextEnd = min(fullText.count, matchStart + 200)
                    let startIndex = fullText.index(fullText.startIndex, offsetBy: contextStart)
                    let endIndex = fullText.index(fullText.startIndex, offsetBy: contextEnd)
                    let context = String(fullText[startIndex..<endIndex])
                    return "…" + flatten(context, maxChars: 200)
                }
            }
        }

        return displayText
    }

    // Define exactly what constitutes a "change" for SwiftUI diffing
    // Note: onTap closure is intentionally excluded from equality comparison
    nonisolated static func == (lhs: ItemRow, rhs: ItemRow) -> Bool {
        return lhs.isSelected == rhs.isSelected &&
               lhs.item.stableId == rhs.item.stableId &&
               lhs.searchQuery == rhs.searchQuery
    }

    var body: some View {
        HStack(spacing: 6) {
            // Content type icon with source app badge overlay
            ZStack(alignment: .bottomTrailing) {
                // Main icon: image thumbnail, browser icon for links, or UTType system icon
                Group {
                    if case .image(let data, _) = item.content,
                       let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if case .link = item.content,
                              let browserURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://")!) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: browserURL.path))
                            .resizable()
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(for: item.content.utType))
                            .resizable()
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                // Badge: Source app icon (skip for links since browser icon is already shown)
                if case .link = item.content {} else if let bundleID = item.sourceAppBundleID,
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
                text: previewText,
                query: searchQuery,
                isSelected: isSelected
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
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
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(previewText)
        .accessibilityHint("Double tap to paste")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - AppKit Highlighted Text (Fast)

/// AppKit-based text view for fast search highlighting
/// NSTextField is much faster than SwiftUI Text with AttributedString
struct HighlightedTextView: NSViewRepresentable {
    let text: String
    let query: String
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

        if query.isEmpty {
            field.stringValue = text
            field.font = font
            field.textColor = textColor
        } else {
            // Build attributed string that matches NSTextField's default rendering
            field.stringValue = text
            field.font = font
            field.textColor = textColor

            // Now get the field's attributed string and add highlights to it
            let mutable = field.attributedStringValue.mutableCopy() as! NSMutableAttributedString
            let nsString = text as NSString
            let highlightColor = NSColor.yellow.withAlphaComponent(0.4)
            var highlightedRanges = Set<NSRange>()
            var matchCount = 0

            // Try exact match first
            var searchRange = NSRange(location: 0, length: nsString.length)
            while matchCount < 50, searchRange.location < nsString.length {
                let foundRange = nsString.range(of: query, options: .caseInsensitive, range: searchRange)
                guard foundRange.location != NSNotFound else { break }
                mutable.addAttribute(.backgroundColor, value: highlightColor, range: foundRange)
                highlightedRanges.insert(foundRange)
                searchRange.location = foundRange.location + foundRange.length
                searchRange.length = nsString.length - searchRange.location
                matchCount += 1
            }

            // If no exact matches, use trigram highlighting
            if highlightedRanges.isEmpty && query.count >= 3 {
                let queryLower = query.lowercased()
                let chars = Array(queryLower)
                for i in 0..<(chars.count - 2) {
                    let trigram = String(chars[i..<i+3])
                    searchRange = NSRange(location: 0, length: nsString.length)
                    while matchCount < 50, searchRange.location < nsString.length {
                        let foundRange = nsString.range(of: trigram, options: .caseInsensitive, range: searchRange)
                        guard foundRange.location != NSNotFound else { break }
                        let alreadyHighlighted = highlightedRanges.contains { NSIntersectionRange($0, foundRange).length > 0 }
                        if !alreadyHighlighted {
                            mutable.addAttribute(.backgroundColor, value: highlightColor, range: foundRange)
                            highlightedRanges.insert(foundRange)
                            matchCount += 1
                        }
                        searchRange.location = foundRange.location + foundRange.length
                        searchRange.length = nsString.length - searchRange.location
                    }
                }
            }

            field.attributedStringValue = mutable
        }
    }
}
