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
                    .cardListRow()
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
                    .cardListRow()
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("feed.\(viewModel.activeFilterKind.rawValue).\(feedLoadPhase)")
        .onGeometryChange(for: FeedLayout.self) { proxy in
            FeedLayout(containerWidth: proxy.size.width)
        } action: { layout in
            feedLayout = layout
        }
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
        if case .loaded = viewModel.contentState, ImageLoadActivity.shared.isSettled {
            return "settled"
        }
        return "loading"
    }

    /// Horizontal gutter between the feed content and the screen edges,
    /// applied via list-row insets so multi-clip rows share one gutter.
    fileprivate static let feedGutter: CGFloat = 16

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

private extension View {
    /// Shared list-row chrome for feed rows: no separator, card gutters via
    /// insets, transparent background.
    func cardListRow() -> some View {
        listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: 6,
                leading: HomeFeedView.feedGutter,
                bottom: 6,
                trailing: HomeFeedView.feedGutter
            ))
            .listRowBackground(Color.clear)
    }
}

// MARK: - QueryLoadPhase spinner helper

private extension QueryLoadPhase {
    var isSpinnerVisible: Bool {
        guard case let .running(spinnerVisible) = self else { return false }
        return spinnerVisible
    }
}
