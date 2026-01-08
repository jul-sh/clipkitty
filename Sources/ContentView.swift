import SwiftUI
import AppKit

struct ContentView: View {
    var store: ClipboardStore
    let onSelect: (ClipboardItem) -> Void
    let onDismiss: () -> Void

    @State private var selection: String?
    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool

    private var items: [ClipboardItem] { store.items }

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
                .onKeyPress(.return) {
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

            if store.isSearching {
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
                    selection = item.stableId
                    confirmSelection()
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
                if let newSelection {
                    proxy.scrollTo(newSelection, anchor: .center)
                }
            }
        }
    }

    // MARK: - Preview Pane

    private var previewPane: some View {
        VStack(spacing: 0) {
            if let item = selectedItem {
                // Content
                ScrollView(.vertical, showsIndicators: true) {
                    Text(highlightedPreview(for: item))
                        .font(.custom(FontManager.mono, size: 15))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }

                Divider()

                // Metadata footer
                HStack(spacing: 12) {
                    Label(item.timeAgo, systemImage: "clock")
                    if item.content.count > 100 {
                        Label(formatSize(item.content.count), systemImage: "doc.text")
                    }
                    if let app = item.sourceApp {
                        Label(app, systemImage: "app")
                    }
                    Spacer()
                    Text("⏎ copy")
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 17)
                .padding(.vertical, 11)
                .glassEffect(.regular, in: Rectangle())
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

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "clipboard")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(store.searchQuery.isEmpty ? "No clipboard history" : "No results")
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
        Text(truncatedText.fuzzyHighlighted(query: searchQuery))
            .lineLimit(1)
            .font(.custom(FontManager.sansSerif, size: 15))
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
