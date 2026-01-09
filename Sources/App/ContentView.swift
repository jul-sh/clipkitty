import SwiftUI
import AppKit
import ClipKittyCore

struct ContentView: View {
    private enum SelectionOrigin {
        case keyboard
        case mouse
        case programmatic
    }

    var store: ClipboardStore
    let onSelect: (ClipboardItem) -> Void
    let onDismiss: () -> Void

    @State private var selection: String?
    @State private var selectionOrigin: SelectionOrigin = .programmatic
    @State private var searchText: String = ""
    @State private var isCopyHovering: Bool = false
    @FocusState private var isSearchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var items: [ClipboardItem] {
        switch store.state {
        case .loaded(let items, _):
            return items
        case .searching(_, let searchState):
            switch searchState {
            case .loading(let previous):
                return previous
            case .results(let results):
                return results
            }
        default:
            return []
        }
    }

    private var selectedItem: ClipboardItem? {
        guard let selection else { return nil }
        return items.first { $0.stableId == selection }
    }

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return items.firstIndex { $0.stableId == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
        }
        // 1. Force the VStack to fill the entire available space
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        // 2. Apply the glass effect/background so it fills that infinite frame
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    (colorScheme == .dark ? Color.black : Color.white)
                        .opacity(0.18)
                )
        )
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 12))

        // 3. Finally, ignore the safe area to push the background into the title bar
        .ignoresSafeArea(.all)

        .onAppear {
            isSearchFocused = true
            searchText = ""
            selectFirstItem()
        }
        .onChange(of: store.state) { _, _ in
            validateSelection()
        }
        .onChange(of: searchText) { _, newValue in
            store.setSearchQuery(newValue)
        }
    }

    // MARK: - Selection Management

    private func selectFirstItem() {
        selectionOrigin = .programmatic
        selection = items.first?.stableId
    }

    private func validateSelection() {
        if selection == nil || !items.contains(where: { $0.stableId == selection }) {
            selectFirstItem()
        }
    }

    private func moveSelection(by offset: Int) {
        guard let currentIndex = selectedIndex else {
            selectFirstItem()
            return
        }
        let newIndex = max(0, min(items.count - 1, currentIndex + offset))
        selectionOrigin = .keyboard
        selection = items[newIndex].stableId
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

            TextField("Search clipboard...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.custom(FontManager.sansSerif, size: 17))
                .focused($isSearchFocused)
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

            if case .searching(_, .loading) = store.state {
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

        selectionOrigin = .keyboard
        selection = items[index].stableId
        confirmSelection()
        return .handled
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
            List(items, id: \.stableId) { item in
                let index = items.firstIndex { $0.stableId == item.stableId } ?? 0
                ItemRow(
                    item: item,
                    isSelected: item.stableId == selection,
                    searchQuery: searchText
                )
                .equatable()
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .onTapGesture {
                    selectionOrigin = .mouse
                    selection = item.stableId
                }
                .onAppear {
                    if index == items.count - 10 {
                        store.loadMoreItems()
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: selection) { _, newSelection in
                if let newSelection, selectionOrigin == .keyboard {
                    proxy.scrollTo(newSelection, anchor: .center)
                }
            }
        }
    }

    // MARK: - Preview Pane

    private var previewPane: some View {
        VStack(spacing: 0) {
            if let item = selectedItem {
                // Content - wrapped in NonDraggableView to allow text selection
                ScrollView(.vertical, showsIndicators: true) {
                    switch item.content {
                    case .image(let data, _):
                        if let nsImage = NSImage(data: data) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .padding(16)
                        }

                    case .link(let url, let metadataState):
                        // Link preview - fetch metadata on-demand if needed
                        linkPreview(url: url, metadataState: metadataState)
                            .task(id: item.stableId) {
                                store.fetchLinkMetadataIfNeeded(for: item)
                            }

                    case .text:
                        // Text preview
                        Text(highlightedPreview(for: item))
                            .font(.custom(FontManager.mono, size: 15))
                            .textSelection(.enabled)
                            .modifier(IBeamCursorOnHover())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
                .background(NonDraggableView())

                Divider()

                // Metadata footer
                HStack(spacing: 12) {
                    Label(item.timeAgo, systemImage: "clock")
                    if item.textContent.count > 100 {
                        Label(formatSize(item.textContent.count), systemImage: "doc.text")
                    }
                    if let app = item.sourceApp {
                        Label(app, systemImage: "app")
                    }
                    Spacer()
                    Button("⏎ copy") {
                        confirmSelection()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isCopyHovering ? .black.opacity(0.08) : .clear)
                    )
                    .onHover { hovering in
                        isCopyHovering = hovering
                    }
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
        .onHover { hovering in
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                window.isMovableByWindowBackground = !hovering
            }
        }
    }

    private func formatSize(_ chars: Int) -> String {
        if chars >= 1_000_000 {
            return String(format: "%.1fM", Double(chars) / 1_000_000)
        } else if chars >= 1000 {
            return String(format: "%.1fK", Double(chars) / 1000)
        }
        return "\(chars)"
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

    private func highlightedPreview(for item: ClipboardItem) -> AttributedString {
        // If the content is massive, don't try to highlight the whole thing on the main thread.
        // Cap it at ~2000 chars for the "fuzzy match" view.
        if item.contentPreview.count > 2000 {
            let prefix = String(item.contentPreview.prefix(2000))
            var attributed = prefix.fuzzyHighlighted(query: searchText)

            // Append a plain text suffix so the user knows there is more
            attributed += AttributedString("\n\n... (text truncated for preview)")
            return attributed
        }

        return item.contentPreview.fuzzyHighlighted(query: searchText)
    }

    @ViewBuilder
    private func linkPreview(url: String, metadataState: LinkMetadataState) -> some View {
        VStack(spacing: 16) {
            // OG Image if available
            if let imageData = metadataState.metadata?.imageData,
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
                                Text("Loading preview...")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            case .failed:
                                Text("Preview unavailable")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            case .loaded(let metadata) where metadata.imageData == nil:
                                EmptyView()
                            default:
                                EmptyView()
                            }
                        }
                    }
            }

            // Title and URL
            VStack(alignment: .leading, spacing: 8) {
                if let title = metadataState.metadata?.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .modifier(IBeamCursorOnHover())
                }

                Text(url)
                    .font(.custom(FontManager.mono, size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .modifier(IBeamCursorOnHover())
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(16)
    }
}

// MARK: - Non-Draggable View
// Prevents window dragging on the preview pane to allow text selection

struct NonDraggableView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NonDraggableNSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

class NonDraggableNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Return self to capture mouse events and prevent window dragging
        return self
    }
}

// MARK: - Hover Cursor

struct IBeamCursorOnHover: ViewModifier {
    func body(content: Content) -> some View {
        content.background(IBeamCursorView())
    }
}

struct IBeamCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        CursorTrackingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class CursorTrackingView: NSView {
    private var trackingArea: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate]
        let newArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(newArea)
        trackingArea = newArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.iBeam.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.iBeam.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.iBeam.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

// MARK: - Item Row

struct ItemRow: View, Equatable {
    let item: ClipboardItem
    let isSelected: Bool
    let searchQuery: String

    // Fixed height for exactly 1 line of text at font size 15
    private let rowHeight: CGFloat = 32

    // Optimization: Cache the truncated text so we don't process massive strings
    private var truncatedText: String {
        String(item.displayText.prefix(300))
    }

    // Define exactly what constitutes a "change" for SwiftUI diffing
    nonisolated static func == (lhs: ItemRow, rhs: ItemRow) -> Bool {
        return lhs.isSelected == rhs.isSelected &&
               lhs.searchQuery == rhs.searchQuery &&
               lhs.item.stableId == rhs.item.stableId
    }

    var body: some View {
        HStack(spacing: 10) {
            // Content type icon
            Image(systemName: item.icon)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)
                .frame(width: 16)

            // Text content
            Text(truncatedText.fuzzyHighlighted(query: searchQuery))
                .lineLimit(1)
                .font(.custom(FontManager.sansSerif, size: 15))
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 4)
        .foregroundStyle(isSelected ? .white : .primary)
        .background {
            if isSelected {
                Color.accentColor
                    .opacity(0.85)
                    .saturation(0.9)
            } else {
                Color.clear
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(truncatedText)
        .accessibilityHint("Double tap to paste")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
