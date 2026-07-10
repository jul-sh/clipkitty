import ClipKittyRust
import ClipKittyShared
import SwiftUI

struct HomeFeedView: View {
    @Environment(AppState.self) private var appState
    @Environment(BrowserViewModel.self) private var viewModel

    @State private var isSearchActive = false
    @State private var previewItemId: String?
    @State private var hasAppeared = false
    @State private var showSettings = false
    @State private var searchFocusRequestID = 0
    @State private var feedLayout: FeedLayout = .singleColumn
    /// Cards currently drawing an image placeholder; see
    /// `PendingImagePlaceholderCount` and `feedLoadPhase`.
    @State private var pendingImagePlaceholders = 0

    /// How the feed arranges clips, derived from the window geometry. The
    /// packed case carries the row width it was derived from, so packing can
    /// never run against a stale or unset width.
    ///
    /// Chosen purely by window width, never by device idiom: a full-screen
    /// iPad and a hypothetical extra-wide iPhone (or a landscape Max-class
    /// one) get the same packed rows, and an iPad squeezed into a narrow
    /// Split View column reads like an iPhone.
    private enum FeedLayout: Equatable {
        /// One clip per row: windows narrower than
        /// `JustifiedCardRow.multiColumnMinimumWidth`.
        case singleColumn
        /// Up to `JustifiedCardRow.maxCardsPerRow` clips share each row:
        /// full-screen iPads, spacious Split View / Stage Manager windows,
        /// and any other window at least `multiColumnMinimumWidth` wide.
        case packedRows(rowWidth: CGFloat)

        init(containerWidth: CGFloat) {
            if containerWidth >= JustifiedCardRow.multiColumnMinimumWidth {
                self = .packedRows(rowWidth: containerWidth - 2 * HomeFeedView.feedGutter)
            } else {
                self = .singleColumn
            }
        }
    }

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
            // The title still names the screen (and labels the back button on
            // pushed screens), but the bar itself is hidden: the ClipKitty
            // header lives inside the feed (`feedHeader`) so it scrolls away
            // with the content instead of floating over it.
            .navigationTitle("ClipKitty")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $previewItemId) { itemId in
                PreviewScreen(itemId: itemId)
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
            staticState { Color.clear }

        case let .loading(_, previous, phase):
            if previous != nil {
                scrollableFeed
            } else if phase.isSpinnerVisible {
                staticState { loadingView }
            } else {
                staticState { Color.clear }
            }

        case .loaded:
            if filteredRows.isEmpty {
                staticState { emptyStateView }
            } else {
                scrollableFeed
            }

        case let .failed(_, message, previous):
            if previous != nil {
                scrollableFeed
            } else {
                staticState { failedView(message: message) }
            }
        }
    }

    /// The ClipKitty header: part of the feed content, not a pinned bar, so
    /// it sits at the top of the list and hides as you scroll down.
    private var feedHeader: some View {
        ZStack {
            Text("ClipKitty")
                .font(.headline)

            HStack {
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        // Color.primary, not the hierarchical .primary: inside
                        // a button the hierarchy is rooted at the tint, so the
                        // shorthand stays accent blue.
                        .foregroundStyle(Color.primary)
                }
                .accessibilityLabel(String(localized: "Settings"))
            }
        }
        .padding(.horizontal, Self.feedGutter)
        .padding(.vertical, 10)
    }

    /// Non-scrolling states (spinner, empty, failed) keep the same header at
    /// the top so the screen doesn't lose its title and Settings access.
    private func staticState(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            feedHeader
            content()
        }
    }

    /// A ScrollView rather than a List on purpose: List attaches context-menu
    /// and drag interactions to the whole UICollectionView cell, so in packed
    /// rows a long press lifted every card in the row at once and a drag
    /// carried the row, not the card. Outside a List each CardView owns its
    /// own interactions.
    private var scrollableFeed: some View {
        ScrollView {
            VStack(spacing: 0) {
                feedHeader
                feedRows
            }
        }
        // With the navigation bar gone there is no bar for the system to
        // anchor a scroll edge effect to, so scrolled content collides with
        // the status bar clock. An empty safe-area bar recreates the effect
        // region: content softly fades out under the status bar.
        .safeAreaBar(edge: .top, spacing: 0) {
            Color.clear.frame(height: 0)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onPreferenceChange(PendingImagePlaceholderCount.self) { count in
            pendingImagePlaceholders = count
        }
        .accessibilityIdentifier("feed.\(viewModel.activeFilterKind.rawValue).\(feedLoadPhase)")
        .onGeometryChange(for: FeedLayout.self) { proxy in
            FeedLayout(containerWidth: proxy.size.width)
        } action: { layout in
            feedLayout = layout
        }
    }

    private var feedRows: some View {
        LazyVStack(spacing: Self.feedRowSpacing) {
            switch feedLayout {
            case .singleColumn:
                ForEach(filteredRows) { row in
                    CardView(
                        row: row,
                        previewItemId: $previewItemId
                    )
                    .onAppear {
                        viewModel.loadMatchedExcerptsForItems([row.id])
                    }
                }

            case let .packedRows(rowWidth):
                ForEach(CardRowChunk.pack(filteredRows, rowWidth: rowWidth)) { chunk in
                    JustifiedCardRow {
                        ForEach(chunk.rows) { row in
                            CardView(
                                row: row,
                                previewItemId: $previewItemId
                            )
                        }
                    }
                    .onAppear {
                        viewModel.loadMatchedExcerptsForItems(chunk.rows.map(\.id))
                    }
                }
            }
        }
        .padding(.horizontal, Self.feedGutter)
        .padding(.vertical, Self.feedRowSpacing / 2)
    }

    /// Load-state signal for UI automation, the iOS counterpart of the Mac's
    /// `ResultsState_<kind>_<phase>` identifier: the feed list is tagged
    /// `feed.<filterKind>.<loading|settled>`, where `settled` means the
    /// current filter's query has loaded AND every in-flight card image
    /// fetch/decode has finished — a capture taken then cannot ship
    /// placeholder or stale-thumbnail cards. Keying on the filter kind
    /// matters: right after a filter is applied the feed still shows the
    /// previous (already settled) rows, and a kind-less signal would read
    /// "settled" before the filtered content even arrived. Marketing
    /// screenshot runs wait on this instead of guessing at sleeps.
    private var feedLoadPhase: String {
        if case .loaded = viewModel.contentState,
           ImageLoadActivity.shared.isSettled,
           // Cards drawing a placeholder count as loading even before their
           // fetch/decode tasks have started (the tasks are what drive
           // ImageLoadActivity, and they run a frame after first draw).
           pendingImagePlaceholders == 0
        {
            return "settled"
        }
        return "loading"
    }

    /// Horizontal gutter between the feed content and the screen edges,
    /// shared by every feed row so multi-clip rows line up with single cards.
    fileprivate static let feedGutter: CGFloat = 16

    /// Vertical spacing between feed rows.
    private static let feedRowSpacing: CGFloat = 12

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
        !viewModel.searchText.isEmpty || viewModel.activeFilterKind != .all
    }
}

// MARK: - QueryLoadPhase spinner helper

private extension QueryLoadPhase {
    var isSpinnerVisible: Bool {
        guard case let .running(spinnerVisible) = self else { return false }
        return spinnerVisible
    }
}
