import ClipKittyRust
import SwiftUI

@MainActor
@Observable
final class ClipboardListViewModel {
    private let store: iOSClipboardStore

    var searchText: String = ""
    var filter: ItemQueryFilter = .all
    var items: [ItemMatch] = []
    var totalCount: Int = 0
    var isSearching = false
    var errorMessage: String?

    // Row decorations cache
    var rowDecorations: [String: RowDecoration] = [:]

    private var searchTask: Task<Void, Never>?
    private var searchOperation: ClipboardSearchOperation?
    private var decorationTask: Task<Void, Never>?
    private var lastContentRevision: Int = -1

    init(store: iOSClipboardStore) {
        self.store = store
    }

    func onAppear() {
        performSearch()
    }

    func checkForUpdates(contentRevision: Int) {
        guard contentRevision != lastContentRevision else { return }
        lastContentRevision = contentRevision
        performSearch()
    }

    func updateSearch(text: String) {
        searchText = text
        scheduleSearch()
    }

    func setFilter(_ filter: ItemQueryFilter) {
        self.filter = filter
        performSearch()
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchOperation?.cancel()

        if searchText.isEmpty {
            performSearch()
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            performSearch()
        }
    }

    func performSearch() {
        searchOperation?.cancel()
        isSearching = true
        errorMessage = nil

        guard let operation = store.startSearch(
            query: searchText,
            filter: filter
        ) else {
            isSearching = false
            errorMessage = "Database not available"
            return
        }

        searchOperation = operation

        Task {
            let outcome = await operation.awaitOutcome()
            guard !Task.isCancelled else { return }

            switch outcome {
            case let .success(result):
                self.items = result.matches
                self.totalCount = Int(result.totalCount)
                self.isSearching = false
                self.loadRowDecorations()

            case .cancelled:
                break

            case let .failure(error):
                self.isSearching = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func loadRowDecorations() {
        guard !searchText.isEmpty else {
            rowDecorations = [:]
            return
        }

        let itemIds = items.map(\.itemMetadata.itemId)
        let query = searchText

        decorationTask?.cancel()
        decorationTask = Task {
            let results = await store.loadRowDecorations(
                itemIds: itemIds,
                query: query
            )
            guard !Task.isCancelled else { return }

            var decorations: [String: RowDecoration] = [:]
            for result in results {
                if let decoration = result.decoration {
                    decorations[result.itemId] = decoration
                }
            }
            self.rowDecorations = decorations
        }
    }

    func deleteItem(_ itemId: String) async {
        _ = await store.deleteItem(itemId: itemId)
        items.removeAll { $0.itemMetadata.itemId == itemId }
    }

    func toggleBookmark(_ itemId: String) async {
        let item = items.first { $0.itemMetadata.itemId == itemId }
        let isBookmarked = item?.itemMetadata.tags.contains(.bookmark) ?? false

        if isBookmarked {
            _ = await store.removeTag(itemId: itemId, tag: .bookmark)
        } else {
            _ = await store.addTag(itemId: itemId, tag: .bookmark)
        }
        performSearch()
    }
}

struct ClipboardListView: View {
    @EnvironmentObject private var store: iOSClipboardStore
    @State private var viewModel: ClipboardListViewModel?
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    clipboardList(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("ClipKitty")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search clipboard history"
            )
            .onChange(of: searchText) { _, newValue in
                viewModel?.updateSearch(text: newValue)
            }
        }
        .onAppear {
            if viewModel == nil {
                viewModel = ClipboardListViewModel(store: store)
            }
            viewModel?.onAppear()
        }
        .onChange(of: store.contentRevision) { _, newRevision in
            viewModel?.checkForUpdates(contentRevision: newRevision)
        }
    }

    @ViewBuilder
    private func clipboardList(viewModel: ClipboardListViewModel) -> some View {
        VStack(spacing: 0) {
            FilterBar(
                currentFilter: viewModel.filter,
                onFilterChanged: { viewModel.setFilter($0) }
            )

            if let error = viewModel.errorMessage {
                ContentUnavailableView(
                    "Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if viewModel.items.isEmpty && !viewModel.isSearching {
                if viewModel.searchText.isEmpty {
                    ContentUnavailableView(
                        "No Clipboard History",
                        systemImage: "doc.on.clipboard",
                        description: Text(
                            "Items copied on your Mac will appear here via iCloud sync."
                        )
                    )
                } else {
                    ContentUnavailableView.search(text: viewModel.searchText)
                }
            } else {
                List {
                    ForEach(viewModel.items, id: \.itemMetadata.itemId) {
                        item in
                        NavigationLink(value: item.itemMetadata.itemId) {
                            ItemRowView(
                                metadata: item.itemMetadata,
                                decoration: viewModel.rowDecorations[
                                    item.itemMetadata.itemId
                                ],
                                searchQuery: viewModel.searchText
                            )
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task {
                                    await viewModel.deleteItem(
                                        item.itemMetadata.itemId
                                    )
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                Task {
                                    await viewModel.toggleBookmark(
                                        item.itemMetadata.itemId
                                    )
                                }
                            } label: {
                                if item.itemMetadata.tags.contains(.bookmark) {
                                    Label(
                                        "Unbookmark",
                                        systemImage: "bookmark.slash"
                                    )
                                } else {
                                    Label(
                                        "Bookmark",
                                        systemImage: "bookmark"
                                    )
                                }
                            }
                            .tint(.orange)
                        }
                    }
                }
                .listStyle(.plain)
                .navigationDestination(for: String.self) { itemId in
                    ClipboardDetailView(itemId: itemId)
                }
                .overlay(alignment: .top) {
                    if viewModel.isSearching {
                        ProgressView()
                            .padding(8)
                    }
                }
                .refreshable {
                    viewModel.performSearch()
                }
            }
        }
    }
}

// MARK: - Filter Bar

struct FilterBar: View {
    let currentFilter: ItemQueryFilter
    let onFilterChanged: (ItemQueryFilter) -> Void

    private struct FilterOption: Identifiable {
        let id: String
        let label: String
        let icon: String
        let filter: ItemQueryFilter
    }

    private let options: [FilterOption] = [
        FilterOption(id: "all", label: "All", icon: "tray.full", filter: .all),
        FilterOption(
            id: "text",
            label: "Text",
            icon: "doc.text",
            filter: .contentType(filter: .text)
        ),
        FilterOption(
            id: "images",
            label: "Images",
            icon: "photo",
            filter: .contentType(filter: .images)
        ),
        FilterOption(
            id: "links",
            label: "Links",
            icon: "link",
            filter: .contentType(filter: .links)
        ),
        FilterOption(
            id: "colors",
            label: "Colors",
            icon: "paintpalette",
            filter: .contentType(filter: .colors)
        ),
        FilterOption(
            id: "files",
            label: "Files",
            icon: "folder",
            filter: .contentType(filter: .files)
        ),
        FilterOption(
            id: "bookmarks",
            label: "Saved",
            icon: "bookmark",
            filter: .tagged(tag: .bookmark)
        ),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options) { option in
                    Button {
                        onFilterChanged(option.filter)
                    } label: {
                        Label(option.label, systemImage: option.icon)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isSelected(option.filter)
                                    ? Color.accentColor.opacity(0.15)
                                    : Color(.secondarySystemFill)
                            )
                            .foregroundStyle(
                                isSelected(option.filter)
                                    ? Color.accentColor
                                    : .primary
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
    }

    private func isSelected(_ filter: ItemQueryFilter) -> Bool {
        // Compare by string representation since ItemQueryFilter may not conform to Equatable
        String(describing: currentFilter) == String(describing: filter)
    }
}
