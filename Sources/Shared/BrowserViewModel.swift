import ClipKittyRust
import Foundation
import Observation
import os.signpost

private let poi = OSLog(subsystem: "com.eviljuliette.clipkitty", category: .pointsOfInterest)

@MainActor
@Observable
public final class BrowserViewModel {
    private let client: BrowserStoreClient
    private let filterCatalog: BrowserFilterCatalog
    private let shouldGenerateLinkPreviews: @MainActor () -> Bool
    private let onSelect: (String, ClipboardContent) -> Void
    private let onCopyOnly: (String, ClipboardContent) -> Void
    private let onDismiss: () -> Void
    private let showSnackbarNotification: (NotificationKind, (() -> Void)?) -> Void
    private let dismissSnackbarNotification: () -> Void
    /// How long a pending delete stays undoable before committing; injectable
    /// so tests don't have to wait out the real undo window.
    private let deleteCommitDelay: TimeInterval
    /// How long the user must pause typing before a new filter suggestion
    /// surfaces; injectable so tests don't race the real delay.
    private let pendingFilterSurfaceDelay: TimeInterval

    private enum SearchExecution {
        case idle
        case debouncing(request: SearchRequest, targetContentRevision: Int, task: Task<Void, Never>)
        case running(
            id: UUID,
            request: SearchRequest,
            targetContentRevision: Int,
            operation: BrowserSearchOperation,
            observer: Task<Void, Never>,
            spinner: Task<Void, Never>?
        )

        var id: UUID? {
            guard case let .running(id, _, _, _, _, _) = self else { return nil }
            return id
        }

        var request: SearchRequest? {
            switch self {
            case .idle:
                return nil
            case let .debouncing(request, _, _), let .running(_, request, _, _, _, _):
                return request
            }
        }

        var targetContentRevision: Int? {
            switch self {
            case .idle:
                return nil
            case let .debouncing(_, targetContentRevision, _), let .running(_, _, targetContentRevision, _, _, _):
                return targetContentRevision
            }
        }

        mutating func cancel() {
            switch self {
            case .idle:
                break
            case let .debouncing(_, _, task):
                task.cancel()
            case let .running(_, _, _, operation, observer, spinner):
                operation.cancel()
                observer.cancel()
                spinner?.cancel()
            }
            self = .idle
        }
    }

    private var searchExecution: SearchExecution = .idle
    private var previewTask: Task<Void, Never>?
    #if ENABLE_LINK_PREVIEWS
        private var metadataTask: Task<Void, Never>?
    #endif
    private var matchedExcerptTasks: [String: Task<Void, Never>] = [:]
    private var pendingMatchedExcerptItemIds: Set<String> = []
    private var prefetchTask: Task<Void, Never>?
    private var previewSpinnerTask: Task<Void, Never>?
    private var pendingFilterSurfaceTask: Task<Void, Never>?
    private var pendingDeleteTask: Task<Void, Never>?
    private var pendingTagSettleTask: Task<Void, Never>?
    private var queryGeneration = 0
    private var previewGeneration = 0
    #if ENABLE_LINK_PREVIEWS
        private var metadataGeneration = 0
    #endif
    private var hasAppliedInitialSearch = false
    private var latestKnownContentRevision = 0
    private var lastLoadedContentRevision: Int?

    public private(set) var contentState: BrowserContentState = .idle(request: SearchRequest(text: "", filter: .all))
    public private(set) var selectionState: SelectionState = .none
    public private(set) var overlayState: OverlayState = .none
    public private(set) var pendingFilterState: PendingFilterState = .none
    public private(set) var mutationState: MutationState = .idle
    public private(set) var editSession: PreviewEditSession = .inactive
    public private(set) var resolvedMatchedExcerptsByItemId: [String: MatchedExcerpt] = [:]
    private var previewPayloadsByItemId: [String: PreviewPayload] = [:]
    public private(set) var hasUserNavigated = false
    public private(set) var prefetchCache: [String: ClipboardItem] = [:]
    public private(set) var previewSpinnerVisible = false
    public private(set) var itemIds: [String] = []
    public private(set) var displayRows: [DisplayRow] = []
    private var itemIndexById: [String: Int] = [:]

    public init(
        client: BrowserStoreClient,
        filterCatalog: BrowserFilterCatalog = BrowserFilterCatalog(includesFileItems: false),
        shouldGenerateLinkPreviews: @escaping @MainActor () -> Bool = { true },
        onSelect: @escaping (String, ClipboardContent) -> Void,
        onCopyOnly: @escaping (String, ClipboardContent) -> Void,
        onDismiss: @escaping () -> Void,
        showSnackbarNotification: @escaping (NotificationKind, (() -> Void)?) -> Void = { _, _ in },
        dismissSnackbarNotification: @escaping () -> Void = {},
        deleteCommitDelay: TimeInterval = NotificationKind.undoWindow,
        pendingFilterSurfaceDelay: TimeInterval = 0.1
    ) {
        self.client = client
        self.filterCatalog = filterCatalog
        self.shouldGenerateLinkPreviews = shouldGenerateLinkPreviews
        self.onSelect = onSelect
        self.onCopyOnly = onCopyOnly
        self.onDismiss = onDismiss
        self.showSnackbarNotification = showSnackbarNotification
        self.dismissSnackbarNotification = dismissSnackbarNotification
        self.deleteCommitDelay = deleteCommitDelay
        self.pendingFilterSurfaceDelay = pendingFilterSurfaceDelay
    }

    public var searchText: String {
        contentState.request.text
    }

    /// The catalog descriptor for the active filter, or nil when browsing
    /// unfiltered. Drives the applied chip in the search bar.
    public var appliedFilterDescriptor: BrowserFilterDescriptor? {
        filterCatalog.appliedDescriptor(for: contentState.request.filter)
    }

    /// The semantic kind of the active filter; `.all` when unfiltered.
    public var activeFilterKind: BrowserFilterKind {
        appliedFilterDescriptor?.kind ?? .all
    }

    /// Filters the user can select on this platform, in display order.
    public var selectableFilters: [BrowserFilterDescriptor] {
        filterCatalog.selectableFilters
    }

    public func filterDescriptor(for kind: BrowserFilterKind) -> BrowserFilterDescriptor {
        filterCatalog.descriptor(for: kind)
    }

    public var pendingFilterSuggestion: TypedFilterSuggestion? {
        pendingFilterState.suggestion
    }

    /// What Enter and row-only shortcuts currently address. The chip owns the
    /// keyboard only while the user has arrowed up onto it.
    public var keyboardTarget: BrowserKeyboardTarget {
        if case let .suggested(suggestion, keyboardTarget: .suggestion) = pendingFilterState {
            return .pendingFilterChip(suggestion)
        }
        return .results
    }

    public var searchSpinnerVisible: Bool {
        contentState.isSearchSpinnerVisible
    }

    public func indexOfItem(_ itemId: String?) -> Int? {
        guard let itemId else { return nil }
        return itemIndexById[itemId]
    }

    public var selection: SelectionState {
        selectionState
    }

    public var selectedItemId: String? {
        selection.itemId
    }

    public var selectedItemState: SelectedItemState? {
        selection.selectedItem
    }

    public var selectedItem: ClipboardItem? {
        selectedItemState?.item
    }

    public var previewDecoration: PreviewDecoration? {
        guard let selectedItemState else { return nil }
        switch selectedItemState.previewState {
        case .plain, .loadingDecoration(previous: nil):
            return nil
        case let .loadingDecoration(previous: .some(decoration)), let .highlighted(decoration):
            return decoration
        }
    }

    public var selectedIndex: Int? {
        guard let selectedItemId else { return nil }
        return itemIndexById[selectedItemId]
    }

    public var itemCount: Int {
        itemIds.count
    }

    public var mutationFailureMessage: String? {
        guard case let .failed(failure) = mutationState else { return nil }
        return failure.message
    }

    /// Draft text for the currently-editing item, if any.
    /// Callers should prefer matching `editSession` directly.
    public var draftText: (itemId: String, text: String)? {
        if case let .dirty(itemId, draft) = editSession {
            return (itemId, draft)
        }
        return nil
    }

    public func onAppear(initialSearchQuery: String, contentRevision: Int = 0) {
        latestKnownContentRevision = max(latestKnownContentRevision, contentRevision)
        guard !hasAppliedInitialSearch else { return }
        startInitialSearch(initialSearchQuery: initialSearchQuery, targetContentRevision: latestKnownContentRevision)
    }

