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
    @State private var createFlow: CreateFlow = .none
    @State private var isFilterExpanded = false

    private enum CreateFlow: Equatable {
        case none
        case menuExpanded
        case composingText
        case importingPhoto
        case importingPasteboard
    }

    private var isAddExpanded: Bool {
        createFlow == .menuExpanded
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
                            createFlow = .none
                            isFilterExpanded = false
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                get: { createFlow == .importingPhoto },
                set: { if !$0 { createFlow = .none } }
            ),
            selection: $selectedPhoto,
            matching: .images
        )
        .sheet(isPresented: Binding(
            get: { createFlow == .composingText },
            set: { if !$0 { createFlow = .none } }
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
    }

    // MARK: - Search button (collapsed)

    private var searchButton: some View {
        Button {
            withAnimation(.bouncy) {
                createFlow = .none
                isFilterExpanded = false
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
            if isFilterExpanded {
                VStack(spacing: 12) {
                    ForEach(sortedFilterOptions, id: \.kind) { option in
                        let isActive = option.kind == viewModel.activeFilterKind
                        Button {
                            viewModel.applyFilter(option.kind)
                            haptics.fire(.selection)
                            withAnimation(.bouncy) {
                                isFilterExpanded = false
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
            } else {
                Button {
                    withAnimation(.bouncy) {
                        createFlow = .none
                        isFilterExpanded = true
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
            if isAddExpanded {
                Button {
                    withAnimation(.bouncy) { createFlow = .none }
                    createFlow = .importingPhoto
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
                    withAnimation(.bouncy) { createFlow = .none }
                    createFlow = .composingText
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
                        withAnimation(.bouncy) { createFlow = .none }
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
            }

            Button {
                withAnimation(.bouncy) {
                    isFilterExpanded = false
                    createFlow = isAddExpanded ? .none : .menuExpanded
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

        let result: Result<String, ClipboardError>

        switch content {
        case let .image(image):
            guard let data = image.pngData() else {
                appState.showToast(.addFailed(String(localized: "Could not read image data")))
                return
            }
            let thumbnail = image.preparingThumbnail(of: CGSize(width: 200, height: 200))?.jpegData(
                compressionQuality: 0.7
            )
            result = await appState.saveImage(
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
            appState.showToast(.addSucceeded)
            appState.refreshFeed()
        case let .failure(error):
            haptics.fire(.destructive)
            appState.showToast(.addFailed(error.localizedDescription))
        }
    }

    // MARK: - Import photo

    private func importPhoto(from item: PhotosPickerItem) async {
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
