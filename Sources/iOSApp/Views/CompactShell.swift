import ClipKittyRust
import ClipKittyShared
import SwiftUI

/// iPhone-style single-column navigation shell. Preserves all existing compact behavior.
struct CompactShell: View {
    @Environment(SceneState.self) private var sceneState
    @Environment(BrowserViewModel.self) private var viewModel
    @Environment(HapticsClient.self) private var haptics

    @State private var hasAppeared = false

    var body: some View {
        @Bindable var sceneState = sceneState

        NavigationStack {
            ZStack(alignment: .bottom) {
                feedContent
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: 72)
                    }

                BottomControlBar(
                    isSearchActive: Binding(
                        get: { sceneState.chromeState == .searching },
                        set: { sceneState.chromeState = $0 ? .searching : .idle }
                    )
                )
            }
            .navigationTitle("ClipKitty")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $sceneState.previewItemId) { itemId in
                PreviewScreen(itemId: itemId)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        sceneState.modalRoute = .settings
                    } label: {
                        Image(systemName: "gearshape")
                    }
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
            .onAppear {
                guard !hasAppeared else { return }
                hasAppeared = true
                viewModel.onAppear(
                    initialSearchQuery: "",
                    contentRevision: sceneState.contentRevision
                )
                consumePendingDeepLink()
            }
            .onChange(of: sceneState.contentRevision) { _, newValue in
                viewModel.handlePanelVisibilityChange(true, contentRevision: newValue)
            }
            .onChange(of: sceneState.router.pendingDeepLink) { _, _ in
                consumePendingDeepLink()
            }
        }
        .overlay(alignment: .bottom) {
            toastOverlay
                .padding(.bottom, 80)
        }
    }

    @ViewBuilder
    private var feedContent: some View {
        switch viewModel.contentState {
        case .idle:
            Color.clear

        case let .loading(_, previous, phase):
            if previous != nil {
                scrollableFeed
            } else if phase.isSpinnerVisible {
                loadingView
            } else {
                Color.clear
            }

        case .loaded:
            if filteredRows.isEmpty {
                emptyStateView
            } else {
                scrollableFeed
            }

        case let .failed(_, message, previous):
            if previous != nil {
                scrollableFeed
            } else {
                failedView(message: message)
            }
        }
    }

    private var scrollableFeed: some View {
        List {
            ForEach(filteredRows) { row in
                CardView(row: row)
                .onAppear {
                    loadDecorationsIfNeeded(for: row)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        sceneState.previewItemId = row.metadata.itemId
                        haptics.fire(.selection)
                    } label: {
                        Label("Preview", systemImage: "eye")
                    }
                    .tint(.blue)
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// Filter out file items on iPhone — compact mode on phone doesn't support file sharing.
    /// iPad in compact mode (Split View narrow) still supports files.
    private var filteredRows: [DisplayRow] {
        if UIDevice.current.userInterfaceIdiom == .phone {
            return viewModel.displayRows.filter { row in
                if case .symbol(.file) = row.metadata.icon { return false }
                return true
            }
        }
        return viewModel.displayRows
    }

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

    private func loadDecorationsIfNeeded(for row: DisplayRow) {
        if row.listDecoration == nil {
            viewModel.loadListDecorationsForItems([row.id])
        }
    }

    private func consumePendingDeepLink() {
        guard let deepLink = sceneState.router.pendingDeepLink else { return }
        sceneState.modalRoute = nil
        sceneState.previewItemId = nil
        switch deepLink {
        case let .search(query):
            sceneState.chromeState = .searching
            viewModel.updateSearchText(query)
        case .newItem:
            sceneState.modalRoute = .compose
        }
        sceneState.router.pendingDeepLink = nil
    }
}

// MARK: - QueryLoadPhase spinner helper

extension QueryLoadPhase {
    var isSpinnerVisible: Bool {
        guard case let .running(spinnerVisible) = self else { return false }
        return spinnerVisible
    }
}
