import ClipKittyBrowser
import ClipKittyRust
import SwiftUI
import UIKit

struct HomeFeedView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var appState
    @Environment(BrowserViewModel.self) private var viewModel
    @Environment(HapticsClient.self) private var haptics
    @Environment(iOSSettingsStore.self) private var settings
    @Environment(\.dockedKeyboardInset) private var dockedKeyboardInset

    @State private var isSearchActive = false
    @State private var previewItemId: String?
    @State private var hasAppeared = false
    @State private var showSettings = false
    @State private var showPermissionFlow = false
    @State private var permissionFlowResumesInDoneState = false
    @State private var searchFocusRequestID = 0
    @State private var feedLayout: FeedLayout = .singleColumn
    @State private var selection = FeedSelectionState()
    @State private var showDeleteConfirmation = false
    @State private var bulkCopyTask: Task<Void, Never>?
    @State private var bulkCopyRequestID: UUID?
    @State private var bulkShareTask: Task<Void, Never>?
    @State private var bulkShareRequestID: UUID?
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
                        Color.clear.frame(height: 72 + dockedKeyboardInset)
                    }

                if selection.isActive {
                    FeedSelectionActionBar(
                        selectedItemIDs: orderedSelectedItemIDs,
                        allSelectedAreBookmarked: allSelectedAreBookmarked,
                        isCopying: isBulkCopying,
                        onCopy: copySelectedItems,
                        onToggleBookmark: toggleBookmarkForSelectedItems,
                        onShare: shareSelectedItems,
                        onDelete: { showDeleteConfirmation = true }
                    )
                    .padding(.bottom, dockedKeyboardInset)
                } else {
                    BottomControlBar(
                        isSearchActive: $isSearchActive,
                        searchFocusRequestID: searchFocusRequestID
                    )
                    .padding(.bottom, dockedKeyboardInset)
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $previewItemId) { itemId in
                PreviewScreen(itemId: itemId)
            }
            .toolbar {
                if selection.isActive {
                    selectionToolbarContent
                } else {
                    defaultToolbarContent
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsScreen()
            }
            .sheet(isPresented: $showPermissionFlow) {
                SaveAutomaticallySheet(resumeInDoneState: permissionFlowResumesInDoneState)
            }
            .onChange(of: showPermissionFlow) { _, isPresented in
                if !isPresented {
                    permissionFlowResumesInDoneState = false
                }
            }
            .onAppear {
                guard !hasAppeared else { return }
                hasAppeared = true
                // A trip to the Settings app from the permission flow comes
                // back through a rebootstrapped session with all sheets gone;
                // pick the flow back up on its finishing step.
                if settings.permissionFlowResumePending {
                    settings.permissionFlowResumePending = false
                    if !settings.permissionHintDismissed {
                        permissionFlowResumesInDoneState = true
                        showPermissionFlow = true
                    }
                }
                viewModel.onAppear(
                    initialSearchQuery: "",
                    contentRevision: appState.contentRevision
                )
            }
            .onChange(of: visibleItemIDs) { _, newValue in
                cancelBulkCopy()
                selection.reconcile(with: newValue)
            }
            .onChange(of: previewItemId) { oldValue, newValue in
                guard oldValue != nil, newValue == nil, isSearchActive else { return }
                searchFocusRequestID += 1
            }
            .alert(
                String(localized: "Delete Selected Items?"),
                isPresented: $showDeleteConfirmation
            ) {
                Button(String(localized: "Delete"), role: .destructive) {
                    deleteSelectedItems()
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "Are you sure you want to delete the selected items?"))
            }
            .onDisappear {
                cancelBulkCopy()
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
            } else {
                switch phase {
                case .runningShowingSpinner:
                    loadingView
                case .debouncing, .runningWaitingForSpinner:
                    Color.clear
                }
            }

        case .loaded:
            if filteredRows.isEmpty {
                emptyFeed
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

    /// A ScrollView rather than a List on purpose: List attaches context-menu
    /// and drag interactions to the whole UICollectionView cell, so in packed
    /// rows a long press lifted every card in the row at once and a drag
    /// carried the row, not the card. Outside a List each CardView owns its
    /// own interactions.
    private var scrollableFeed: some View {
        ScrollView {
            feedRows
        }
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

    /// Whether the clipboard-permission card tops the feed. Hidden during
    /// selection: the card is not selectable and would sit above the
    /// checkable clips.
    private var showsPermissionCard: Bool {
        !settings.permissionHintDismissed && !selection.isActive
    }

    private var permissionCard: some View {
        ClipboardPermissionCard {
            showPermissionFlow = true
        }
    }

    /// The loaded-but-empty screen. The permission card still tops it — a
    /// fresh install has no clips yet, and that first-run user is exactly who
    /// the card is for — except while a search or filter is active, where
    /// "no results" is the whole story.
    private var emptyFeed: some View {
        VStack(spacing: 0) {
            if showsPermissionCard, !isSearchOrFilterActive {
                permissionCard
                    .padding(.horizontal, Self.feedGutter)
                    .padding(.top, Self.feedRowSpacing / 2)
            }
            emptyStateView
        }
    }

    private var feedRows: some View {
        LazyVStack(spacing: Self.feedRowSpacing) {
            if showsPermissionCard {
                permissionCard
            }

            switch feedLayout {
            case .singleColumn:
                ForEach(filteredRows) { row in
                    feedCard(for: row)
                        .onAppear {
                            viewModel.loadMatchedExcerptsForItems([row.id])
                        }
                }

            case let .packedRows(rowWidth):
                ForEach(CardRowChunk.pack(filteredRows, rowWidth: rowWidth)) { chunk in
                    JustifiedCardRow {
                        ForEach(chunk.rows) { row in
                            feedCard(for: row)
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

    private var visibleItemIDs: [String] {
        filteredRows.map(\.id)
    }

    private var orderedSelectedItemIDs: [String] {
        selection.orderedSelectedItemIDs(in: visibleItemIDs)
    }

    /// Whether every selected item already carries the bookmark tag. Only
    /// visible rows are consulted, matching `orderedSelectedItemIDs`; a
    /// selection is never non-empty without visible rows to back it.
    private var allSelectedAreBookmarked: Bool {
        let selectedIDs = Set(orderedSelectedItemIDs)
        guard !selectedIDs.isEmpty else { return false }
        return filteredRows
            .filter { selectedIDs.contains($0.id) }
            .allSatisfy { $0.metadata.tags.contains(.bookmark) }
    }

    private var navigationTitle: String {
        guard selection.isActive else { return "ClipKitty" }
        return String.localizedStringWithFormat(
            String(localized: "%lld Selected"),
            Int64(selection.selectedCount)
        )
    }

    /// Split out of `.toolbar { }` so the type checker evaluates each branch
    /// separately instead of one combined `if`/`else` builder expression.
    @ToolbarContentBuilder
    private var selectionToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(
                selection.areAllSelected(in: visibleItemIDs)
                    ? String(localized: "Deselect All")
                    : String(localized: "Select All")
            ) {
                toggleAllVisibleItems()
            }
            .disabled(visibleItemIDs.isEmpty)
            .accessibilityIdentifier("selection.selectAllButton")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(String(localized: "Done")) {
                withAnimation(.bouncy) {
                    cancelSelection()
                }
            }
            .accessibilityIdentifier("selection.doneButton")
        }
    }

    @ToolbarContentBuilder
    private var defaultToolbarContent: some ToolbarContent {
        #if ENABLE_ICLOUD_SYNC
            ToolbarItem(placement: .topBarLeading) {
                SyncStatusButton()
            }
        #endif
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    withAnimation(.bouncy) {
                        selection.beginSelection()
                    }
                } label: {
                    Label(String(localized: "Select"), systemImage: "checkmark.circle")
                }
                .disabled(filteredRows.isEmpty)
                .accessibilityIdentifier("home.selectMenuItem")

                Button {
                    showSettings = true
                } label: {
                    Label(String(localized: "Settings"), systemImage: "gearshape")
                }
                .accessibilityIdentifier("home.settingsMenuItem")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityIdentifier("home.overflowMenuButton")
        }
    }

    private func feedCard(for row: DisplayRow) -> some View {
        CardView(
            row: row,
            previewItemId: $previewItemId,
            isSelectionMode: selection.isActive,
            isSelected: selection.selectedItemIDs.contains(row.id),
            onToggleSelection: {
                cancelBulkCopy()
                selection.toggleSelection(for: row.id)
            }
        )
    }

    private func toggleAllVisibleItems() {
        cancelBulkCopy()
        if selection.areAllSelected(in: visibleItemIDs) {
            selection.deselectAll()
        } else {
            selection.selectAll(in: visibleItemIDs)
        }
        haptics.fire(.selection)
    }

    private func copySelectedItems() {
        let itemIDs = orderedSelectedItemIDs
        guard !itemIDs.isEmpty, !isBulkCopying else { return }
        guard iOSTransferLimits.validateItemCount(itemIDs.count) == nil else {
            showTransferItemLimitExceeded()
            return
        }

        let requestID = UUID()
        bulkCopyRequestID = requestID

        let task = Task { @MainActor in
            defer { finishBulkCopy(requestID: requestID) }
            guard !Task.isCancelled else { return }
            let result = await container.repository.fetchTransferItems(ids: itemIDs)
            guard !Task.isCancelled,
                  selection.isActive,
                  orderedSelectedItemIDs == itemIDs
            else { return }

            switch result {
            case let .success(items):
                guard items.map(\.itemMetadata.itemId) == itemIDs else {
                    showBulkCopyFailure(String(localized: "Could not load item"))
                    selection.reconcile(with: visibleItemIDs)
                    return
                }
                let copied = await container.clipboardService.copy(contents: items.map(\.content))
                guard !Task.isCancelled,
                      bulkCopyRequestID == requestID,
                      selection.isActive,
                      orderedSelectedItemIDs == itemIDs
                else { return }
                guard copied else {
                    showBulkCopyFailure(String(localized: "Could not load item"))
                    selection.reconcile(with: visibleItemIDs)
                    return
                }

                haptics.fire(.copy)
                appState.showToast(.copied)

            case let .rejected(reason):
                switch reason {
                case .tooManyItems:
                    showTransferItemLimitExceeded()
                case .textTooLarge, .imageTooLarge, .aggregateTooLarge:
                    showBulkCopyFailure(
                        String(localized: "The selected items are too large to copy or drag together.")
                    )
                case .duplicateItemId, .missingItem:
                    showBulkCopyFailure(String(localized: "Could not load item"))
                    selection.reconcile(with: visibleItemIDs)
                }

            case .cancelled:
                return

            case .failure:
                showBulkCopyFailure(String(localized: "Could not load item"))
                selection.reconcile(with: visibleItemIDs)
            }
        }
        bulkCopyTask = task
        guard appState.registerForegroundTask(id: requestID, task: task) else {
            cancelBulkCopy()
            return
        }
    }

    private func showBulkCopyFailure(_ message: String) {
        haptics.fire(.destructive)
        appState.showToast(.addFailed(message))
    }

    /// Bookmarks the whole selection, or removes the bookmark if every
    /// selected item already carries it.
    ///
    /// Goes through the view model's batch tag mutation, which applies the
    /// whole selection as one transaction and updates the affected rows in
    /// place. Writing to the repository directly and then calling
    /// `refreshFeed()` would restart the search, discarding the feed's caches
    /// and scrolling the user back to the top for what is only a tag change.
    private func toggleBookmarkForSelectedItems() {
        let itemIDs = orderedSelectedItemIDs
        guard !itemIDs.isEmpty else { return }
        let shouldInclude = !allSelectedAreBookmarked

        viewModel.setTag(.bookmark, onItems: itemIDs, shouldInclude: shouldInclude)
        haptics.fire(.selection)
        appState.showToast(shouldInclude ? .bookmarked : .unbookmarked)
    }

    private func shareSelectedItems() {
        let itemIDs = orderedSelectedItemIDs
        guard !itemIDs.isEmpty, bulkShareTask == nil else { return }
        guard iOSTransferLimits.validateItemCount(itemIDs.count) == nil else {
            showTransferItemLimitExceeded()
            return
        }

        let requestID = UUID()
        bulkShareRequestID = requestID

        let task = Task { @MainActor in
            defer { finishBulkShare(requestID: requestID) }
            guard !Task.isCancelled else { return }
            let result = await container.repository.fetchTransferItems(ids: itemIDs)
            guard !Task.isCancelled, bulkShareRequestID == requestID else { return }

            switch result {
            case let .success(items):
                guard items.map(\.itemMetadata.itemId) == itemIDs else {
                    showBulkCopyFailure(String(localized: "Could not load item"))
                    selection.reconcile(with: visibleItemIDs)
                    return
                }
                let payloads = await withTaskGroup(of: (Int, PreparedSharePayload?).self) { group in
                    for (index, item) in items.enumerated() {
                        group.addTask { (index, await SharePresenter.prepare(item: item)) }
                    }
                    var prepared = [PreparedSharePayload?](repeating: nil, count: items.count)
                    for await(index, payload) in group {
                        prepared[index] = payload
                    }
                    return prepared.compactMap { $0 }
                }
                guard !Task.isCancelled, bulkShareRequestID == requestID else { return }
                guard !payloads.isEmpty else {
                    showBulkCopyFailure(String(localized: "Could not load item"))
                    return
                }
                SharePresenter.present(payloads: payloads)

            case let .rejected(reason):
                switch reason {
                case .tooManyItems:
                    showTransferItemLimitExceeded()
                case .textTooLarge, .imageTooLarge, .aggregateTooLarge:
                    showBulkCopyFailure(
                        String(localized: "The selected items are too large to copy or drag together.")
                    )
                case .duplicateItemId, .missingItem:
                    showBulkCopyFailure(String(localized: "Could not load item"))
                    selection.reconcile(with: visibleItemIDs)
                }

            case .cancelled:
                return

            case .failure:
                showBulkCopyFailure(String(localized: "Could not load item"))
                selection.reconcile(with: visibleItemIDs)
            }
        }
        bulkShareTask = task
        guard appState.registerForegroundTask(id: requestID, task: task) else {
            cancelBulkShare()
            return
        }
    }

    private func cancelBulkShare() {
        bulkShareRequestID = nil
        bulkShareTask?.cancel()
        bulkShareTask = nil
    }

    private func finishBulkShare(requestID: UUID) {
        appState.finishForegroundTask(id: requestID)
        guard bulkShareRequestID == requestID else { return }
        bulkShareRequestID = nil
        bulkShareTask = nil
    }

    private func deleteSelectedItems() {
        let itemIDs = orderedSelectedItemIDs
        cancelBulkCopy()
        guard viewModel.deleteItems(itemIds: itemIDs) else { return }
        selection.cancelSelection()
        haptics.fire(.destructive)
    }

    private var isBulkCopying: Bool {
        bulkCopyTask != nil
    }

    private func cancelSelection() {
        cancelBulkCopy()
        selection.cancelSelection()
    }

    private func cancelBulkCopy() {
        bulkCopyRequestID = nil
        bulkCopyTask?.cancel()
        bulkCopyTask = nil
    }

    private func finishBulkCopy(requestID: UUID) {
        appState.finishForegroundTask(id: requestID)
        guard bulkCopyRequestID == requestID else { return }
        bulkCopyRequestID = nil
        bulkCopyTask = nil
    }

    private func showTransferItemLimitExceeded() {
        haptics.fire(.destructive)
        let message = String.localizedStringWithFormat(
            String(localized: "Copy or drag up to %lld items at a time."),
            Int64(iOSTransferLimits.maximumItemCount)
        )
        appState.showToast(.addFailed(message))
    }

    @MainActor
    private func makeExternalDragPayload(itemIDs: [String]) -> ExternalCopyDragPayload {
        var iconsByItemID: [String: ItemIcon] = [:]
        for row in filteredRows where iconsByItemID[row.id] == nil {
            iconsByItemID[row.id] = row.metadata.icon
        }
        let descriptors = itemIDs.compactMap { itemID in
            iconsByItemID[itemID].map {
                ExternalCopyDragItemDescriptor(itemID: itemID, icon: $0)
            }
        }
        guard descriptors.count == itemIDs.count else {
            return ExternalCopyDragPayload(items: [])
        }

        let repository = container.repository
        return ExternalCopyDragPayload(
            descriptors: descriptors,
            // Multi-item drag uses the UIKit delegate path, so its lazy store
            // fetch can remain available after a full-screen external drop.
            // A denied UIKit reservation is intentionally non-fatal: providers
            // still work while the foreground store remains available and any
            // failed transfer retains its source item.
            externalTransferLease: appState.beginExternalTransfer(),
            fetchItem: { id in
                await repository.fetchTransferItem(id: id)
            }
        )
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
