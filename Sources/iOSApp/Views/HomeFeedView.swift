import ClipKittyRust
import ClipKittyShared
import SwiftUI

struct HomeFeedView: View {
    @Environment(AppState.self) private var appState
    @Environment(BrowserViewModel.self) private var viewModel

    @State private var isSearchActive = false
    @State private var previewItemId: String?
    @State private var editItemId: String?
    @State private var hasAppeared = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                feedContent
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: 72)
                    }

                BottomControlBar(
                    isSearchActive: $isSearchActive
                )
            }
            .overlay(alignment: .bottom) {
                toastOverlay
                    .padding(.bottom, 80)
            }
            .navigationDestination(item: $previewItemId) { itemId in
                PreviewScreen(itemId: itemId)
            }
            .sheet(isPresented: Binding(
                get: { editItemId != nil },
                set: { if !$0 { editItemId = nil } }
            )) {
                if let itemId = editItemId {
                    EditView(itemId: itemId)
                }
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
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(filteredRows) { row in
                    CardView(
                        row: row,
                        previewItemId: $previewItemId,
                        editItemId: $editItemId
                    )
                    .onAppear {
                        loadDecorationsIfNeeded(for: row)
                    }
                }
            }
            .padding(.vertical, 12)
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
        VStack(spacing: 16) {
            Spacer()

            if isSearchOrFilterActive {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No results found")
                    .font(.title3.weight(.semibold))
                Text("Try adjusting your search or filters")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "clipboard")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No items yet")
                    .font(.title3.weight(.semibold))
                Text("Copy something to get started, or tap + to add manually")
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
            Text("Something went wrong")
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
        if let toast = appState.toastMessage {
            GlassEffectContainer {
                HStack(spacing: 10) {
                    Image(systemName: toast.iconSystemName)
                        .font(.subheadline.weight(.medium))
                    Text(toast.text)
                        .font(.subheadline.weight(.medium))

                    if let actionTitle = toast.actionTitle, let action = appState.toastAction {
                        Button {
                            action()
                            withAnimation(.bouncy) {
                                appState.toastMessage = nil
                                appState.toastAction = nil
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
}

// MARK: - QueryLoadPhase spinner helper

private extension QueryLoadPhase {
    var isSpinnerVisible: Bool {
        guard case let .running(spinnerVisible) = self else { return false }
        return spinnerVisible
    }
}
