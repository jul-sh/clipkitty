import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var store: ClipboardStore
    let onSelect: (ClipboardItem) -> Void
    let onDismiss: () -> Void

    @State private var selection: String?
    @FocusState private var isSearchFocused: Bool

    // Derived from store state
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
        .frame(width: 720, height: 480)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .onAppear {
            isSearchFocused = true
            selectFirstItem()
        }
        .onChange(of: store.state) { _, _ in
            // When state changes, ensure selection is valid
            validateSelection()
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
                .font(.custom(FontManager.sansSerif, size: 16).weight(.medium))

            TextField("Search clipboard...", text: $store.searchQuery)
                .textFieldStyle(.plain)
                .font(.custom(FontManager.sansSerif, size: 16))
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
        case .idle, .loading:
            loadingView
        case .error(let message):
            errorView(message)
        case .loaded, .searchResults, .searching:
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
                .font(.custom(FontManager.sansSerif, size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var splitView: some View {
        HStack(spacing: 0) {
            itemList
                .frame(width: 280)

            Divider()

            previewPane
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Item List

    private var itemList: some View {
        ScrollViewReader { proxy in
            List(items, id: \.stableId, selection: $selection) { item in
                let index = items.firstIndex { $0.stableId == item.stableId } ?? 0
                ItemRow(
                    item: item,
                    isSelected: item.stableId == selection,
                    shortcutNumber: index < 9 ? index + 1 : nil,
                    searchQuery: store.searchQuery
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
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
        Group {
            if let item = selectedItem {
                ScrollView {
                    Text(highlightedPreview(for: item))
                        .font(.custom(FontManager.mono, size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else if items.isEmpty {
                emptyStateView
            } else {
                Text("No item selected")
                    .font(.custom(FontManager.sansSerif, size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.black.opacity(0.05))
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "clipboard")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(store.searchQuery.isEmpty ? "No clipboard history" : "No results")
                .font(.custom(FontManager.sansSerif, size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func highlightedPreview(for item: ClipboardItem) -> AttributedString {
        let previewText = item.contentPreview
        var result = AttributedString(previewText)

        guard !store.searchQuery.isEmpty else { return result }

        let queryLower = store.searchQuery.lowercased()
        let textLower = previewText.lowercased()

        var searchStart = textLower.startIndex
        while let range = textLower.range(of: queryLower, range: searchStart..<textLower.endIndex) {
            if let attrRange = Range(range, in: result) {
                result[attrRange].backgroundColor = .yellow.opacity(0.4)
            }
            searchStart = range.upperBound
        }

        return result
    }
}

// MARK: - Item Row

struct ItemRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let shortcutNumber: Int?
    let searchQuery: String

    var body: some View {
        HStack(spacing: 8) {
            shortcutLabel
            contentStack
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : .clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var shortcutLabel: some View {
        if let number = shortcutNumber {
            Text("⌘\(number)")
                .font(.custom(FontManager.mono, size: 11).weight(.medium))
                .foregroundStyle(.tertiary)
                .frame(width: 24)
        } else {
            Spacer().frame(width: 24)
        }
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            highlightedText
                .lineLimit(1)
                .font(.custom(FontManager.sansSerif, size: 13))

            HStack(spacing: 4) {
                Text(item.timeAgo)
                if item.content.count > 1000 {
                    Text("•")
                    Text(formatSize(item.content.count))
                }
            }
            .font(.custom(FontManager.sansSerif, size: 11))
            .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var highlightedText: some View {
        if searchQuery.isEmpty {
            Text(item.displayText)
                .foregroundStyle(.primary)
        } else {
            Text(attributedDisplayText)
        }
    }

    private var attributedDisplayText: AttributedString {
        var result = AttributedString(item.displayText)
        let queryLower = searchQuery.lowercased()
        let textLower = item.displayText.lowercased()

        var searchStart = textLower.startIndex
        while let range = textLower.range(of: queryLower, range: searchStart..<textLower.endIndex) {
            if let attrRange = Range(range, in: result) {
                result[attrRange].backgroundColor = .yellow.opacity(0.4)
            }
            searchStart = range.upperBound
        }

        return result
    }

    private func formatSize(_ chars: Int) -> String {
        if chars >= 1_000_000 {
            return String(format: "%.1fM chars", Double(chars) / 1_000_000)
        } else if chars >= 1000 {
            return String(format: "%.1fK chars", Double(chars) / 1000)
        }
        return "\(chars) chars"
    }
}
