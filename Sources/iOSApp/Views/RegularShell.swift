import ClipKittyRust
import ClipKittyShared
import PhotosUI
import SwiftUI

/// iPad-style two-pane navigation shell with persistent list/detail layout.
struct RegularShell: View {
    @Environment(SceneState.self) private var sceneState
    @Environment(BrowserViewModel.self) private var viewModel
    @Environment(HapticsClient.self) private var haptics

    @Environment(AppContainer.self) private var container

    @State private var hasAppeared = false
    @State private var showPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?

    private var selectedItemId: String? {
        if case let .selected(id) = sceneState.detailSelection { return id }
        return nil
    }

    var body: some View {
        @Bindable var sceneState = sceneState

        NavigationSplitView {
            sidebarContent
            .navigationTitle("ClipKitty")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: Binding(
                    get: { viewModel.searchText },
                    set: { viewModel.updateSearchText($0) }
                ),
                isPresented: Binding(
                    get: { sceneState.chromeState == .searching },
                    set: { sceneState.chromeState = $0 ? .searching : .idle }
                ),
                prompt: "Search"
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    filterMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    addMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        sceneState.modalRoute = .settings
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        } detail: {
            if let selectedItemId {
                DetailPane(itemId: selectedItemId)
            } else {
                ContentUnavailableView(
                    "No Item Selected",
                    systemImage: "clipboard",
                    description: Text("Select an item from the list")
                )
            }
        }
        .sheet(item: $sceneState.modalRoute) { route in
            switch route {
            case .settings:
                SettingsScreen()
            case let .edit(itemId):
                EditView(itemId: itemId)
            case .compose:
                TextComposerView()
            }
        }
        .overlay(alignment: .bottom) {
            toastOverlay
                .padding(.bottom, 16)
        }
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            viewModel.onAppear(
                initialSearchQuery: "",
                contentRevision: sceneState.contentRevision
            )
            consumePendingDeepLink()
        }
        .onChange(of: viewModel.selectedItemState?.item.itemMetadata.itemId) { _, vmItemId in
            if selectedItemId != vmItemId {
                sceneState.detailSelection = vmItemId.map { .selected(itemId: $0) } ?? .none
            }
        }
        .onChange(of: viewModel.displayRows) { _, rows in
            // Auto-select the first item on iPad when the list loads and nothing is selected.
            if case .none = sceneState.detailSelection, let first = rows.first {
                sceneState.detailSelection = .selected(itemId: first.metadata.itemId)
            }
        }
        .onChange(of: sceneState.contentRevision) { _, newValue in
            viewModel.handlePanelVisibilityChange(true, contentRevision: newValue)
        }
        .onChange(of: sceneState.router.pendingDeepLink) { _, _ in
            consumePendingDeepLink()
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhoto,
            matching: .images
        )
        .onChange(of: selectedPhoto) { _, newItem in
            guard let newItem else { return }
            Task { await importPhoto(from: newItem) }
        }
        .background {
            VStack {
                Button("") { sceneState.chromeState = .searching }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden()
                Button("") { sceneState.modalRoute = .settings }
                    .keyboardShortcut(",", modifiers: .command)
                    .hidden()
                Button("") { copySelectedItem() }
                    .keyboardShortcut(.return, modifiers: [])
                    .hidden()
                Button("") {
                    if sceneState.modalRoute != nil {
                        sceneState.modalRoute = nil
                    } else if sceneState.chromeState == .searching {
                        sceneState.chromeState = .idle
                    }
                }
                    .keyboardShortcut(.escape, modifiers: [])
                    .hidden()
                Button("") { sceneState.modalRoute = .compose }
                    .keyboardShortcut("n", modifiers: .command)
                    .hidden()
                Button("") { viewModel.moveSelection(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                    .hidden()
                Button("") { viewModel.moveSelection(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                    .hidden()
            }
            .frame(width: 0, height: 0)
        }
    }

    // MARK: - Actions

    private func consumePendingDeepLink() {
        guard let deepLink = sceneState.router.pendingDeepLink else { return }
        sceneState.modalRoute = nil
        switch deepLink {
        case let .search(query):
            sceneState.chromeState = .searching
            viewModel.updateSearchText(query)
        case .newItem:
            sceneState.modalRoute = .compose
        }
        sceneState.router.pendingDeepLink = nil
    }

    private func copySelectedItem() {
        guard case let .selected(itemId) = sceneState.detailSelection else { return }
        viewModel.copyOnlyItem(itemId: itemId)
    }

    // MARK: - Sidebar Content

    @ViewBuilder
    private var sidebarContent: some View {
        switch viewModel.contentState {
        case .idle:
            Color.clear

        case let .loading(_, previous, phase):
            if previous != nil {
                sidebarList
            } else if phase.isSpinnerVisible {
                loadingView
            } else {
                Color.clear
            }

        case .loaded:
            if viewModel.displayRows.isEmpty {
                emptyStateView
            } else {
                sidebarList
            }

        case let .failed(_, message, previous):
            if previous != nil {
                sidebarList
            } else {
                failedView(message: message)
            }
        }
    }

    private var sidebarList: some View {
        let selectionBinding = Binding<String?>(
            get: { selectedItemId },
            set: { newId in
                sceneState.detailSelection = newId.map { .selected(itemId: $0) } ?? .none
            }
        )

        return List(viewModel.displayRows, selection: selectionBinding) { row in
            CardView(row: row)
                .tag(row.metadata.itemId)
                .onAppear {
                    if row.listDecoration == nil {
                        viewModel.loadListDecorationsForItems([row.id])
                    }
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .onChange(of: sceneState.detailSelection) { _, newValue in
            if case let .selected(itemId) = newValue {
                viewModel.select(itemId: itemId, origin: .user)
            }
        }
    }

    // MARK: - Loading / Empty / Error States

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .controlSize(.regular)
            Spacer()
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            if isSearchOrFilterActive {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No results found", comment: "Empty state title when search returns no matches")
                    .font(.title3.weight(.semibold))
                Text("Try adjusting your search or filters", comment: "Empty state subtitle for search")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "clipboard")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No items yet", comment: "Empty state title when clipboard history is empty")
                    .font(.title3.weight(.semibold))
                Text("Copy something to get started, or tap + to add manually", comment: "Empty state subtitle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
        }
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Something went wrong", comment: "Error state title")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastOverlay: some View {
        if let message = sceneState.toast.message {
            GlassEffectContainer {
                HStack(spacing: 10) {
                    Image(systemName: message.iconSystemName)
                        .font(.subheadline.weight(.medium))
                    Text(message.text)
                        .font(.subheadline.weight(.medium))

                    if let actionTitle = message.actionTitle, let action = sceneState.toast.action {
                        Button {
                            action()
                            withAnimation(.bouncy) {
                                sceneState.toast = .init()
                            }
                        } label: {
                            Text(actionTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var isSearchOrFilterActive: Bool {
        !viewModel.searchText.isEmpty
            || viewModel.contentTypeFilter != .all
            || viewModel.selectedTagFilter != nil
    }

    // MARK: - Filter Menu

    private var filterMenu: some View {
        Menu {
            Button {
                viewModel.setTagFilter(nil)
                viewModel.setContentTypeFilter(.all)
            } label: {
                Label("All", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
            }

            Button {
                viewModel.setTagFilter(.bookmark)
            } label: {
                Label("Bookmarks", systemImage: "bookmark.fill")
            }

            Button {
                viewModel.setTagFilter(nil)
                viewModel.setContentTypeFilter(.text)
            } label: {
                Label("Text", systemImage: "doc.text")
            }

            Button {
                viewModel.setTagFilter(nil)
                viewModel.setContentTypeFilter(.images)
            } label: {
                Label("Images", systemImage: "photo")
            }

            Button {
                viewModel.setTagFilter(nil)
                viewModel.setContentTypeFilter(.links)
            } label: {
                Label("Links", systemImage: "link")
            }

            Button {
                viewModel.setTagFilter(nil)
                viewModel.setContentTypeFilter(.colors)
            } label: {
                Label("Colors", systemImage: "paintpalette")
            }
        } label: {
            Label(activeFilterLabel, systemImage: activeFilterIcon)
        }
    }

    // MARK: - Add Menu

    private var addMenu: some View {
        Menu {
            Button {
                sceneState.modalRoute = .compose
            } label: {
                Label("Compose Text", systemImage: "square.and.pencil")
            }

            Button {
                showPhotoPicker = true
            } label: {
                Label("Import Photo", systemImage: "photo.badge.plus")
            }

            Button {
                Task { await pasteClipboard() }
            } label: {
                Label("Paste Clipboard", systemImage: "doc.on.clipboard")
            }
        } label: {
            Image(systemName: "plus")
        }
    }

    // MARK: - Active Filter State

    private var activeFilterLabel: String {
        if viewModel.selectedTagFilter == .bookmark { return String(localized: "Bookmarks") }
        switch viewModel.contentTypeFilter {
        case .all: return String(localized: "All")
        case .text: return String(localized: "Text")
        case .images: return String(localized: "Images")
        case .links: return String(localized: "Links")
        case .colors: return String(localized: "Colors")
        case .files: return String(localized: "Files")
        }
    }

    private var activeFilterIcon: String {
        if viewModel.selectedTagFilter == .bookmark { return "bookmark.fill" }
        switch viewModel.contentTypeFilter {
        case .all: return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .text: return "doc.text"
        case .images: return "photo"
        case .links: return "link"
        case .colors: return "paintpalette"
        case .files: return "folder"
        }
    }

    // MARK: - Paste Clipboard

    private func pasteClipboard() async {
        guard let content = container.clipboardService.readCurrentClipboard() else {
            sceneState.showToast(.addFailed(String(localized: "Clipboard is empty")))
            return
        }

        let result: Result<String, ClipboardError>

        switch content {
        case let .image(image):
            guard let data = image.pngData() else {
                sceneState.showToast(.addFailed(String(localized: "Could not read image data")))
                return
            }
            let thumbnail = image.preparingThumbnail(of: CGSize(width: 200, height: 200))?.jpegData(
                compressionQuality: 0.7
            )
            result = await container.repository.saveImage(
                imageData: data,
                thumbnail: thumbnail,
                sourceApp: "Pasteboard",
                sourceAppBundleId: nil,
                isAnimated: false
            )
        case let .link(url):
            result = await container.repository.saveText(
                text: url.absoluteString,
                sourceApp: "Pasteboard",
                sourceAppBundleId: nil
            )
        case let .text(text):
            result = await container.repository.saveText(
                text: text,
                sourceApp: "Pasteboard",
                sourceAppBundleId: nil
            )
        }

        switch result {
        case .success:
            haptics.fire(.success)
            sceneState.showToast(.addSucceeded)
            sceneState.refreshFeed()
        case let .failure(error):
            haptics.fire(.destructive)
            sceneState.showToast(.addFailed(error.localizedDescription))
        }
    }

    // MARK: - Import Photo

    private func importPhoto(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            sceneState.showToast(.addFailed(String(localized: "Could not load photo")))
            return
        }

        let thumbnail: Data? = {
            guard let image = UIImage(data: data) else { return nil }
            return image.preparingThumbnail(of: CGSize(width: 200, height: 200))?.jpegData(
                compressionQuality: 0.7
            )
        }()

        let result = await container.repository.saveImage(
            imageData: data,
            thumbnail: thumbnail,
            sourceApp: "Photos",
            sourceAppBundleId: nil,
            isAnimated: false
        )

        switch result {
        case .success:
            haptics.fire(.success)
            sceneState.showToast(.addSucceeded)
            sceneState.refreshFeed()
        case let .failure(error):
            haptics.fire(.destructive)
            sceneState.showToast(.addFailed(error.localizedDescription))
        }
    }
}