    public func handleDisplayReset(initialSearchQuery: String, contentRevision: Int = 0) {
        flushPendingDelete()
        cancelInFlightWork()
        latestKnownContentRevision = max(latestKnownContentRevision, contentRevision)
        lastLoadedContentRevision = nil
        hasUserNavigated = false
        prefetchCache.removeAll()
        previewPayloadsByItemId.removeAll()
        resolvedMatchedExcerptsByItemId.removeAll()
        overlayState = .none
        resetMutationStateUnlessCommitting()
        editSession = .inactive
        // Clear selection so the fresh search lands on the top item rather
        // than carrying the prior highlight across a hide/show cycle.
        setDisplayedSelection(.none)
        // Preserve displayed content so the fresh search can enter `.loading(previous:)`
        // instead of flashing the empty state while the new results are loading.
        hasAppliedInitialSearch = false
        startInitialSearch(initialSearchQuery: initialSearchQuery, targetContentRevision: contentRevision)
    }

    public func prepareForSuspension() {
        flushPendingDelete()
        cancelInFlightWork()
        dismissSnackbarNotification()
        overlayState = .none
        resetMutationStateUnlessCommitting()
        editSession = .inactive
        hasUserNavigated = false
        // A stale `.suggestion` keyboard target must not survive a hide/show
        // cycle; the suggestion itself stays valid for the request.
        if case let .suggested(suggestion, _) = pendingFilterState {
            pendingFilterState = .suggested(suggestion, keyboardTarget: .results)
        }
    }

    /// Commits any still-pending delete immediately. Called when the UI is
    /// about to reset or suspend, so an optimistic delete is never dropped on
    /// the floor with the item silently resurrecting later.
    private func flushPendingDelete() {
        guard case .deleting(.pending) = mutationState else { return }
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        commitPendingDelete()
    }

    /// `.deleting(.committing)` must survive resets: the commit task resets to
    /// `.idle` itself, and `restoreDeleteFailure` matches on it.
    private func resetMutationStateUnlessCommitting() {
        if case .deleting(.committing) = mutationState { return }
        mutationState = .idle
    }

    public func handleContentRevisionChange(_ contentRevision: Int, isPanelVisible: Bool) {
        latestKnownContentRevision = max(latestKnownContentRevision, contentRevision)
        guard !isPanelVisible else { return }
        refreshCurrentRequestIfStale()
    }

    public func handlePanelVisibilityChange(
        _ isPanelVisible: Bool,
        initialSearchQuery: String = "",
        contentRevision: Int = 0
    ) {
        latestKnownContentRevision = max(latestKnownContentRevision, contentRevision)
        guard isPanelVisible else { return }
        guard hasAppliedInitialSearch else {
            onAppear(initialSearchQuery: initialSearchQuery, contentRevision: latestKnownContentRevision)
            return
        }
        refreshCurrentRequestIfStale()
    }

    public func dismiss() {
        onDismiss()
    }

    public func updateSearchText(_ value: String) {
        submitSearch(text: value, filter: contentState.request.filter)
    }

    /// Applies a filter directly (e.g. from the iOS filter picker), keeping
    /// the current search text.
    public func applyFilter(_ kind: BrowserFilterKind) {
        submitSearch(text: searchText, filter: filterCatalog.descriptor(for: kind).queryFilter)
    }

    /// Commits the pending typed-filter suggestion: the trigger token is
    /// consumed, the rest of the query is preserved, and the filter activates.
    public func applyPendingFilterSuggestion() {
        guard case let .suggested(suggestion, _) = pendingFilterState else { return }
        submitSearch(
            text: suggestion.remainingSearchText,
            filter: filterCatalog.descriptor(for: suggestion.kind).queryFilter
        )
    }

    /// Removes the applied filter chip, restoring unfiltered search with the
    /// current text untouched.
    public func clearAppliedFilter() {
        guard contentState.request.filter != .all else { return }
        submitSearch(text: searchText, filter: .all)
    }

    public func openActionsOverlay(highlight: MenuHighlightState) {
        overlayState = .actions(highlight)
    }

    public func closeOverlay() {
        overlayState = .none
    }

    public func dismissMutationFailure() {
        guard case .failed = mutationState else { return }
        mutationState = .idle
    }

    public func setActionsOverlayState(_ highlight: MenuHighlightState) {
        overlayState = .actions(highlight)
    }

    public func moveSelection(by offset: Int) {
        if case let .suggested(suggestion, keyboardTarget) = pendingFilterState {
            switch keyboardTarget {
            case .suggestion:
                // The chip sits above the list: Up stays put, Down hands the
                // keyboard to the FIRST row — a nonzero selection preserved
                // across the query transition must not swallow the handoff.
                guard offset > 0 else { return }
                pendingFilterState = .suggested(suggestion, keyboardTarget: .results)
                hasUserNavigated = true
                if selectedIndex != 0, let firstItemId = itemIds.first {
                    select(itemId: firstItemId, origin: .keyboard)
                }
                return
            case .results:
                // Up from the first row (or from an empty list) moves the
                // keyboard onto the chip; anywhere else Up is row navigation.
                if offset < 0, selectedIndex == 0 || selectedIndex == nil {
                    pendingFilterState = .suggested(suggestion, keyboardTarget: .suggestion)
                    return
                }
            }
        }

        hasUserNavigated = true
        guard let currentIndex = selectedIndex else {
            if let firstItemId = itemIds.first {
                select(itemId: firstItemId, origin: .keyboard)
            }
            return
        }
        let newIndex = max(0, min(itemCount - 1, currentIndex + offset))
        guard let itemId = itemIdentifier(at: newIndex) else { return }
        select(itemId: itemId, origin: .keyboard)
    }

    public func select(itemId: String, origin: SelectionOrigin) {
        let signpostID = OSSignpostID(log: poi)
        os_signpost(.begin, log: poi, name: "select", signpostID: signpostID, "itemId=%{public}s origin=%{public}s", itemId, String(describing: origin))
        defer { os_signpost(.end, log: poi, name: "select", signpostID: signpostID) }

        // An explicit row pick (click or keyboard) hands the keyboard back to
        // the results; the chip must not keep Enter after the user addressed
        // a specific row.
        if origin.isUserInitiated,
           case let .suggested(suggestion, keyboardTarget: .suggestion) = pendingFilterState
        {
            pendingFilterState = .suggested(suggestion, keyboardTarget: .results)
        }

        switch editSession {
        case let .focused(focusedId) where focusedId != itemId:
            editSession = .inactive
        case let .dirty(dirtyId, _) where dirtyId != itemId:
            editSession = .inactive
        default:
            break
        }
        // Don't set .loading here — loadSelectedItem() resolves from cache synchronously
        // on the common path (arrow key navigation), so .loading would be immediately
        // overwritten by .selected, causing a redundant SwiftUI view graph invalidation.
        // On cache misses, loadSelectedItem() sets .loading itself before going async.
        loadSelectedItem(itemId: itemId, origin: origin)
    }

    public func confirmSelection() {
        switch keyboardTarget {
        case .pendingFilterChip:
            applyPendingFilterSuggestion()
        case .results:
            guard let item = selectedItem else { return }
            let content = effectiveContent(for: item)
            commitCurrentEdit()
            onSelect(item.itemMetadata.itemId, content)
        }
    }

    public func confirmItem(itemId: String) {
        performItemAction(itemId: itemId, handler: onSelect)
    }

    public func copyOnlySelection() {
        guard let item = selectedItem else { return }
        let content = effectiveContent(for: item)
        commitCurrentEdit()
        onCopyOnly(item.itemMetadata.itemId, content)
    }

    public func copyOnlyItem(itemId: String) {
        performItemAction(itemId: itemId, handler: onCopyOnly)
    }

    public func loadMatchedExcerptsForItems(_ ids: [String]) {
        guard displayedContent != nil else { return }
        let request = contentState.request

        let uniqueIds = Array(Set(ids)).sorted()
        guard !uniqueIds.isEmpty else { return }

        let excerptRequests = uniqueIds
            .filter { !pendingMatchedExcerptItemIds.contains($0) }
            .compactMap { deferredMatchedExcerptRequest(for: $0) }
        guard !excerptRequests.isEmpty else { return }

        let generation = queryGeneration
        let requestSignature = excerptRequests
            .map { "\($0.itemId)|\($0.query)|\($0.contentHash)|\($0.presentationProfile)" }
            .joined(separator: ",")
        let key = "\(generation)|\(requestSignature)"
        guard matchedExcerptTasks[key] == nil else { return }
        let pendingItemIds = excerptRequests.map { $0.itemId }
        pendingMatchedExcerptItemIds.formUnion(pendingItemIds)

        matchedExcerptTasks[key] = Task { [weak self] in
            guard let self else { return }
            let results = await self.client.resolveMatchedExcerpts(requests: excerptRequests)
            await MainActor.run {
                defer {
                    self.matchedExcerptTasks[key] = nil
                    if self.queryGeneration == generation {
                        self.pendingMatchedExcerptItemIds.subtract(pendingItemIds)
                    }
                }
                guard !Task.isCancelled else { return }
                guard self.queryGeneration == generation,
                      self.contentState.request == request
                else {
                    return
                }

                var updates: [String: MatchedExcerpt] = [:]
                for result in results {
                    switch result {
                    case let .ready(itemId, excerpt):
                        guard self.indexOfItem(itemId) != nil else { continue }
                        guard self.deferredMatchedExcerptRequest(for: itemId) != nil else { continue }
                        updates[itemId] = excerpt
                    case .unavailable:
                        continue
                    }
                }

                guard !updates.isEmpty else { return }
                self.resolvedMatchedExcerptsByItemId.merge(updates) { existing, _ in existing }
                self.rebuildDisplayedRows()
            }
        }
    }

