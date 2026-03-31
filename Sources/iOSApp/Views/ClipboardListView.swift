import ClipKittyRust
import SwiftUI
import UIKit

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
    var isSearchBarVisible = false

    // Row decorations cache
    var rowDecorations: [String: RowDecoration] = [:]

    private var searchTask: Task<Void, Never>?
    private var searchOperation: ClipboardSearchOperation?
    private var decorationTask: Task<Void, Never>?
    private var lastContentRevision: Int = -1

    init(store: iOSClipboardStore) {
        self.store = store
    }

    var filterLabel: String {
        switch filter {
        case .all: return "Clipboard"
        case let .contentType(contentFilter):
            switch contentFilter {
            case .text: return "Text"
            case .images: return "Images"
            case .links: return "Links"
            case .colors: return "Colors"
            case .files: return "Files"
            }
        case .tagged: return "Saved"
        }
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

    func toggleSearchBar() {
        isSearchBarVisible.toggle()
        if !isSearchBarVisible {
            searchText = ""
            performSearch()
        }
    }

    func dismissSearch() {
        isSearchBarVisible = false
        searchText = ""
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

    /// Read from the iOS clipboard and save locally.
    func pasteFromClipboard() async -> Bool {
        let pasteboard = UIPasteboard.general

        if let text = pasteboard.string, !text.isEmpty {
            return await store.saveText(text: text)
        }

        if let image = pasteboard.image,
           let data = image.pngData()
        {
            return await store.saveImage(imageData: data)
        }

        if let url = pasteboard.url {
            return await store.saveText(text: url.absoluteString)
        }

        return false
    }
}

struct ClipboardListView: View {
    @EnvironmentObject private var store: iOSClipboardStore
    @State private var viewModel: ClipboardListViewModel?
    @State private var showPastedToast = false
    @State private var showEmptyClipboardToast = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    clipboardContent(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    menuButton
                }
            }
            .sheet(isPresented: $showSettings) {
                iOSSettingsView()
                    .environmentObject(store)
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
    private var menuButton: some View {
        Menu {
            #if ENABLE_SYNC
                Label {
                    switch store.syncStatus {
                    case .synced: Text("iCloud Synced")
                    case .syncing: Text("Syncing...")
                    case .error: Text("Sync Error")
                    case .unavailable: Text("iCloud Unavailable")
                    default: Text("iCloud Sync")
                    }
                } icon: {
                    switch store.syncStatus {
                    case .synced:
                        Image(systemName: "checkmark.icloud")
                    case .syncing:
                        Image(systemName: "arrow.triangle.2.circlepath.icloud")
                    case .error:
                        Image(systemName: "exclamationmark.icloud")
                    case .unavailable:
                        Image(systemName: "xmark.icloud")
                    default:
                        Image(systemName: "icloud")
                    }
                }
            #endif

            Divider()

            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gear")
            }

            Button(role: .destructive) {
                Task {
                    _ = await store.clearAll()
                    viewModel?.performSearch()
                }
            } label: {
                Label("Clear All", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
        }
    }

    @ViewBuilder
    private func clipboardContent(
        viewModel: ClipboardListViewModel
    ) -> some View {
        VStack(spacing: 0) {
            // Main content
            if let error = viewModel.errorMessage {
                Spacer()
                ContentUnavailableView(
                    "Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                Spacer()
            } else if viewModel.items.isEmpty && !viewModel.isSearching {
                Spacer()
                if viewModel.searchText.isEmpty {
                    ContentUnavailableView(
                        "No Clipboard History",
                        systemImage: "doc.on.clipboard",
                        description: Text(
                            "Items copied on your Mac will appear here via iCloud sync.\nTap + to add from this device's clipboard."
                        )
                    )
                } else {
                    ContentUnavailableView.search(text: viewModel.searchText)
                }
                Spacer()
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
                        .swipeActions(
                            edge: .trailing,
                            allowsFullSwipe: true
                        ) {
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
                .refreshable {
                    viewModel.performSearch()
                }
            }

            // Search bar (when visible)
            if viewModel.isSearchBarVisible {
                searchBar(viewModel: viewModel)
            }

            // Bottom toolbar
            bottomToolbar(viewModel: viewModel)
        }
        .overlay(alignment: .top) {
            if showPastedToast {
                toastBanner(
                    message: "Added from clipboard",
                    icon: "checkmark.circle.fill"
                )
            } else if showEmptyClipboardToast {
                toastBanner(
                    message: "Nothing on clipboard",
                    icon: "clipboard"
                )
            }
        }
    }

    // MARK: - Bottom Toolbar

    @ViewBuilder
    private func bottomToolbar(
        viewModel: ClipboardListViewModel
    ) -> some View {
        HStack(spacing: 0) {
            // Search button
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.toggleSearchBar()
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(
                viewModel.isSearchBarVisible ? .primary : .secondary
            )

            Spacer()

            // Filter picker
            Menu {
                filterMenuContent(viewModel: viewModel)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14))
                    Text(viewModel.filterLabel)
                        .font(.subheadline)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .frame(height: 44)
                .contentShape(Rectangle())
            }

            Spacer()

            // Add from clipboard button
            Button {
                Task {
                    let success = await viewModel.pasteFromClipboard()
                    if success {
                        viewModel.performSearch()
                        showPastedToast = true
                        try? await Task.sleep(for: .seconds(1.5))
                        showPastedToast = false
                    } else {
                        showEmptyClipboardToast = true
                        try? await Task.sleep(for: .seconds(1.5))
                        showEmptyClipboardToast = false
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Search Bar

    @ViewBuilder
    private func searchBar(
        viewModel: ClipboardListViewModel
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            let binding = Binding<String>(
                get: { viewModel.searchText },
                set: { viewModel.updateSearch(text: $0) }
            )
            TextField("Search", text: binding)
                .textFieldStyle(.plain)
                .submitLabel(.search)

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.updateSearch(text: "")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.dismissSearch()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Filter Menu

    @ViewBuilder
    private func filterMenuContent(
        viewModel: ClipboardListViewModel
    ) -> some View {
        Button {
            viewModel.setFilter(.all)
        } label: {
            Label("Clipboard", systemImage: "doc.on.clipboard")
        }

        Divider()

        Button {
            viewModel.setFilter(.contentType(filter: .text))
        } label: {
            Label("Text", systemImage: "doc.text")
        }

        Button {
            viewModel.setFilter(.contentType(filter: .images))
        } label: {
            Label("Images", systemImage: "photo")
        }

        Button {
            viewModel.setFilter(.contentType(filter: .links))
        } label: {
            Label("Links", systemImage: "link")
        }

        Button {
            viewModel.setFilter(.contentType(filter: .colors))
        } label: {
            Label("Colors", systemImage: "paintpalette")
        }

        Button {
            viewModel.setFilter(.contentType(filter: .files))
        } label: {
            Label("Files", systemImage: "folder")
        }

        Divider()

        Button {
            viewModel.setFilter(.tagged(tag: .bookmark))
        } label: {
            Label("Saved", systemImage: "bookmark")
        }
    }

    // MARK: - Toast

    @ViewBuilder
    private func toastBanner(message: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline)
            Text(message)
                .font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(radius: 4)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut, value: showPastedToast)
        .animation(.easeInOut, value: showEmptyClipboardToast)
    }
}
