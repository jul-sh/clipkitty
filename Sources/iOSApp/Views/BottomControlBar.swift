import ClipKittyRust
import ClipKittyShared
import PhotosUI
import SwiftUI

struct BottomControlBar: View {
    @Binding var isSearchActive: Bool
    @Environment(AppContainer.self) private var container
    @Environment(SceneState.self) private var sceneState
    @Environment(BrowserViewModel.self) private var viewModel
    @Environment(HapticsClient.self) private var haptics

    @State private var searchText: String = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isImportingPhoto = false

    private var isAddExpanded: Bool {
        sceneState.chromeState == .addMenuExpanded
    }

    private var isFilterExpanded: Bool {
        sceneState.chromeState == .filterExpanded
    }
    @FocusState private var isSearchFocused: Bool
    @Namespace private var barNamespace

    var body: some View {
        ZStack(alignment: .bottom) {
            // Dismiss overlay when expanded menus are open
            if isAddExpanded || isFilterExpanded {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.bouncy) {
                            sceneState.chromeState = .idle
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            GlassEffectContainer(spacing: 20) {
                HStack(alignment: .bottom, spacing: 20) {
                    // Left: search circle morphs into search field
                    if isSearchActive {
                        searchField
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .glassEffectID("search", in: barNamespace)
                    } else {
                        searchButton
                            .glassEffect(.regular.interactive(), in: .circle)
                            .glassEffectID("search", in: barNamespace)
                    }

                    // Center: filter — morphs between pill and expanded picker
                    if !isSearchActive {
                        filterCluster
                    }

                    // Right: add cluster morphs into dismiss circle
                    if isSearchActive {
                        dismissButton
                            .glassEffect(.regular.interactive(), in: .circle)
                            .glassEffectID("trailing", in: barNamespace)
                    } else {
                        addCluster
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .photosPicker(
            isPresented: $isImportingPhoto,
            selection: $selectedPhoto,
            matching: .images
        )
        .onChange(of: viewModel.searchText) { _, externalValue in
            if searchText != externalValue {
                searchText = externalValue
            }
        }
        .onChange(of: selectedPhoto) { _, newItem in
            guard let newItem else { return }
            Task { await importPhoto(from: newItem) }
        }
    }

    // MARK: - Search button (collapsed)

    private var searchButton: some View {
        Button {
            withAnimation(.bouncy) {
                sceneState.chromeState = .searching
                isSearchActive = true
            }
            isSearchFocused = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.medium))
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Search"))
    }

    // MARK: - Search field (expanded)

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(String(localized: "Search"), text: $searchText)
                .focused($isSearchFocused)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onChange(of: searchText) { _, newValue in
                    viewModel.updateSearchText(newValue)
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    viewModel.updateSearchText("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
    }

    // MARK: - Filter cluster (morphs between pill and expanded picker)

    private var filterCluster: some View {
        VStack(spacing: 8) {
            if isFilterExpanded {
                VStack(spacing: 12) {
                    ForEach(sortedFilterOptions, id: \.self) { option in
                        let isActive = option == activeFilter
                        Button {
                            applyFilter(option)
                            haptics.fire(.selection)
                            withAnimation(.bouncy) {
                                sceneState.chromeState = .idle
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: option.icon)
                                    .font(.subheadline.weight(.medium))
                                    .frame(width: 24)
                                Text(option.title)
                                    .font(.subheadline.weight(.semibold))
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 52)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(
                            isActive ? .regular.interactive() : .regular,
                            in: .capsule
                        )
                    }
                }
                .glassEffectID("filter", in: barNamespace)
            } else {
                Button {
                    withAnimation(.bouncy) {
                        sceneState.chromeState = .filterExpanded
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: filterIcon)
                            .font(.subheadline.weight(.medium))
                        Text(filterLabel)
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("filter", in: barNamespace)
            }
        }
    }

    // MARK: - Add cluster (expandable glass buttons)

    private var addCluster: some View {
        VStack(spacing: 12) {
            if isAddExpanded {
                Button {
                    withAnimation(.bouncy) { sceneState.chromeState = .idle }
                    isImportingPhoto = true
                } label: {
                    Image(systemName: "photo.badge.plus")
                        .font(.body.weight(.medium))
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID("add_photo", in: barNamespace)

                Button {
                    withAnimation(.bouncy) { sceneState.chromeState = .idle }
                    sceneState.modalRoute = .compose
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.body.weight(.medium))
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID("add_text", in: barNamespace)

                Button {
                    withAnimation(.bouncy) { sceneState.chromeState = .idle }
                    Task { await pasteClipboard() }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.body.weight(.medium))
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID("add_paste", in: barNamespace)
            }

            Button {
                withAnimation(.bouncy) {
                    sceneState.chromeState = isAddExpanded ? .idle : .addMenuExpanded
                }
            } label: {
                Image(systemName: isAddExpanded ? "xmark" : "plus")
                    .font(.body.weight(.medium))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .glassEffectID("trailing", in: barNamespace)
            .accessibilityLabel(String(localized: "Add new item"))
        }
    }

    // MARK: - Dismiss search

    private var dismissButton: some View {
        Button {
            isSearchFocused = false
            searchText = ""
            viewModel.updateSearchText("")
            withAnimation(.bouncy) {
                isSearchActive = false
            }
        } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.medium))
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Close search"))
    }

    // MARK: - Filter state

    private var activeFilter: FilterOption {
        if viewModel.selectedTagFilter == .bookmark { return .bookmarks }
        switch viewModel.contentTypeFilter {
        case .all, .files: return .all
        case .text: return .text
        case .images: return .images
        case .links: return .links
        case .colors: return .colors
        }
    }

    private var sortedFilterOptions: [FilterOption] {
        let active = activeFilter
        var options = FilterOption.allCases.filter { $0 != active }
        options.append(active)
        return options
    }

    private func applyFilter(_ option: FilterOption) {
        switch option {
        case .all:
            viewModel.setTagFilter(nil)
            viewModel.setContentTypeFilter(.all)
        case .bookmarks:
            viewModel.setTagFilter(.bookmark)
        case .text:
            viewModel.setTagFilter(nil)
            viewModel.setContentTypeFilter(.text)
        case .images:
            viewModel.setTagFilter(nil)
            viewModel.setContentTypeFilter(.images)
        case .links:
            viewModel.setTagFilter(nil)
            viewModel.setContentTypeFilter(.links)
        case .colors:
            viewModel.setTagFilter(nil)
            viewModel.setContentTypeFilter(.colors)
        }
    }

    // MARK: - Filter label

    private var filterLabel: String {
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

    private var filterIcon: String {
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

    // MARK: - Paste clipboard

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

    // MARK: - Import photo

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

private enum FilterOption: CaseIterable, Hashable {
    case all, bookmarks, text, images, links, colors

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .bookmarks: return String(localized: "Bookmarks")
        case .text: return String(localized: "Text")
        case .images: return String(localized: "Images")
        case .links: return String(localized: "Links")
        case .colors: return String(localized: "Colors")
        }
    }

    var icon: String {
        switch self {
        case .all: return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .bookmarks: return "bookmark.fill"
        case .text: return "doc.text"
        case .images: return "photo"
        case .links: return "link"
        case .colors: return "paintpalette"
        }
    }
}
