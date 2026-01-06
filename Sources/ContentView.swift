import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var store: ClipboardStore
    let onSelect: (ClipboardItem) -> Void
    let onDismiss: () -> Void

    @State private var selectedIndex: Int = 0
    @FocusState private var isSearchFocused: Bool

    private var displayedItems: [ClipboardItem] {
        store.filteredItems
    }

    private var selectedItem: ClipboardItem? {
        displayedItems[safe: selectedIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            splitView
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
            selectedIndex = 0
        }
        .onChange(of: store.searchQuery) {
            selectedIndex = 0
        }
        .onChange(of: store.panelRevision) {
            selectedIndex = 0
            isSearchFocused = true
        }
    }

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
                    selectCurrentItem()
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

    private var splitView: some View {
        HStack(spacing: 0) {
            itemList
                .frame(width: 280)

            Divider()

            previewPane
                .frame(maxWidth: .infinity)
        }
    }

    private var itemList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(displayedItems.enumerated()), id: \.element.stableId) { index, item in
                        ItemRow(
                            item: item,
                            isSelected: index == selectedIndex,
                            shortcutNumber: index < 9 ? index + 1 : nil,
                            searchQuery: store.searchQuery
                        )
                        .id(item.stableId)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedIndex = index
                        }
                        .onTapGesture(count: 2) {
                            selectedIndex = index
                            selectCurrentItem()
                        }
                        .onAppear {
                            if index == displayedItems.count - 10 {
                                store.loadMoreItems()
                            }
                        }
                    }

                    if store.hasMore && store.searchQuery.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                            .onAppear {
                                store.loadMoreItems()
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.automatic)
            .onChange(of: selectedIndex) { _, newIndex in
                if let item = displayedItems[safe: newIndex] {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(item.stableId, anchor: .center)
                    }
                }
            }
        }
    }

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
            } else {
                Text("No item selected")
                    .font(.custom(FontManager.sansSerif, size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.black.opacity(0.05))
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

    private func moveSelection(by offset: Int) {
        let newIndex = selectedIndex + offset
        if newIndex >= 0 && newIndex < displayedItems.count {
            selectedIndex = newIndex
        }
    }

    private func selectCurrentItem() {
        guard let item = displayedItems[safe: selectedIndex] else { return }
        onSelect(item)
    }

    private func handleNumberKey(_ keyPress: KeyPress) -> KeyPress.Result {
        guard let number = Int(keyPress.characters),
              number >= 1 && number <= 9 else {
            return .ignored
        }

        let modifiers = keyPress.modifiers
        guard modifiers.contains(.command) else { return .ignored }

        let index = number - 1
        guard index < displayedItems.count else { return .ignored }

        selectedIndex = index
        selectCurrentItem()
        return .handled
    }
}

struct ItemRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let shortcutNumber: Int?
    let searchQuery: String

    var body: some View {
        HStack(spacing: 8) {
            if let number = shortcutNumber {
                Text("⌘\(number)")
                    .font(.custom(FontManager.mono, size: 11).weight(.medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 24)
            } else {
                Spacer()
                    .frame(width: 24)
            }

            VStack(alignment: .leading, spacing: 2) {
                highlightedText
                    .lineLimit(1)
                    .font(.custom(FontManager.sansSerif, size: 13))

                HStack(spacing: 4) {
                    Text(item.timeAgo)
                    if item.content.count > 1000 {
                        Text("•")
                        Text("\(formatSize(item.content.count))")
                    }
                }
                .font(.custom(FontManager.sansSerif, size: 11))
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : .clear)
        .contentShape(Rectangle())
    }

    private func formatSize(_ chars: Int) -> String {
        if chars >= 1_000_000 {
            return String(format: "%.1fM chars", Double(chars) / 1_000_000)
        } else if chars >= 1000 {
            return String(format: "%.1fK chars", Double(chars) / 1000)
        }
        return "\(chars) chars"
    }

    @ViewBuilder
    private var highlightedText: some View {
        if searchQuery.isEmpty {
            Text(item.displayText)
                .foregroundStyle(.primary)
        } else {
            Text(attributedString)
        }
    }

    private var attributedString: AttributedString {
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
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