    public func deleteSelectedItem() {
        guard let itemId = selectedItemId else { return }
        deleteItem(itemId: itemId)
    }

    public func deleteItem(itemId: String) {
        // Accumulate into existing pending delete batch
        if case var .deleting(.pending(prev)) = mutationState {
            pendingDeleteTask?.cancel()
            prev.deletedItemIds.append(itemId)
            mutationState = .deleting(.pending(prev))
            applyOptimisticDelete(itemId: itemId)
            showDeleteUndoNotification(count: prev.deletedItemIds.count)
            scheduleDeleteCommit()
            return
        }

        // If a previous delete is already committing, just clear state
        if case .deleting(.committing) = mutationState {
            mutationState = .idle
        }

        guard case .idle = mutationState else { return }

        let transaction = DeleteTransaction(
            deletedItemIds: [itemId],
            snapshot: contentState,
            selectionSnapshot: selectionState
        )
        mutationState = .deleting(.pending(transaction))

        applyOptimisticDelete(itemId: itemId)
        showDeleteUndoNotification(count: 1)
        scheduleDeleteCommit()
    }

    private func scheduleDeleteCommit() {
        pendingDeleteTask?.cancel()
        let delay = deleteCommitDelay
        pendingDeleteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.commitPendingDelete()
            }
        }
    }

    public func undoPendingDelete() {
        guard case let .deleting(.pending(transaction)) = mutationState else { return }
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        dismissSnackbarNotification()
        restoreSnapshot(transaction.snapshot, selection: transaction.selectionSnapshot)
        mutationState = .idle
    }

    public func clearAll() {
        mutationState = .clearing(ClearTransaction(
            snapshot: contentState,
            selectionSnapshot: selectionState
        ))

        let request = contentState.request
        setDisplayedSelection(.none)
        contentState = .loaded(LoadedBrowserContent(
            response: BrowserSearchResponse(
                request: request,
                items: [],
                firstPreviewPayload: nil,
                totalCount: 0
            )
        ))
        resolvedMatchedExcerptsByItemId.removeAll()
        rebuildDisplayedRows()
        previewPayloadsByItemId.removeAll()
        prefetchCache.removeAll()

        Task { [weak self] in
            guard let self else { return }
            let result = await self.client.clear()
            await MainActor.run {
                switch result {
                case .success:
                    self.mutationState = .idle
                case let .failure(error):
                    self.restoreClearFailure(error: error)
                }
            }
        }
    }

    public func addTagToSelectedItem(_ tag: ItemTag) {
        guard let itemId = selectedItemId else { return }
        mutateItemTag(itemId: itemId, tag: tag, shouldInclude: true)
    }

    public func removeTagFromSelectedItem(_ tag: ItemTag) {
        guard let itemId = selectedItemId else { return }
        mutateItemTag(itemId: itemId, tag: tag, shouldInclude: false)
    }

    public func addTag(_ tag: ItemTag, toItem itemId: String) {
        mutateItemTag(itemId: itemId, tag: tag, shouldInclude: true)
    }

    public func removeTag(_ tag: ItemTag, fromItem itemId: String) {
        mutateItemTag(itemId: itemId, tag: tag, shouldInclude: false)
    }

    public func effectiveContent(for item: ClipboardItem) -> ClipboardContent {
        if case let .dirty(dirtyId, draft) = editSession, dirtyId == item.itemMetadata.itemId {
            return .text(value: draft)
        }
        return item.content
    }

    public func onTextEdit(_ newText: String, for itemId: String, originalText: String) {
        if newText == originalText {
            // Text matches original — drop back to focused (not dirty)
            editSession = .focused(itemId: itemId)
        } else {
            editSession = .dirty(itemId: itemId, draft: newText)
        }
    }

    public func onEditingStateChange(_ isEditing: Bool, for itemId: String) {
        if isEditing {
            // Only transition to focused if not already dirty for this item
            if case let .dirty(dirtyId, _) = editSession, dirtyId == itemId {
                return
            }
            editSession = .focused(itemId: itemId)
        } else {
            switch editSession {
            case let .focused(focusedId) where focusedId == itemId:
                editSession = .inactive
            default:
                break
            }
        }
    }

    public func discardCurrentEdit() {
        editSession = .inactive
    }

    public func commitCurrentEdit() {
        guard case let .dirty(id, editedText) = editSession,
              !editedText.isEmpty
        else {
            editSession = .inactive
            return
        }
        editSession = .inactive

        guard let selectedItemState else {
            showSnackbarNotification(.passive(message: String(localized: "Saved"), iconSystemName: "checkmark.circle.fill"), nil)
            return
        }

        let currentItem = selectedItemState.item
        let updatedContent = ClipboardContent.text(value: editedText)
        let updatedExcerpt = BaselineExcerpt(text: client.formatExcerpt(content: editedText))
        let updatedMetadata = ItemMetadata(
            itemId: currentItem.itemMetadata.itemId,
            icon: currentItem.itemMetadata.icon,
            sourceApp: currentItem.itemMetadata.sourceApp,
            sourceAppBundleId: currentItem.itemMetadata.sourceAppBundleId,
            timestampUnix: currentItem.itemMetadata.timestampUnix,
            tags: currentItem.itemMetadata.tags
        )
        let updatedItem = ClipboardItem(itemMetadata: updatedMetadata, content: updatedContent)
        let updatedPreviewState: SelectedPreviewState = .plain
        previewPayloadsByItemId[id] = PreviewPayload(item: updatedItem, decoration: nil)

        setDisplayedSelection(.selected(SelectedItemState(
            item: updatedItem,
            origin: selectedItemState.origin,
            previewState: updatedPreviewState
        )))
        updateDisplayedResponseForItem(
            itemId: id,
            updatedMetadata: updatedMetadata,
            updatedFirstItem: updatedItem,
            updatedPresentation: .baseline(excerpt: updatedExcerpt)
        )

        // Invalidate stale decoration caches for this item
        resolvedMatchedExcerptsByItemId.removeValue(forKey: id)
        previewPayloadsByItemId[id] = PreviewPayload(item: updatedItem, decoration: nil)

        showSnackbarNotification(.passive(message: String(localized: "Saved"), iconSystemName: "checkmark.circle.fill"), nil)

        Task { [weak self] in
            guard let self else { return }
            _ = await self.client.updateTextItem(itemId: id, text: editedText)
            // Resubmit the active search so Rust re-evaluates whether this item
            // still matches, re-ranks it, and emits fresh highlight ranges.
            if !self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.submitSearch(text: self.searchText, filter: self.contentState.request.filter)
            }
        }
    }

    // Call sites should match `editSession` directly instead of
    // using derived booleans. PreviewInteractionMode has been removed.

    /// Semantic browser actions (platform-independent).
    public enum BrowserAction {
        case defaultAction
        case copyOnly
        case bookmark
        case unbookmark
        case delete
    }

    public func performAction(
        _ action: BrowserAction,
        itemId: String,
        dismissOverlay: () -> Void
    ) {
        switch action {
        case .defaultAction:
            dismissOverlay()
            confirmItem(itemId: itemId)
        case .copyOnly:
            dismissOverlay()
            copyOnlyItem(itemId: itemId)
        case .bookmark:
            dismissOverlay()
            addTag(.bookmark, toItem: itemId)
        case .unbookmark:
            dismissOverlay()
            removeTag(.bookmark, fromItem: itemId)
        case .delete:
            dismissOverlay()
            deleteItem(itemId: itemId)
        }
    }

    private func refreshCurrentRequestIfStale() {
        guard hasAppliedInitialSearch else { return }
        guard lastLoadedContentRevision != latestKnownContentRevision || displayedContent == nil else { return }
        guard searchExecution.request != contentState.request ||
            searchExecution.targetContentRevision != latestKnownContentRevision
        else {
            return
        }
        submitSearch(request: contentState.request, targetContentRevision: latestKnownContentRevision)
    }

    private func cancelInFlightWork() {
        searchExecution.cancel()
        previewTask?.cancel()
        previewTask = nil
        #if ENABLE_LINK_PREVIEWS
            metadataTask?.cancel()
            metadataTask = nil
        #endif
        matchedExcerptTasks.values.forEach { $0.cancel() }
        matchedExcerptTasks.removeAll()
        pendingMatchedExcerptItemIds.removeAll()
        prefetchTask?.cancel()
        prefetchTask = nil
        previewSpinnerTask?.cancel()
        previewSpinnerTask = nil
        pendingFilterSurfaceTask?.cancel()
        pendingFilterSurfaceTask = nil
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        pendingTagSettleTask?.cancel()
        pendingTagSettleTask = nil
        queryGeneration += 1
        previewGeneration += 1
        #if ENABLE_LINK_PREVIEWS
            metadataGeneration += 1
        #endif
        hidePreviewSpinner()
    }

    /// Re-derives the pending suggestion whenever a search is submitted, so
    /// the chip always reflects the request the user actually sees.
    ///
    /// A suggestion that is already visible for the same filter updates in
    /// place (keeping the user's keyboard target) so the chip doesn't flicker
    /// while the trigger token grows ("ima" → "imag"). A NEW suggestion only
    /// surfaces after the user pauses typing for ``pendingFilterSurfaceDelay``,
    /// so intermediate prefixes mid-word don't flash the chip; it surfaces
    /// with the results keeping the keyboard — the user opts into the chip
    /// with Up from the first row.
    private func refreshPendingFilterState(for request: SearchRequest) {
        pendingFilterSurfaceTask?.cancel()
        pendingFilterSurfaceTask = nil

        guard let suggestion = filterCatalog.typedSuggestion(
            searchText: request.text,
            appliedFilter: request.filter
        ) else {
            pendingFilterState = .none
            return
        }

        if case let .suggested(current, keyboardTarget) = pendingFilterState,
           current.kind == suggestion.kind
        {
            pendingFilterState = .suggested(suggestion, keyboardTarget: keyboardTarget)
            return
        }

        pendingFilterState = .none
        let delay = pendingFilterSurfaceDelay
        pendingFilterSurfaceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.contentState.request == request else { return }
                self.pendingFilterState = .suggested(suggestion, keyboardTarget: .results)
            }
        }
    }

    private func startInitialSearch(initialSearchQuery: String, targetContentRevision: Int) {
        hasAppliedInitialSearch = true
        submitSearch(
            request: SearchRequest(text: initialSearchQuery, filter: .all),
            targetContentRevision: targetContentRevision
        )
    }

    private func submitSearch(text rawText: String, filter: ItemQueryFilter) {
        submitSearch(
            request: SearchRequest(text: rawText, filter: filter),
            targetContentRevision: latestKnownContentRevision
        )
    }

    private func submitSearch(request: SearchRequest, targetContentRevision: Int) {
        queryGeneration += 1
        hasUserNavigated = false
        refreshPendingFilterState(for: request)
        prefetchCache.removeAll()
        previewPayloadsByItemId.removeAll()
        resolvedMatchedExcerptsByItemId.removeAll()
        searchExecution.cancel()
        matchedExcerptTasks.values.forEach { $0.cancel() }
        matchedExcerptTasks.removeAll()
        pendingMatchedExcerptItemIds.removeAll()
        prefetchTask?.cancel()
        prefetchTask = nil

        if displayedContent?.response.request != request {
            setDisplayedSelection(selectionDuringSearchTransition(to: request))
        }
        contentState = .loading(request: request, previous: displayedContent, phase: .debouncing)
        rebuildDisplayedRows()

        if request.text.isEmpty {
            beginSearch(request: request, targetContentRevision: targetContentRevision)
            return
        }

        let debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.beginSearch(request: request, targetContentRevision: targetContentRevision)
            }
        }
        searchExecution = .debouncing(
            request: request,
            targetContentRevision: targetContentRevision,
            task: debounceTask
        )
    }

    private func beginSearch(request: SearchRequest, targetContentRevision: Int) {
        let operation = client.startSearch(request: request)
        let operationId = UUID()
        contentState = .loading(request: request, previous: displayedContent, phase: .running(spinnerVisible: false))
        rebuildDisplayedRows()

        let observer = Task { [weak self] in
            guard let self else { return }
            let outcome = await operation.awaitOutcome()
            await MainActor.run {
                self.applySearchOutcome(
                    outcome,
                    operationId: operationId,
                    targetContentRevision: targetContentRevision
                )
            }
        }

        let spinner = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.showSearchSpinnerIfNeeded(operationId: operationId, request: request)
            }
        }

        searchExecution = .running(
            id: operationId,
            request: request,
            targetContentRevision: targetContentRevision,
            operation: operation,
            observer: observer,
            spinner: spinner
        )
    }

    private func applySearchOutcome(
        _ outcome: BrowserSearchOutcome,
        operationId: UUID,
        targetContentRevision: Int
    ) {
        guard searchExecution.id == operationId else { return }
        searchExecution = .idle

        switch outcome {
        case let .success(response):
            applySearchResponse(response, targetContentRevision: targetContentRevision)
        case .cancelled:
            // The operationId guard passed, so this cancellation came from outside the
            // view model (another consumer of the shared Rust store cancelled the global
            // search token). Re-run the current request instead of stranding `.loading`
            // with stale results or a stuck spinner.
            guard case let .loading(request, _, _) = contentState else { return }
            beginSearch(request: request, targetContentRevision: targetContentRevision)
        case let .failure(error):
            guard case let .loading(request, previous, _) = contentState else { return }
            contentState = .failed(
                request: request,
                message: error.localizedDescription,
                previous: previous
            )
            rebuildDisplayedRows()
        }
    }

    private func applySearchResponse(_ response: BrowserSearchResponse, targetContentRevision: Int) {
        guard contentState.request == response.request else { return }
        let response = responseApplyingPendingMutations(response)
        cachePreviewPayload(response.firstPreviewPayload)
        lastLoadedContentRevision = targetContentRevision

        let previousOrder = itemIds
        let previousSelection = selection
        let previousSelectedItemState = selectedItemState

        contentState = .loaded(LoadedBrowserContent(response: response))
        rebuildDisplayedRows()

        let newOrder = response.items.map { $0.itemMetadata.itemId }
        guard !newOrder.isEmpty else {
            setDisplayedSelection(.none)
            clearInactiveEdits()
            finishTagMutationSettleIfNeeded()
            return
        }

        guard let previousSelectedItemId = previousSelection.itemId,
              let previousOrigin = previousSelection.origin
        else {
            select(itemId: newOrder[0], origin: .automatic)
            finishTagMutationSettleIfNeeded()
            return
        }

        if !newOrder.contains(previousSelectedItemId) ||
            previousOrder.firstIndex(of: previousSelectedItemId) != newOrder.firstIndex(of: previousSelectedItemId)
        {
            let nextItemId = newOrder[0]
            setDisplayedSelection(.loading(itemId: nextItemId, origin: .automatic))
            loadSelectedItem(itemId: nextItemId, origin: .automatic)
            clearInactiveEdits()
            finishTagMutationSettleIfNeeded()
            return
        }

        refreshSelection(
            itemId: previousSelectedItemId,
            origin: previousOrigin,
            response: response,
            previousSelectedItemState: previousSelectedItemState
        )
        clearInactiveEdits()
        finishTagMutationSettleIfNeeded()
    }

    private func refreshSelection(
        itemId: String,
        origin: SelectionOrigin,
        response: BrowserSearchResponse,
        previousSelectedItemState: SelectedItemState?
    ) {
        let request = response.request

        // Once an image preview is already loaded for the selected item, keep that
        // selection stable across query refreshes. Rebuilding the same image-backed
        // selection on every keystroke needlessly invalidates the preview subtree and
        // can make typing feel sticky right when the image is visible.
        if let currentSelectedItemState = selectedItemState,
           currentSelectedItemState.item.itemMetadata.itemId == itemId,
           !requiresPreviewDecoration(for: currentSelectedItemState.item, request: request),
           case .image = currentSelectedItemState.item.content
        {
            return
        }

        if let firstPreviewPayload = response.firstPreviewPayload,
           firstPreviewPayload.item.itemMetadata.itemId == itemId
        {
            cachePreviewPayload(firstPreviewPayload)
            setDisplayedSelection(.selected(makeSelectedItemState(
                for: firstPreviewPayload,
                origin: origin,
                request: request,
                previousDecoration: carriedPreviewDecoration(for: itemId)
            )))
            if !previewPayloadSatisfiesDecorationRequirement(firstPreviewPayload, for: request) {
                loadSelectedItem(itemId: itemId, origin: origin)
            }
            return
        }

        if let cachedPreviewPayload = previewPayloadsByItemId[itemId] {
            setDisplayedSelection(.selected(makeSelectedItemState(
                for: cachedPreviewPayload,
                origin: origin,
                request: request,
                previousDecoration: carriedPreviewDecoration(for: itemId)
            )))
            if !previewPayloadSatisfiesDecorationRequirement(cachedPreviewPayload, for: request) {
                loadSelectedItem(itemId: itemId, origin: origin)
            }
            return
        }

        if let previousSelectedItemState,
           previousSelectedItemState.item.itemMetadata.itemId == itemId
        {
            let payload = PreviewPayload(item: previousSelectedItemState.item, decoration: nil)
            cachePreviewPayload(payload)
            if requiresPreviewDecoration(for: previousSelectedItemState.item, request: request) {
                setDisplayedSelection(.selected(makeDecorationLoadingSelectedItemState(
                    from: previousSelectedItemState,
                    origin: origin
                )))
                loadSelectedItem(itemId: itemId, origin: origin)
            } else {
                setDisplayedSelection(.selected(makeSelectedItemState(
                    for: payload,
                    origin: origin,
                    request: request
                )))
            }
            return
        }

        if let cachedItem = prefetchCache[itemId] {
            let payload = PreviewPayload(item: cachedItem, decoration: nil)
            cachePreviewPayload(payload)
            setDisplayedSelection(.selected(makeSelectedItemState(
                for: payload,
                origin: origin,
                request: request
            )))
            if requiresPreviewDecoration(for: cachedItem, request: request) {
                loadSelectedItem(itemId: itemId, origin: origin)
            }
            return
        }

        setDisplayedSelection(.loading(itemId: itemId, origin: origin))
        loadSelectedItem(itemId: itemId, origin: origin)
    }

    private func loadSelectedItem(itemId: String, origin: SelectionOrigin) {
        let signpostID = OSSignpostID(log: poi)
        os_signpost(.begin, log: poi, name: "loadSelectedItem", signpostID: signpostID, "itemId=%{public}s", itemId)
        defer { os_signpost(.end, log: poi, name: "loadSelectedItem", signpostID: signpostID) }

        previewTask?.cancel()
        prefetchTask?.cancel()
        prefetchTask = nil
        #if ENABLE_LINK_PREVIEWS
            metadataTask?.cancel()
        #endif
        previewGeneration += 1
        let generation = previewGeneration
        let request = contentState.request

        if let firstPreviewPayload = contentState.firstPreviewPayload,
           firstPreviewPayload.item.itemMetadata.itemId == itemId
        {
            cachePreviewPayload(firstPreviewPayload)
            setDisplayedSelection(.selected(makeSelectedItemState(
                for: firstPreviewPayload,
                origin: origin,
                request: request,
                previousDecoration: carriedPreviewDecoration(for: itemId)
            )))
            prefetchAdjacentItems(around: itemId)
            #if ENABLE_LINK_PREVIEWS
                maybeRefreshLinkMetadata(for: firstPreviewPayload.item, generation: generation)
            #endif
            hidePreviewSpinner()
            guard !previewPayloadSatisfiesDecorationRequirement(firstPreviewPayload, for: request) else {
                return
            }
            schedulePreviewSpinner(for: generation, itemId: itemId)
            loadPreviewDecoration(itemId: itemId, origin: origin, request: request, generation: generation)
            return
        }

        if let cachedPreviewPayload = previewPayloadsByItemId[itemId] {
            setDisplayedSelection(.selected(makeSelectedItemState(
                for: cachedPreviewPayload,
                origin: origin,
                request: request,
                previousDecoration: carriedPreviewDecoration(for: itemId)
            )))
            prefetchAdjacentItems(around: itemId)
            #if ENABLE_LINK_PREVIEWS
                maybeRefreshLinkMetadata(for: cachedPreviewPayload.item, generation: generation)
            #endif
            hidePreviewSpinner()
            guard !previewPayloadSatisfiesDecorationRequirement(cachedPreviewPayload, for: request) else {
                return
            }
            schedulePreviewSpinner(for: generation, itemId: itemId)
            loadPreviewDecoration(itemId: itemId, origin: origin, request: request, generation: generation)
            return
        }

        if let currentSelectedItemState = selectedItemState,
           currentSelectedItemState.item.itemMetadata.itemId == itemId,
           requiresPreviewDecoration(for: currentSelectedItemState.item, request: request)
        {
            setDisplayedSelection(.selected(makeDecorationLoadingSelectedItemState(
                from: currentSelectedItemState,
                origin: origin
            )))
            schedulePreviewSpinner(for: generation, itemId: itemId)
            loadPreviewDecoration(itemId: itemId, origin: origin, request: request, generation: generation)
            return
        }

        if let cachedItem = prefetchCache[itemId] {
            let payload = PreviewPayload(item: cachedItem, decoration: nil)
            cachePreviewPayload(payload)
            setDisplayedSelection(.selected(makeSelectedItemState(
                for: payload,
                origin: origin,
                request: request
            )))
            prefetchAdjacentItems(around: itemId)
            #if ENABLE_LINK_PREVIEWS
                maybeRefreshLinkMetadata(for: cachedItem, generation: generation)
            #endif
            hidePreviewSpinner()
            guard requiresPreviewDecoration(for: cachedItem, request: request) else {
                return
            }
            schedulePreviewSpinner(for: generation, itemId: itemId)
            loadPreviewDecoration(itemId: itemId, origin: origin, request: request, generation: generation)
            return
        }

        setDisplayedSelection(.loading(itemId: itemId, origin: origin))
        schedulePreviewSpinner(for: generation, itemId: itemId)

        previewTask = Task { [weak self] in
            guard let self else { return }
            guard let item = await self.client.fetchItem(id: itemId) else {
                await MainActor.run {
                    guard self.previewGeneration == generation,
                          self.contentState.request == request,
                          self.selectedItemId == itemId
                    else {
                        return
                    }

                    self.hidePreviewSpinner()
                    self.setDisplayedSelection(.failed(itemId: itemId, origin: origin))
                }
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.previewGeneration == generation,
                      self.contentState.request == request,
                      self.selectedItemId == itemId
                else {
                    return
                }

                let payload = PreviewPayload(item: item, decoration: nil)
                self.cachePreviewPayload(payload)
                self.setDisplayedSelection(.selected(self.makeSelectedItemState(
                    for: payload,
                    origin: origin,
                    request: request
                )))
                self.prefetchAdjacentItems(around: itemId)
                #if ENABLE_LINK_PREVIEWS
                    self.maybeRefreshLinkMetadata(for: item, generation: generation)
                #endif

                guard self.requiresPreviewDecoration(for: item, request: request) else {
                    self.hidePreviewSpinner()
                    return
                }

                self.loadPreviewDecoration(
                    itemId: itemId,
                    origin: origin,
                    request: request,
                    generation: generation
                )
            }
        }
    }

    private func loadPreviewDecoration(
        itemId: String,
        origin: SelectionOrigin,
        request: SearchRequest,
        generation: Int
    ) {
        previewTask = Task { [weak self] in
            guard let self else { return }
            let payload = await self.client.loadPreviewPayload(itemId: itemId, query: request.text)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.previewGeneration == generation,
                      self.contentState.request == request,
                      self.selectedItemId == itemId
                else {
                    return
                }

                self.hidePreviewSpinner()
                guard let payload else {
                    self.resolveSelectionWithoutPreviewDecoration(itemId: itemId, origin: origin)
                    return
                }

                self.cachePreviewPayload(payload)
                if self.previewPayloadSatisfiesDecorationRequirement(payload, for: request) {
                    self.setDisplayedSelection(.selected(self.makeSelectedItemState(
                        for: payload,
                        origin: origin,
                        request: request,
                        previousDecoration: self.carriedPreviewDecoration(for: itemId)
                    )))
                } else {
                    self.setDisplayedSelection(.selected(SelectedItemState(
                        item: payload.item,
                        origin: origin,
                        previewState: .plain
                    )))
                }
                self.prefetchAdjacentItems(around: itemId)
                #if ENABLE_LINK_PREVIEWS
                    self.maybeRefreshLinkMetadata(for: payload.item, generation: generation)
                #endif
            }
        }
    }

    #if ENABLE_LINK_PREVIEWS
        private func maybeRefreshLinkMetadata(for item: ClipboardItem, generation: Int) {
            guard case let .link(url, metadataState) = item.content,
                  case .pending = metadataState,
                  shouldGenerateLinkPreviews()
            else {
                return
            }

            metadataTask?.cancel()
            metadataGeneration += 1
            let metadataRequest = metadataGeneration

            metadataTask = Task { [weak self] in
                guard let self else { return }
                let updatedItem = await self.client.fetchLinkMetadata(url: url, itemId: item.itemMetadata.itemId)
                await MainActor.run {
                    guard self.previewGeneration == generation,
                          self.metadataGeneration == metadataRequest,
                          self.selectedItemId == item.itemMetadata.itemId,
                          let updatedItem,
                          let selectedItemState = self.selectedItemState
                    else {
                        return
                    }

                    let currentTags = self.selectedItem?.itemMetadata.tags ?? updatedItem.itemMetadata.tags
                    let mergedPreviewMetadata = ItemMetadata(
                        itemId: updatedItem.itemMetadata.itemId,
                        icon: updatedItem.itemMetadata.icon,
                        sourceApp: updatedItem.itemMetadata.sourceApp,
                        sourceAppBundleId: updatedItem.itemMetadata.sourceAppBundleId,
                        timestampUnix: updatedItem.itemMetadata.timestampUnix,
                        tags: currentTags
                    )
                    let mergedPreviewItem = ClipboardItem(itemMetadata: mergedPreviewMetadata, content: updatedItem.content)
                    let updatedPreviewPayload = PreviewPayload(
                        item: mergedPreviewItem,
                        decoration: self.cachedPreviewPayloadDecoration(for: selectedItemState)
                    )
                    self.cachePreviewPayload(updatedPreviewPayload)

                    self.setDisplayedSelection(.selected(SelectedItemState(
                        item: mergedPreviewItem,
                        origin: selectedItemState.origin,
                        previewState: selectedItemState.previewState
                    )))
                    self.updateDisplayedResponseForItem(
                        itemId: updatedItem.itemMetadata.itemId,
                        updatedMetadata: mergedPreviewMetadata,
                        updatedFirstItem: mergedPreviewItem,
                        updatedPresentation: self.currentResponse?.items.first {
                            $0.itemMetadata.itemId == updatedItem.itemMetadata.itemId
                        }?.presentation ?? .baseline(excerpt: BaselineExcerpt(text: ""))
                    )
                }
            }
        }
    #endif

    private let prefetchRadius = 5

    private func prefetchAdjacentItems(around itemId: String) {
        guard let currentIndex = indexOfItem(itemId) else { return }
        let start = max(0, currentIndex - prefetchRadius)
        let end = min(itemIds.count - 1, currentIndex + prefetchRadius)
        guard start <= end else { return }
        let idsToPrefetch = (start ... end).map { itemIds[$0] }.filter { prefetchCache[$0] == nil }
        guard !idsToPrefetch.isEmpty else { return }
        let generation = queryGeneration

        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            for itemId in idsToPrefetch {
                guard !Task.isCancelled else { return }
                guard let item = await self.client.fetchItem(id: itemId) else { continue }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.queryGeneration == generation else { return }
                    if self.indexOfItem(itemId) != nil {
                        self.prefetchCache[itemId] = item
                    }
                }
            }
        }
    }

    private func showSearchSpinnerIfNeeded(operationId: UUID, request: SearchRequest) {
        guard searchExecution.id == operationId,
              case let .loading(currentRequest, previous, .running(spinnerVisible: false)) = contentState,
              currentRequest == request
        else {
            return
        }
        contentState = .loading(
            request: currentRequest,
            previous: previous,
            phase: .running(spinnerVisible: true)
        )
    }

    private func hidePreviewSpinner() {
        previewSpinnerTask?.cancel()
        previewSpinnerTask = nil
        previewSpinnerVisible = false
    }

    private func schedulePreviewSpinner(for generation: Int, itemId: String) {
        hidePreviewSpinner()
        previewSpinnerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.previewGeneration == generation,
                      self.selectedItemId == itemId,
                      self.isPreviewAwaitingPayload(for: itemId)
                else {
                    return
                }
                self.previewSpinnerTask = nil
                self.previewSpinnerVisible = true
            }
        }
    }

    private func applyOptimisticDelete(itemId: String) {
        guard let response = currentResponse else { return }
        let filteredItems = response.items.filter { $0.itemMetadata.itemId != itemId }
        resolvedMatchedExcerptsByItemId.removeValue(forKey: itemId)
        previewPayloadsByItemId.removeValue(forKey: itemId)
        prefetchCache.removeValue(forKey: itemId)
        let deletedSelectedItem = selectedItemId == itemId
        let nextSelection = deletedSelectedItem ? nextSelectionAfterDelete(deleting: itemId) : nil
        updateDisplayedResponse(BrowserSearchResponse(
            request: response.request,
            items: filteredItems,
            firstPreviewPayload: response.firstPreviewPayload?.item.itemMetadata.itemId == itemId
                ? nil
                : response.firstPreviewPayload,
            totalCount: max(0, response.totalCount - 1)
        ))

        if let nextSelection {
            setDisplayedSelection(.loading(itemId: nextSelection, origin: .automatic))
            loadSelectedItem(itemId: nextSelection, origin: .automatic)
        } else if deletedSelectedItem {
            setDisplayedSelection(.none)
        }
        clearInactiveEdits()
    }

    private func commitPendingDelete() {
        guard case let .deleting(.pending(transaction)) = mutationState else { return }
        pendingDeleteTask = nil
        mutationState = .deleting(.committing(transaction))
        // The undo window is over; the Undo button must not outlive it.
        dismissSnackbarNotification()

        Task { [weak self] in
            guard let self else { return }
            var lastError: ClipboardError?
            for itemId in transaction.deletedItemIds {
                let result = await self.client.delete(itemId: itemId)
                if case let .failure(error) = result {
                    lastError = error
                }
            }
            await MainActor.run {
                if let error = lastError {
                    self.restoreDeleteFailure(error: error)
                } else if case .deleting(.committing) = self.mutationState {
                    self.mutationState = .idle
                }
            }
        }
    }

    private func restoreDeleteFailure(error: ClipboardError) {
        let transaction: DeleteTransaction
        switch mutationState {
        case let .deleting(.pending(pendingTransaction)), let .deleting(.committing(pendingTransaction)):
            transaction = pendingTransaction
        default:
            return
        }
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        restoreSnapshot(transaction.snapshot, selection: transaction.selectionSnapshot)
        mutationState = .failed(ActionFailure(message: error.localizedDescription))
    }

    private func showDeleteUndoNotification(count: Int) {
        let message = count > 1
            ? String(localized: "Deleted \(count)")
            : String(localized: "Deleted")
        showSnackbarNotification(
            .actionable(
                message: message,
                iconSystemName: "trash",
                actionTitle: String(localized: "Undo")
            )
        ) { [weak self] in
            self?.undoPendingDelete()
        }
    }

    private func restoreClearFailure(error: ClipboardError) {
        guard case let .clearing(transaction) = mutationState else { return }
        restoreSnapshot(transaction.snapshot, selection: transaction.selectionSnapshot)
        mutationState = .failed(ActionFailure(message: error.localizedDescription))
    }

    private func restoreSnapshot(_ snapshot: BrowserContentState, selection: SelectionState?) {
        contentState = snapshot
        rebuildDisplayedRows()
        if let selection {
            setDisplayedSelection(selection)
        }
        syncPreviewPayloadCacheToDisplayedState()
        clearInactiveEdits()
    }

    private func nextSelectionAfterDelete(deleting _: String) -> String? {
        guard let currentIndex = selectedIndex else { return nil }
        if currentIndex + 1 < itemCount {
            return itemIdentifier(at: currentIndex + 1)
        }
        if currentIndex > 0 {
            return itemIdentifier(at: currentIndex - 1)
        }
        return nil
    }

    private var displayedContent: LoadedBrowserContent? {
        contentState.displayedContent
    }

    private var currentResponse: BrowserSearchResponse? {
        displayedContent?.response
    }

    private func responseApplyingPendingMutations(_ response: BrowserSearchResponse) -> BrowserSearchResponse {
        switch mutationState {
        case let .deleting(.pending(transaction)), let .deleting(.committing(transaction)):
            return responseHidingDeletedItems(response, deletedItemIds: transaction.deletedItemIds)
        case let .tagging(.pending(mutation)), let .tagging(.settling(mutation)):
            return responseApplyingTagMutation(
                response,
                itemId: mutation.itemId,
                tag: mutation.tag,
                shouldInclude: mutation.shouldInclude
            )
        case .idle, .clearing, .failed:
            return response
        }
    }

    private func responseHidingDeletedItems(_ response: BrowserSearchResponse, deletedItemIds: [String]) -> BrowserSearchResponse {
        let idSet = Set(deletedItemIds)
        let filteredItems = response.items.filter { !idSet.contains($0.itemMetadata.itemId) }
        guard filteredItems.count < response.items.count else { return response }

        let filteredFirstPreviewPayload: PreviewPayload? =
            if let preview = response.firstPreviewPayload,
            idSet.contains(preview.item.itemMetadata.itemId) { nil }
            else { response.firstPreviewPayload }

        return BrowserSearchResponse(
            request: response.request,
            items: filteredItems,
            firstPreviewPayload: filteredFirstPreviewPayload,
            totalCount: max(0, response.totalCount - idSet.count)
        )
    }

    private func mutateItemTag(itemId: String, tag: ItemTag, shouldInclude: Bool) {
        pendingTagSettleTask?.cancel()
        pendingTagSettleTask = nil
        let transaction = TagMutationTransaction(
            itemId: itemId,
            tag: tag,
            shouldInclude: shouldInclude,
            snapshot: contentState,
            selectionSnapshot: selectionState
        )
        mutationState = .tagging(.pending(transaction))
        applyOptimisticTagMutation(itemId: itemId, tag: tag, shouldInclude: shouldInclude)

        Task { [weak self] in
            guard let self else { return }
            let result: Result<Void, ClipboardError> = shouldInclude
                ? await self.client.addTag(itemId: itemId, tag: tag)
                : await self.client.removeTag(itemId: itemId, tag: tag)

            await MainActor.run {
                switch result {
                case .success:
                    if case let .tagging(.pending(mutation)) = self.mutationState,
                       mutation.itemId == itemId,
                       mutation.tag == tag,
                       mutation.shouldInclude == shouldInclude
                    {
                        self.mutationState = .tagging(.settling(mutation))
                        self.scheduleTagMutationSettleFallback(
                            itemId: mutation.itemId,
                            tag: mutation.tag,
                            shouldInclude: mutation.shouldInclude
                        )
                    }
                case let .failure(error):
                    self.pendingTagSettleTask?.cancel()
                    self.pendingTagSettleTask = nil
                    self.restoreSnapshot(transaction.snapshot, selection: transaction.selectionSnapshot)
                    self.mutationState = .failed(ActionFailure(message: error.localizedDescription))
                }
            }
        }
    }

    private func applyOptimisticTagMutation(itemId: String, tag: ItemTag, shouldInclude: Bool) {
        guard let response = currentResponse else { return }
        let updatedResponse = responseApplyingTagMutation(
            response,
            itemId: itemId,
            tag: tag,
            shouldInclude: shouldInclude
        )
        updateDisplayedResponse(updatedResponse)

        if let selectedItemState {
            let updatedMetadata = selectedItemState.item.itemMetadata.itemId == itemId
                ? applyingTagMutation(to: selectedItemState.item.itemMetadata, tag: tag, shouldInclude: shouldInclude)
                : selectedItemState.item.itemMetadata

            if case let .tagged(activeTag) = response.request.filter,
               activeTag == tag,
               !updatedMetadata.tags.contains(tag)
            {
                setDisplayedSelection(.none)
                if let firstItemId = updatedResponse.items.first?.itemMetadata.itemId {
                    select(itemId: firstItemId, origin: .automatic)
                }
            } else if selectedItemState.item.itemMetadata.itemId == itemId {
                let updatedItem = ClipboardItem(itemMetadata: updatedMetadata, content: selectedItemState.item.content)
                previewPayloadsByItemId[itemId] = PreviewPayload(
                    item: updatedItem,
                    decoration: cachedPreviewPayloadDecoration(for: selectedItemState)
                )
                setDisplayedSelection(.selected(SelectedItemState(
                    item: updatedItem,
                    origin: selectedItemState.origin,
                    previewState: selectedItemState.previewState
                )))
            }
        }

        if let cachedItem = prefetchCache[itemId] {
            let updatedMetadata = applyingTagMutation(to: cachedItem.itemMetadata, tag: tag, shouldInclude: shouldInclude)
            prefetchCache[itemId] = ClipboardItem(itemMetadata: updatedMetadata, content: cachedItem.content)
        }
        clearInactiveEdits()
    }

    private func scheduleTagMutationSettleFallback(itemId: String, tag: ItemTag, shouldInclude: Bool) {
        pendingTagSettleTask?.cancel()
        pendingTagSettleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if case let .tagging(.settling(mutation)) = self.mutationState,
                   mutation.itemId == itemId,
                   mutation.tag == tag,
                   mutation.shouldInclude == shouldInclude
                {
                    self.mutationState = .idle
                }
                self.pendingTagSettleTask = nil
            }
        }
    }

    private func responseApplyingTagMutation(
        _ response: BrowserSearchResponse,
        itemId: String,
        tag: ItemTag,
        shouldInclude: Bool
    ) -> BrowserSearchResponse {
        let updatedItems = response.items.compactMap { itemMatch -> ItemMatch? in
            let isTarget = itemMatch.itemMetadata.itemId == itemId
            let updatedMetadata = isTarget
                ? applyingTagMutation(to: itemMatch.itemMetadata, tag: tag, shouldInclude: shouldInclude)
                : itemMatch.itemMetadata

            if case let .tagged(activeTag) = response.request.filter,
               activeTag == tag,
               !updatedMetadata.tags.contains(tag)
            {
                resolvedMatchedExcerptsByItemId.removeValue(forKey: itemMatch.itemMetadata.itemId)
                previewPayloadsByItemId.removeValue(forKey: itemMatch.itemMetadata.itemId)
                prefetchCache.removeValue(forKey: itemMatch.itemMetadata.itemId)
                return nil
            }

            return ItemMatch(itemMetadata: updatedMetadata, presentation: itemMatch.presentation)
        }

        let updatedFirstPreviewPayload = response.firstPreviewPayload.flatMap { payload -> PreviewPayload? in
            guard payload.item.itemMetadata.itemId == itemId else { return payload }
            let updatedMetadata = applyingTagMutation(
                to: payload.item.itemMetadata,
                tag: tag,
                shouldInclude: shouldInclude
            )
            if case let .tagged(activeTag) = response.request.filter,
               activeTag == tag,
               !updatedMetadata.tags.contains(tag)
            {
                return nil
            }
            let updatedItem = ClipboardItem(itemMetadata: updatedMetadata, content: payload.item.content)
            let updatedPayload = PreviewPayload(item: updatedItem, decoration: payload.decoration)
            previewPayloadsByItemId[itemId] = updatedPayload
            return updatedPayload
        }

        return BrowserSearchResponse(
            request: response.request,
            items: updatedItems,
            firstPreviewPayload: updatedFirstPreviewPayload,
            totalCount: updatedItems.count
        )
    }

    private func applyingTagMutation(
        to metadata: ItemMetadata,
        tag: ItemTag,
        shouldInclude: Bool
    ) -> ItemMetadata {
        let updatedTags: [ItemTag]
        if shouldInclude {
            updatedTags = metadata.tags.contains(tag) ? metadata.tags : metadata.tags + [tag]
        } else {
            updatedTags = metadata.tags.filter { $0 != tag }
        }

        return ItemMetadata(
            itemId: metadata.itemId,
            icon: metadata.icon,
            sourceApp: metadata.sourceApp,
            sourceAppBundleId: metadata.sourceAppBundleId,
            timestampUnix: metadata.timestampUnix,
            tags: updatedTags
        )
    }

    private func deferredMatchedExcerptRequest(for itemId: String) -> MatchedExcerptRequest? {
        guard let index = itemIndexById[itemId], displayRows.indices.contains(index) else {
            return nil
        }
        guard resolvedMatchedExcerptsByItemId[itemId] == nil else { return nil }
        switch displayRows[index].presentation {
        case let .deferred(request, _):
            return request
        case .baseline, .matched, .unavailable:
            return nil
        }
    }

    private func makeSelectedItemState(
        for payload: PreviewPayload,
        origin: SelectionOrigin,
        request: SearchRequest,
        previousDecoration: PreviewDecoration? = nil
    ) -> SelectedItemState {
        let previewState: SelectedPreviewState
        if let decoration = payload.decoration {
            previewState = .highlighted(decoration)
        } else if requiresPreviewDecoration(for: payload.item, request: request) {
            previewState = .loadingDecoration(previous: previousDecoration)
        } else {
            previewState = .plain
        }

        return SelectedItemState(
            item: payload.item,
            origin: origin,
            previewState: previewState
        )
    }

    private func makeDecorationLoadingSelectedItemState(
        from selectedItemState: SelectedItemState,
        origin: SelectionOrigin
    ) -> SelectedItemState {
        let previousDecoration: PreviewDecoration?
        switch selectedItemState.previewState {
        case let .highlighted(decoration):
            previousDecoration = decoration
        case let .loadingDecoration(previous):
            previousDecoration = previous
        case .plain:
            previousDecoration = nil
        }

        return SelectedItemState(
            item: selectedItemState.item,
            origin: origin,
            previewState: .loadingDecoration(previous: previousDecoration)
        )
    }

    private func requiresPreviewDecoration(for item: ClipboardItem, request: SearchRequest) -> Bool {
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        switch item.content {
        case .text, .color:
            return true
        case .image, .link, .file:
            return false
        }
    }

    private func previewPayloadSatisfiesDecorationRequirement(
        _ payload: PreviewPayload,
        for request: SearchRequest
    ) -> Bool {
        !requiresPreviewDecoration(for: payload.item, request: request) || payload.decoration != nil
    }

    private func resolveSelectionWithoutPreviewDecoration(itemId: String, origin: SelectionOrigin) {
        guard let currentSelectedItemState = selectedItemState,
              currentSelectedItemState.item.itemMetadata.itemId == itemId
        else {
            return
        }

        setDisplayedSelection(.selected(SelectedItemState(
            item: currentSelectedItemState.item,
            origin: origin,
            previewState: .plain
        )))
    }

    private func selectionDuringSearchTransition(to request: SearchRequest) -> SelectionState {
        guard displayedContent != nil else { return .none }

        switch selectionState {
        case let .selected(selectedItemState):
            guard requiresPreviewDecoration(for: selectedItemState.item, request: request) else {
                return .selected(selectedItemState)
            }

            return .selected(makeDecorationLoadingSelectedItemState(
                from: selectedItemState,
                origin: selectedItemState.origin
            ))
        case .loading, .failed, .none:
            return selectionState
        }
    }

    private func cachePreviewPayload(_ payload: PreviewPayload?) {
        guard let payload else { return }
        let itemId = payload.item.itemMetadata.itemId
        previewPayloadsByItemId[itemId] = payload
        prefetchCache[itemId] = payload.item
    }

    private func cachedPreviewPayloadDecoration(for selectedItemState: SelectedItemState) -> PreviewDecoration? {
        switch selectedItemState.previewState {
        case let .highlighted(decoration):
            return decoration
        case .plain, .loadingDecoration:
            return nil
        }
    }

    private func carriedPreviewDecoration(for itemId: String) -> PreviewDecoration? {
        guard let selectedItemState,
              selectedItemState.item.itemMetadata.itemId == itemId
        else {
            return nil
        }
        return previewDecoration
    }

    private func isPreviewAwaitingPayload(for itemId: String) -> Bool {
        switch selection {
        case let .loading(loadingItemId, _):
            return loadingItemId == itemId
        case let .selected(selectedItemState):
            guard selectedItemState.item.itemMetadata.itemId == itemId else { return false }
            if case .loadingDecoration = selectedItemState.previewState {
                return true
            }
            return false
        case .failed, .none:
            return false
        }
    }

    private func syncPreviewPayloadCacheToDisplayedState() {
        previewPayloadsByItemId.removeAll()

        if let firstPreviewPayload = contentState.firstPreviewPayload {
            cachePreviewPayload(firstPreviewPayload)
        }

        if let selectedItemState {
            let payload = PreviewPayload(
                item: selectedItemState.item,
                decoration: cachedPreviewPayloadDecoration(for: selectedItemState)
            )
            cachePreviewPayload(payload)
        }
    }

    private func itemIdentifier(at index: Int) -> String? {
        guard itemIds.indices.contains(index) else { return nil }
        return itemIds[index]
    }

    private func performItemAction(
        itemId: String,
        handler: @escaping (String, ClipboardContent) -> Void
    ) {
        if let selectedItem, selectedItem.itemMetadata.itemId == itemId {
            handler(selectedItem.itemMetadata.itemId, selectedItem.content)
            return
        }

        if let cachedItem = prefetchCache[itemId] {
            handler(cachedItem.itemMetadata.itemId, cachedItem.content)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            guard let item = await self.client.fetchItem(id: itemId) else { return }
            await MainActor.run {
                handler(item.itemMetadata.itemId, item.content)
            }
        }
    }

    private func setDisplayedSelection(_ selection: SelectionState) {
        os_signpost(.event, log: poi, name: "setDisplayedSelection", "%{public}s", selection.poiLabel)
        selectionState = selection
    }

    private func updateDisplayedResponse(_ response: BrowserSearchResponse) {
        updateDisplayedContent { _ in
            LoadedBrowserContent(response: response)
        }
    }

    private func updateDisplayedResponseForItem(
        itemId: String,
        updatedMetadata: ItemMetadata,
        updatedFirstItem: ClipboardItem,
        updatedPresentation: RowPresentation
    ) {
        guard let response = currentResponse else { return }
        let updatedItems = response.items.map { itemMatch in
            guard itemMatch.itemMetadata.itemId == itemId else { return itemMatch }
            // Clear stale list decoration — Rust will recompute on next search
            return ItemMatch(
                itemMetadata: updatedMetadata,
                presentation: updatedPresentation
            )
        }
        let firstPreviewPayload: PreviewPayload? = {
            guard let currentFirstPreviewPayload = response.firstPreviewPayload,
                  currentFirstPreviewPayload.item.itemMetadata.itemId == itemId
            else {
                return response.firstPreviewPayload
            }
            // Clear stale preview decoration — Rust will recompute on next load
            let updatedPayload = PreviewPayload(
                item: updatedFirstItem,
                decoration: nil
            )
            previewPayloadsByItemId[itemId] = updatedPayload
            return updatedPayload
        }()
        updateDisplayedResponse(BrowserSearchResponse(
            request: response.request,
            items: updatedItems,
            firstPreviewPayload: firstPreviewPayload,
            totalCount: response.totalCount
        ))
    }

    private func updateDisplayedContent(_ transform: (LoadedBrowserContent) -> LoadedBrowserContent) {
        switch contentState {
        case .idle:
            break
        case let .loaded(content):
            contentState = .loaded(transform(content))
        case let .loading(request, previous, phase):
            guard let previous else { return }
            contentState = .loading(request: request, previous: transform(previous), phase: phase)
        case let .failed(request, message, previous):
            guard let previous else { return }
            contentState = .failed(request: request, message: message, previous: transform(previous))
        }
        rebuildDisplayedRows()
    }

    private func rebuildDisplayedRows() {
        let items = contentState.items
        var nextItemIds: [String] = []
        nextItemIds.reserveCapacity(items.count)
        var nextIndexById: [String: Int] = [:]
        nextIndexById.reserveCapacity(items.count)
        var nextDisplayRows: [DisplayRow] = []
        nextDisplayRows.reserveCapacity(items.count)

        for (index, itemMatch) in items.enumerated() {
            let itemId = itemMatch.itemMetadata.itemId
            nextItemIds.append(itemId)
            nextIndexById[itemId] = index
            nextDisplayRows.append(DisplayRow(
                metadata: itemMatch.itemMetadata,
                presentation: presentationApplyingResolvedExcerpt(itemMatch.presentation, itemId: itemId)
            ))
        }

        if itemIds != nextItemIds {
            itemIds = nextItemIds
            itemIndexById = nextIndexById
        }
        if displayRows != nextDisplayRows {
            displayRows = nextDisplayRows
        }
    }

    private func presentationApplyingResolvedExcerpt(_ presentation: RowPresentation, itemId: String) -> RowPresentation {
        guard let excerpt = resolvedMatchedExcerptsByItemId[itemId] else { return presentation }
        switch presentation {
        case .deferred:
            return .matched(excerpt: excerpt)
        case .baseline, .matched, .unavailable:
            return presentation
        }
    }

    private func clearInactiveEdits() {
        guard let selectedItemId else {
            editSession = .inactive
            return
        }

        switch editSession {
        case let .focused(focusedId) where focusedId != selectedItemId:
            editSession = .inactive
        case let .dirty(dirtyId, _) where dirtyId != selectedItemId:
            editSession = .inactive
        default:
            break
        }
    }

    private func finishTagMutationSettleIfNeeded() {
        if case .tagging(.settling) = mutationState {
            pendingTagSettleTask?.cancel()
            pendingTagSettleTask = nil
            mutationState = .idle
        }
    }
}
