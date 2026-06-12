import ClipKittyRust
import ClipKittyShared
import SwiftUI

struct HomeFeedView: View {
    @Environment(AppState.self) private var appState
    @Environment(BrowserViewModel.self) private var viewModel

    #if ENABLE_ICLOUD_SYNC
        @Environment(iOSSyncCoordinator.self) private var syncCoordinator: iOSSyncCoordinator?
    #endif

    @State private var isSearchActive = false
    @State private var previewItemId: String?
    @State private var hasAppeared = false
    @State private var showSettings = false
    @State private var searchFocusRequestID = 0

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                feedContent
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: 72)
                    }

                BottomControlBar(
                    isSearchActive: $isSearchActive,
                    searchFocusRequestID: searchFocusRequestID
                )
            }
            .navigationTitle("ClipKitty")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $previewItemId) { itemId in
                PreviewScreen(itemId: itemId)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsScreen()
            }
            .onAppear {
                guard !hasAppeared else { return }
                hasAppeared = true
                viewModel.onAppear(
                    initialSearchQuery: "",
                    contentRevision: appState.contentRevision
                )
            }
            .onChange(of: appState.contentRevision) { _, newValue in
                viewModel.handlePanelVisibilityChange(true, contentRevision: newValue)
            }
            .onChange(of: previewItemId) { oldValue, newValue in
                guard oldValue != nil, newValue == nil, isSearchActive else { return }
                searchFocusRequestID += 1
            }
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
                CardView(
                    row: row,
                    previewItemId: $previewItemId
                )
                .onAppear {
                    loadMatchedExcerptIfNeeded(for: row)
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await refreshFeed()
        }
    }

    /// Filter out file items — iPhone app doesn't support file sharing.
    private var filteredRows: [DisplayRow] {
        viewModel.displayRows.filter { row in
            if case .symbol(.file) = row.metadata.icon { return false }
            return true
        }
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
        ScrollView {
            emptyStateContent
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical)
        }
        .scrollContentBackground(.hidden)
        .refreshable {
            await refreshFeed()
        }
    }

    private var emptyStateContent: some View {
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

    private var isSearchOrFilterActive: Bool {
        !viewModel.searchText.isEmpty
            || viewModel.contentTypeFilter != .all
            || viewModel.selectedTagFilter != nil
    }

    private func loadMatchedExcerptIfNeeded(for row: DisplayRow) {
        viewModel.loadMatchedExcerptsForItems([row.id])
    }

    /// Pull-to-refresh: kick an immediate iCloud sync cycle when sync is
    /// available, then always requery the local store so a refresh does
    /// something even with sync disabled or the feature flag off.
    private func refreshFeed() async {
        #if ENABLE_ICLOUD_SYNC
            _ = await syncCoordinator?.performUserInitiatedSync()
        #endif
        appState.refreshFeed()
    }
}

// MARK: - QueryLoadPhase spinner helper

private extension QueryLoadPhase {
    var isSpinnerVisible: Bool {
        guard case let .running(spinnerVisible) = self else { return false }
        return spinnerVisible
    }
}
