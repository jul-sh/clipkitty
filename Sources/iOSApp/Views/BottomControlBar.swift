import ClipKittyRust
import ClipKittyShared
import PhotosUI
import SwiftUI

struct BottomControlBar: View {
    @Binding var isSearchActive: Bool
    let searchFocusRequestID: Int

    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var appState
    @Environment(BrowserViewModel.self) private var viewModel
    @Environment(HapticsClient.self) private var haptics
    @Environment(iOSSettingsStore.self) private var settings

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var presentation: BarPresentation = .idle

    private enum BarPresentation {
        case idle
        case addMenu
        case filterMenu
        case composingText
        case importingPhoto
    }

    @FocusState private var isSearchFocused: Bool
    @Namespace private var barNamespace

    var body: some View {
        ZStack(alignment: .bottom) {
            // Dismiss overlay when expanded menus are open
            switch presentation {
            case .addMenu, .filterMenu:
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.bouncy) {
                            presentation = .idle
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .idle, .composingText, .importingPhoto:
                EmptyView()
            }

            GlassEffectContainer(spacing: 20) {
                HStack(alignment: .bottom, spacing: 20) {
                    // Left: search circle morphs into search field
                    if isSearchActive {
                        searchField
                            .id(searchFocusRequestID)
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
            isPresented: Binding(
                get: {
                    if case .importingPhoto = presentation { return true }
                    return false
                },
                set: { presented in
                    if !presented, case .importingPhoto = presentation {
                        presentation = .idle
                    }
                }
            ),
            selection: $selectedPhoto,
            matching: .images
        )
        .sheet(isPresented: Binding(
            get: {
                if case .composingText = presentation { return true }
                return false
            },
            set: { presented in
                if !presented, case .composingText = presentation {
                    presentation = .idle
                }
            }
        )) {
            TextComposerView()
        }
        .onChange(of: selectedPhoto) { _, newItem in
            guard let newItem else { return }
            Task { await importPhoto(from: newItem) }
        }
        .onChange(of: searchFocusRequestID) { _, _ in
            restoreSearchFocusIfNeeded()
        }
        // Search can be activated from outside the bar; make sure no create
        // sheet/menu covers it.
        .onChange(of: isSearchActive) { _, active in
            guard active else { return }
            withAnimation(.bouncy) {
                presentation = .idle
            }
        }
    }

    // MARK: - Search button (collapsed)

    private var searchButton: some View {
        Button {
            withAnimation(.bouncy) {
                presentation = .idle
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
        .accessibilityIdentifier("bottomBar.searchButton")
    }

    // MARK: - Search field (expanded)

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(String(localized: "Search"), text: searchTextBinding)
                .focused($isSearchFocused)
                .accessibilityIdentifier("bottomBar.searchField")
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !viewModel.searchText.isEmpty {
                Button {
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
            switch presentation {
            case .filterMenu:
                VStack(spacing: 12) {
                    ForEach(sortedFilterOptions, id: \.kind) { option in
                        let isActive = option.kind == viewModel.activeFilterKind
                        Button {
                            viewModel.applyFilter(option.kind)
                            haptics.fire(.selection)
                            withAnimation(.bouncy) {
                                presentation = .idle
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: option.symbolName)
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
                        .accessibilityIdentifier("bottomBar.filterOption.\(option.identifierSuffix)")
                    }
                }
                .glassEffectID("filter", in: barNamespace)
            case .idle, .addMenu, .composingText, .importingPhoto:
                Button {
                    withAnimation(.bouncy) {
                        presentation = .filterMenu
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: activeFilterDescriptor.symbolName)
                            .font(.subheadline.weight(.medium))
                        Text(activeFilterDescriptor.title)
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
                .accessibilityIdentifier("bottomBar.filterPill")
            }
        }
    }

    // MARK: - Add cluster (expandable glass buttons)

    private var addCluster: some View {
        VStack(spacing: 12) {
            switch presentation {
            case .addMenu:
                Button {
                    withAnimation(.bouncy) { presentation = .importingPhoto }
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
                    withAnimation(.bouncy) { presentation = .composingText }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.body.weight(.medium))
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID("add_text", in: barNamespace)

                // With auto-add on, everything on the pasteboard is ingested
                // each time the app comes to the foreground, so a manual
                // "add from clipboard" button would only ever duplicate that.
                if !settings.autoAddFromClipboard {
                    Button {
                        withAnimation(.bouncy) { presentation = .idle }
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
            case .idle, .filterMenu, .composingText, .importingPhoto:
                EmptyView()
            }

            Button {
                withAnimation(.bouncy) {
                    switch presentation {
                    case .addMenu:
                        presentation = .idle
                    case .idle, .filterMenu, .composingText, .importingPhoto:
                        presentation = .addMenu
                    }
                }
            } label: {
                switch presentation {
                case .addMenu:
                    addButtonImage(systemName: "xmark")
                case .idle, .filterMenu, .composingText, .importingPhoto:
                    addButtonImage(systemName: "plus")
                }
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .glassEffectID("trailing", in: barNamespace)
            .accessibilityLabel(String(localized: "Add new item"))
        }
    }

    private func addButtonImage(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.body.weight(.medium))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 52, height: 52)
            .contentShape(Circle())
    }

    // MARK: - Dismiss search

    private var dismissButton: some View {
        Button {
            isSearchFocused = false
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
        .accessibilityIdentifier("bottomBar.closeSearchButton")
    }

    // MARK: - Filter state

    /// The picker lists "All" plus every selectable filter from the shared
    /// catalog, with the active option sorted last (nearest the pill).
    private var sortedFilterOptions: [BrowserFilterDescriptor] {
        let allOptions = [allFilterOption] + viewModel.selectableFilters
        var options = allOptions.filter { $0.kind != viewModel.activeFilterKind }
        if let active = allOptions.first(where: { $0.kind == viewModel.activeFilterKind }) {
            options.append(active)
        }
        return options
    }

    private var allFilterOption: BrowserFilterDescriptor {
        viewModel.filterDescriptor(for: .all)
    }

    private var activeFilterDescriptor: BrowserFilterDescriptor {
        viewModel.appliedFilterDescriptor ?? allFilterOption
    }

    private var searchTextBinding: Binding<String> {
        Binding(
            get: { viewModel.searchText },
            set: { viewModel.updateSearchText($0) }
        )
    }

    private func restoreSearchFocusIfNeeded() {
        guard isSearchActive else { return }
        Task { @MainActor in
            await Task.yield()
            guard isSearchActive else { return }
            isSearchFocused = true
        }
    }

    // MARK: - Paste clipboard

    private func pasteClipboard() async {
        guard let content = container.clipboardService.readCurrentClipboard() else {
            // Explain the no-op: otherwise tapping the button with an empty
            // pasteboard just silently adds nothing.
            haptics.fire(.destructive)
            appState.showToast(.clipboardEmpty)
            return
        }

        guard let result = await appState.savePasteboardContent(content) else {
            haptics.fire(.destructive)
            appState.showToast(.addFailed(String(localized: "Could not read image data")))
            return
        }
        handleAddResult(result)
    }

    // MARK: - Import photo

    private func importPhoto(from item: PhotosPickerItem) async {
        defer { selectedPhoto = nil }

        guard let data = try? await item.loadTransferable(type: Data.self) else {
            appState.showToast(.addFailed(String(localized: "Could not load photo")))
            return
        }

        let thumbnail: Data? = {
            guard let image = UIImage(data: data) else { return nil }
            return image.preparingThumbnail(of: CGSize(width: 200, height: 200))?.jpegData(
                compressionQuality: 0.7
            )
        }()

        let result = await appState.saveImage(
            imageData: data,
            thumbnail: thumbnail,
            sourceApp: "Photos",
            sourceAppBundleId: nil,
            isAnimated: false
        )

        handleAddResult(result)
    }

    private func handleAddResult(_ result: Result<String, ClipboardError>) {
        switch result {
        case .success:
            haptics.fire(.success)
            appState.showToast(.addSucceeded)
            appState.refreshFeed()
        case let .failure(error):
            haptics.fire(.destructive)
            appState.showToast(.addFailed(error.localizedDescription))
        }
    }
}
