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
    private let showSnackbarNotification: (NotificationRequest) -> Void
    private let dismissSnackbarNotification: () -> Void
    /// How long a pending delete stays undoable before committing; injectable
    /// so tests don't have to wait out the real undo window.
    private let deleteCommitDelay: TimeInterval
    /// How long the user must pause typing before a new filter suggestion
    /// surfaces; injectable so tests don't race the real delay.
    private let pendingFilterSurfaceDelay: TimeInterval

    private struct SearchContext: Equatable {
        let request: SearchRequest
        let targetContentRevision: Int
    }

    private enum SearchExecution {
        case idle
        case debouncing(
            token: UUID,
            context: SearchContext,
            task: Task<Void, Never>
        )
        case running(
            token: UUID,
            context: SearchContext,
            operation: BrowserSearchOperation,
            observer: Task<Void, Never>,
            spinner: Task<Void, Never>
        )

        var context: SearchContext? {
            switch self {
            case .idle:
                return nil
            case let .debouncing(_, context, _), let .running(_, context, _, _, _):
                return context
            }
        }

        mutating func cancel() {
            switch self {
            case .idle:
                break
            case let .debouncing(_, _, task):
                task.cancel()
            case let .running(_, _, operation, observer, spinner):
                operation.cancel()
                observer.cancel()
                spinner.cancel()
            }
            self = .idle
        }
    }

    private enum TextSaveFollowUp {
        case showSavedNotification
        case performSelectionAction(action: @MainActor () -> Void)
    }

    private struct PreviewRequest: Equatable {
        let token = UUID()
        let itemId: String
        let searchRequest: SearchRequest
    }

    private var searchExecution: SearchExecution = .idle
    private var activePreviewRequest: PreviewRequest?
    private var previewTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var previewSpinnerTask: Task<Void, Never>?
    #if ENABLE_LINK_PREVIEWS
        private var metadataTask: Task<Void, Never>?
    #endif
    private var matchedExcerptTasks: [String: Task<Void, Never>] = [:]
    private var pendingMatchedExcerptItemIds: Set<String> = []
    private var pendingFilterSurfaceTask: Task<Void, Never>?
    private var pendingDeleteTask: Task<Void, Never>?
    private var pendingTagSettleTask: Task<Void, Never>?
    private var queryGeneration = 0
    private var selectionGeneration = 0
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
        showSnackbarNotification: @escaping (NotificationRequest) -> Void = { _ in },
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
    /// keyboard only while the user has arrowed up onto it — or while the
    /// result list is empty, where Enter would otherwise be inert.
    public var keyboardTarget: BrowserKeyboardTarget {
        if case let .suggested(suggestion, keyboardTarget: .suggestion) = pendingFilterState {
            return .pendingFilterChip(suggestion)
        }
        return .results
    }

    /// The keyboard target a suggestion receives when no explicit user choice
    /// applies: with rows to select the chip is opt-in; over an empty list
    /// Enter would be inert, so the chip takes the keyboard. Only a LOADED
    /// empty list grants the chip — while a search is still running the
    /// outcome is unknown, and ``applySearchResponse`` promotes the chip if
    /// the load comes up empty.
    private var restingPendingFilterKeyboardTarget: PendingFilterKeyboardTarget {
        if case .loaded = contentState, itemIds.isEmpty {
            return .suggestion
        }
        return .results
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
        selectedItemState?.previewState.decoration
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
        resetMutationStateUnlessInFlight()
        if case .saving = mutationState {
            // The save task still owns this draft. Its completion will either
            // settle it or restore it after a failure.
        } else {
            editSession = .inactive
        }
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
        resetMutationStateUnlessInFlight()
        if case .saving = mutationState {
            // Preserve the draft until the in-flight write settles.
        } else {
            editSession = .inactive
        }
        hasUserNavigated = false
        // A stale user-chosen `.suggestion` keyboard target must not survive a
        // hide/show cycle; the suggestion itself stays valid for the request.
        if case let .suggested(suggestion, _) = pendingFilterState {
            pendingFilterState = .suggested(suggestion, keyboardTarget: restingPendingFilterKeyboardTarget)
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

    /// In-flight persistence must survive display resets. Each completion
    /// validates its transaction identity before changing observable state.
    private func resetMutationStateUnlessInFlight() {
        switch mutationState {
        case .saving, .deleting(.committing):
            break
        case .idle, .deleting(.pending), .tagging, .clearing, .failed:
            mutationState = .idle
        }
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
                    // Reaching the chip is user navigation, so it earns the
                    // accent — an automatic grant over an empty list does not.
                    hasUserNavigated = true
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
        switch origin {
        case .click, .keyboard:
            if case let .suggested(suggestion, keyboardTarget: .suggestion) = pendingFilterState {
                pendingFilterState = .suggested(suggestion, keyboardTarget: .results)
            }
        case .automatic:
            break
        }

        switch editSession {
        case let .focused(focusedId) where focusedId != itemId:
            editSession = .inactive
        case let .dirty(dirtyId, draft) where dirtyId != itemId:
            editSession = .suspendedDirty(itemId: dirtyId, draft: draft)
        case let .suspendedDirty(dirtyId, draft) where dirtyId == itemId:
            editSession = .dirty(itemId: dirtyId, draft: draft)
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
            performSelectedItemAction(item, handler: onSelect)
        }
    }

    public func confirmItem(itemId: String) {
        performItemAction(itemId: itemId, handler: onSelect)
    }

    public func copyOnlySelection() {
        guard let item = selectedItem else { return }
        performSelectedItemAction(item, handler: onCopyOnly)
    }

    public func copyOnlyItem(itemId: String) {
        performItemAction(itemId: itemId, handler: onCopyOnly)
    }

    /// Routes actions on the selected row through persistence when that row
    /// owns an unsaved draft. The callback is then part of the save
    /// transaction and cannot paste or dismiss the browser until persistence
    /// succeeds. A draft owned by another row blocks the action rather than
    /// being silently discarded by the resulting display reset.
    private func performSelectedItemAction(
        _ item: ClipboardItem,
        handler: @escaping (String, ClipboardContent) -> Void
    ) {
        let itemId = item.itemMetadata.itemId
        switch editSession {
        case let .dirty(dirtyItemId, draft) where dirtyItemId == itemId:
            beginCurrentEditSave(followUp: .performSelectionAction {
                handler(itemId, .text(value: draft))
            })
        case .dirty, .suspendedDirty:
            return
        case .inactive, .focused:
            handler(itemId, item.content)
        }
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
        editSession = .inactive
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
        guard case .text = item.content else { return item.content }

        switch editSession {
        case let .dirty(dirtyId, draft) where dirtyId == item.itemMetadata.itemId:
            return .text(value: draft)
        case let .suspendedDirty(dirtyId, draft) where dirtyId == item.itemMetadata.itemId:
            return .text(value: draft)
        case .inactive, .focused, .dirty, .suspendedDirty:
            return item.content
        }
    }

    public func onTextEdit(
        _ newText: String,
        for itemId: String,
        originalContent: ClipboardContent
    ) {
        guard case let .text(originalText) = originalContent else { return }

        switch editSession {
        case let .dirty(dirtyId, _) where dirtyId != itemId,
             let .suspendedDirty(dirtyId, _) where dirtyId != itemId:
            // Only one draft may exist at a time. The owner must be saved or
            // discarded before another item's preview can enter edit mode.
            return
        case .inactive, .focused, .dirty, .suspendedDirty:
            break
        }

        if case let .saving(transaction) = mutationState,
           transaction.itemId == itemId
        {
            // Until the write settles, its draft is the prospective persisted
            // baseline. Keep an equal value dirty so failure can still return
            // that unsaved text to the user; a different value is a newer edit
            // that the older completion must not discard.
            editSession = .dirty(itemId: itemId, draft: newText)
            return
        }

        if newText == originalText {
            // Text matches original — drop back to focused (not dirty)
            editSession = .focused(itemId: itemId)
        } else {
            editSession = .dirty(itemId: itemId, draft: newText)
        }
    }

    public func onEditingStateChange(_ isEditing: Bool, for itemId: String) {
        if isEditing {
            switch editSession {
            case let .dirty(dirtyId, _) where dirtyId == itemId:
                return
            case let .suspendedDirty(dirtyId, draft) where dirtyId == itemId:
                editSession = .dirty(itemId: dirtyId, draft: draft)
            case .dirty, .suspendedDirty:
                // Preserve the existing draft until its owner is selected.
                return
            case .inactive, .focused:
                editSession = .focused(itemId: itemId)
            }
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
        beginCurrentEditSave(followUp: .showSavedNotification)
    }

    private func beginCurrentEditSave(followUp: TextSaveFollowUp) {
        guard case let .dirty(id, editedText) = editSession else { return }

        switch mutationState {
        case .idle, .failed:
            break
        case .saving, .deleting, .tagging, .clearing:
            return
        }

        // A dirty draft can survive navigation to another row. Only the row
        // that owns the draft may commit it, otherwise metadata from the
        // current selection could be paired with the wrong item identifier.
        guard let selectedItemState,
              selectedItemState.item.itemMetadata.itemId == id
        else {
            return
        }

        let currentItem = selectedItemState.item
        let contentSnapshot = contentState
        let selectionSnapshot = selectionState
        let previewPayloadSnapshot = SnapshotValue(previewPayloadsByItemId[id])
        let resolvedExcerptSnapshot = SnapshotValue(resolvedMatchedExcerptsByItemId[id])
        let prefetchedItemSnapshot = SnapshotValue(prefetchCache[id])
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

        let transaction = TextSaveTransaction(
            id: UUID(),
            itemId: id,
            draft: editedText,
            itemSnapshot: currentItem,
            contentSnapshot: contentSnapshot,
            selectionSnapshot: selectionSnapshot,
            previewPayloadSnapshot: previewPayloadSnapshot,
            resolvedExcerptSnapshot: resolvedExcerptSnapshot,
            prefetchedItemSnapshot: prefetchedItemSnapshot,
            queryGeneration: queryGeneration,
            selectionGeneration: selectionGeneration
        )
        mutationState = .saving(transaction)

        Task { [weak self] in
            guard let self else { return }
            let result = await self.client.updateTextItem(itemId: id, text: editedText)
            await MainActor.run {
                guard self.finishTextSave(transactionID: transaction.id, result: result) else {
                    return
                }

                switch followUp {
                case .showSavedNotification:
                    self.showSnackbarNotification(.passive(
                        message: String(localized: "Saved"),
                        iconSystemName: "checkmark.circle.fill"
                    ))
                case let .performSelectionAction(action):
                    guard transaction.queryGeneration == self.queryGeneration else { return }
                    action()
                }
            }
        }
    }

    private func finishTextSave(
        transactionID: UUID,
        result: Result<Void, ClipboardError>
    ) -> Bool {
        guard case let .saving(transaction) = mutationState,
              transaction.id == transactionID
        else { return false }

        switch result {
        case .success:
            mutationState = .idle
            switch editSession {
            case let .dirty(itemId, draft), let .suspendedDirty(itemId, draft):
                guard itemId == transaction.itemId, draft == transaction.draft else {
                    return false
                }
                editSession = .inactive
                return true
            case .inactive, .focused:
                // A different draft was authored while this save was in
                // flight (or the edit was explicitly discarded). Keep the
                // current user state and do not run a stale paste action.
                return false
            }

        case let .failure(error):
            if queryGeneration == transaction.queryGeneration {
                let selection = selectionGeneration == transaction.selectionGeneration
                    ? transaction.selectionSnapshot
                    : nil
                restoreSnapshot(transaction.contentSnapshot, selection: selection)
                restoreCacheEntry(
                    transaction.previewPayloadSnapshot,
                    key: transaction.itemId,
                    in: &previewPayloadsByItemId
                )
                restoreCacheEntry(
                    transaction.resolvedExcerptSnapshot,
                    key: transaction.itemId,
                    in: &resolvedMatchedExcerptsByItemId
                )
                restoreCacheEntry(
                    transaction.prefetchedItemSnapshot,
                    key: transaction.itemId,
                    in: &prefetchCache
                )
            }

            switch editSession {
            case let .dirty(itemId, draft)
                where itemId == transaction.itemId && draft != transaction.draft,
                 let .suspendedDirty(itemId, draft)
                     where itemId == transaction.itemId && draft != transaction.draft:
                // Preserve a newer draft instead of replacing it with the
                // failed transaction's older value.
                break
            case .inactive, .focused, .dirty, .suspendedDirty:
                editSession = selectedItemId == transaction.itemId
                    ? .dirty(itemId: transaction.itemId, draft: transaction.draft)
                    : .suspendedDirty(itemId: transaction.itemId, draft: transaction.draft)
            }
            mutationState = .failed(ActionFailure(message: error.localizedDescription))
            return false
        }
    }

    private func restoreCacheEntry<Key: Hashable, Value>(
        _ snapshot: SnapshotValue<Value>,
        key: Key,
        in cache: inout [Key: Value]
    ) {
        switch snapshot {
        case .absent:
            cache.removeValue(forKey: key)
        case let .present(value):
            cache[key] = value
        }
    }

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
        guard searchExecution.context?.request != contentState.request ||
            searchExecution.context?.targetContentRevision != latestKnownContentRevision
        else {
            return
        }
        submitSearch(request: contentState.request, targetContentRevision: latestKnownContentRevision)
    }

    private func cancelInFlightWork() {
        searchExecution.cancel()
        cancelPreviewWork()
        matchedExcerptTasks.values.forEach { $0.cancel() }
        matchedExcerptTasks.removeAll()
        pendingMatchedExcerptItemIds.removeAll()
        pendingFilterSurfaceTask?.cancel()
        pendingFilterSurfaceTask = nil
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        pendingTagSettleTask?.cancel()
        pendingTagSettleTask = nil
        queryGeneration += 1
        cancelPreviewSpinner()
    }

    /// Re-derives the pending suggestion whenever a search is submitted, so
    /// the chip always reflects the request the user actually sees.
    ///
    /// A suggestion that is already visible for the same filter updates in
    /// place so the chip doesn't flicker while the trigger token grows
    /// ("ima" → "imag"), but the keyboard always returns to the results: a
    /// query change means the user is typing again, so Enter must address the
    /// first real result even if they had arrowed up onto the chip. If the new
    /// load comes up empty, ``applySearchResponse`` promotes the chip again.
    /// A NEW suggestion only
    /// surfaces after the user pauses typing for ``pendingFilterSurfaceDelay``,
    /// so intermediate prefixes mid-word don't flash the chip; it surfaces
    /// with the results keeping the keyboard — the user opts into the chip
    /// with Up from the first row — unless the list is empty, in which case
    /// the chip takes the keyboard so Return isn't inert.
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

        if case let .suggested(current, _) = pendingFilterState,
           current.kind == suggestion.kind
        {
            pendingFilterState = .suggested(suggestion, keyboardTarget: .results)
            return
        }

        pendingFilterState = .none
        let delay = pendingFilterSurfaceDelay
        pendingFilterSurfaceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.contentState.request == request else { return }
                self.pendingFilterState = .suggested(
                    suggestion,
                    keyboardTarget: self.restingPendingFilterKeyboardTarget
                )
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
        cancelPreviewSpinner()

        if displayedContent?.response.request != request {
            setDisplayedSelection(selectionDuringSearchTransition(to: request))
        }
        contentState = .loading(request: request, previous: displayedContent, phase: .debouncing)
        rebuildDisplayedRows()

        scheduleSearch(
            context: SearchContext(
                request: request,
                targetContentRevision: targetContentRevision
            ),
            debounce: request.text.isEmpty ? nil : .milliseconds(50)
        )
    }

    private func scheduleSearch(
        context: SearchContext,
        debounce: Duration?
    ) {
        searchExecution.cancel()

        guard let debounce else {
            beginSearch(context: context, expectedDebounceToken: nil)
            return
        }

        let token = UUID()
        let task = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.beginSearch(context: context, expectedDebounceToken: token)
        }
        searchExecution = .debouncing(token: token, context: context, task: task)
    }

    private func beginSearch(
        context: SearchContext,
        expectedDebounceToken: UUID?
    ) {
        // A cancelled debounce can resume after a newer identical request has
        // been submitted. Its token, not request equality, owns the transition.
        switch (expectedDebounceToken, searchExecution) {
        case (nil, .idle):
            break
        case let (token?, .debouncing(currentToken, currentContext, _))
            where token == currentToken && context == currentContext:
            break
        default:
            return
        }

        let operation = client.startSearch(request: context.request)
        let token = UUID()
        contentState = .loading(
            request: context.request,
            previous: displayedContent,
            phase: .runningWaitingForSpinner
        )
        rebuildDisplayedRows()

        let observer = Task { [weak self] in
            let outcome = await operation.awaitOutcome()
            guard !Task.isCancelled else { return }
            self?.completeSearch(token: token, context: context, outcome: outcome)
        }
        let spinner = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.showSearchSpinnerIfNeeded(token: token, request: context.request)
        }
        searchExecution = .running(
            token: token,
            context: context,
            operation: operation,
            observer: observer,
            spinner: spinner
        )
    }

    private func completeSearch(
        token: UUID,
        context: SearchContext,
        outcome: BrowserSearchOutcome
    ) {
        guard case let .running(currentToken, _, _, _, spinner) = searchExecution,
              currentToken == token
        else { return }

        spinner.cancel()
        searchExecution = .idle
        applySearchOutcome(outcome, context: context)
    }

    private func applySearchOutcome(
        _ outcome: BrowserSearchOutcome,
        context: SearchContext
    ) {
        switch outcome {
        case let .success(response):
            applySearchResponse(response, targetContentRevision: context.targetContentRevision)
        case .cancelled:
            // The execution-token guard passed, so this cancellation came
            // from outside the view model. Re-run the same request instead of
            // stranding the reducer in a loading state.
            guard case let .loading(request, _, _) = contentState else { return }
            scheduleSearch(
                context: SearchContext(
                    request: request,
                    targetContentRevision: context.targetContentRevision
                ),
                debounce: nil
            )
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
            // The results came up empty after the suggestion surfaced: with
            // nothing to select, Enter would be inert, so the chip takes the
            // keyboard. Only then — with rows present the chip stays opt-in.
            if case let .suggested(suggestion, keyboardTarget: .results) = pendingFilterState {
                pendingFilterState = .suggested(suggestion, keyboardTarget: .suggestion)
            }
            reconcileEditSessionWithSelection()
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
            setDisplayedSelection(.loading(
                itemId: nextItemId,
                origin: .automatic,
                phase: .waitingForSpinner
            ))
            loadSelectedItem(itemId: nextItemId, origin: .automatic)
            reconcileEditSessionWithSelection()
            finishTagMutationSettleIfNeeded()
            return
        }

        refreshSelection(
            itemId: previousSelectedItemId,
            origin: previousOrigin,
            response: response,
            previousSelectedItemState: previousSelectedItemState
        )
        reconcileEditSessionWithSelection()
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

        setDisplayedSelection(.loading(
            itemId: itemId,
            origin: origin,
            phase: .waitingForSpinner
        ))
        loadSelectedItem(itemId: itemId, origin: origin)
    }

    private func loadSelectedItem(itemId: String, origin: SelectionOrigin) {
        let signpostID = OSSignpostID(log: poi)
        os_signpost(.begin, log: poi, name: "loadSelectedItem", signpostID: signpostID, "itemId=%{public}s", itemId)
        defer { os_signpost(.end, log: poi, name: "loadSelectedItem", signpostID: signpostID) }

        let request = contentState.request
        let selectionRequest = beginPreviewRequest(
            itemId: itemId,
            searchRequest: request
        )

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
            prefetchAdjacentItems(around: itemId, selectionRequest: selectionRequest)
            #if ENABLE_LINK_PREVIEWS
                maybeRefreshLinkMetadata(for: firstPreviewPayload.item, selectionRequest: selectionRequest)
            #endif
            cancelPreviewSpinner()
            guard !previewPayloadSatisfiesDecorationRequirement(firstPreviewPayload, for: request) else {
                return
            }
            schedulePreviewSpinner(for: selectionRequest)
            loadPreviewDecoration(origin: origin, selectionRequest: selectionRequest)
            return
        }

        if let cachedPreviewPayload = previewPayloadsByItemId[itemId] {
            setDisplayedSelection(.selected(makeSelectedItemState(
                for: cachedPreviewPayload,
                origin: origin,
                request: request,
                previousDecoration: carriedPreviewDecoration(for: itemId)
            )))
            prefetchAdjacentItems(around: itemId, selectionRequest: selectionRequest)
            #if ENABLE_LINK_PREVIEWS
                maybeRefreshLinkMetadata(for: cachedPreviewPayload.item, selectionRequest: selectionRequest)
            #endif
            cancelPreviewSpinner()
            guard !previewPayloadSatisfiesDecorationRequirement(cachedPreviewPayload, for: request) else {
                return
            }
            schedulePreviewSpinner(for: selectionRequest)
            loadPreviewDecoration(origin: origin, selectionRequest: selectionRequest)
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
            schedulePreviewSpinner(for: selectionRequest)
            loadPreviewDecoration(origin: origin, selectionRequest: selectionRequest)
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
            prefetchAdjacentItems(around: itemId, selectionRequest: selectionRequest)
            #if ENABLE_LINK_PREVIEWS
                maybeRefreshLinkMetadata(for: cachedItem, selectionRequest: selectionRequest)
            #endif
            cancelPreviewSpinner()
            guard requiresPreviewDecoration(for: cachedItem, request: request) else {
                return
            }
            schedulePreviewSpinner(for: selectionRequest)
            loadPreviewDecoration(origin: origin, selectionRequest: selectionRequest)
            return
        }

        setDisplayedSelection(.loading(
            itemId: itemId,
            origin: origin,
            phase: .waitingForSpinner
        ))
        schedulePreviewSpinner(for: selectionRequest)

        previewTask = Task { [weak self] in
            guard let self else { return }
            let item = await self.client.fetchItem(id: selectionRequest.itemId)
            guard !Task.isCancelled,
                  self.activePreviewRequest == selectionRequest,
                  self.contentState.request == selectionRequest.searchRequest,
                  case let .loading(loadingItemId, _, decorationLoadPhase) = self.selectionState,
                  loadingItemId == selectionRequest.itemId
            else { return }

            self.previewTask = nil

            guard let item else {
                self.cancelPreviewSpinner()
                self.setDisplayedSelection(.failed(itemId: selectionRequest.itemId, origin: origin))
                return
            }

            let payload = PreviewPayload(item: item, decoration: nil)
            self.cachePreviewPayload(payload)
            self.setDisplayedSelection(.selected(self.makeSelectedItemState(
                for: payload,
                origin: origin,
                request: selectionRequest.searchRequest,
                decorationLoadPhase: decorationLoadPhase
            )))
            self.prefetchAdjacentItems(
                around: selectionRequest.itemId,
                selectionRequest: selectionRequest
            )
            #if ENABLE_LINK_PREVIEWS
                self.maybeRefreshLinkMetadata(for: item, selectionRequest: selectionRequest)
            #endif

            guard self.requiresPreviewDecoration(for: item, request: selectionRequest.searchRequest) else {
                self.cancelPreviewSpinner()
                return
            }

            self.loadPreviewDecoration(origin: origin, selectionRequest: selectionRequest)
        }
    }

    private func loadPreviewDecoration(
        origin: SelectionOrigin,
        selectionRequest: PreviewRequest
    ) {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            guard let self else { return }
            let payload = await self.client.loadPreviewPayload(
                itemId: selectionRequest.itemId,
                query: selectionRequest.searchRequest.text
            )
            guard !Task.isCancelled,
                  self.activePreviewRequest == selectionRequest,
                  self.contentState.request == selectionRequest.searchRequest,
                  self.selectedItemId == selectionRequest.itemId
            else { return }

            self.previewTask = nil

            self.cancelPreviewSpinner()
            guard let payload else {
                self.resolveSelectionWithoutPreviewDecoration(
                    itemId: selectionRequest.itemId,
                    origin: origin
                )
                return
            }

            self.cachePreviewPayload(payload)
            if self.previewPayloadSatisfiesDecorationRequirement(payload, for: selectionRequest.searchRequest) {
                self.setDisplayedSelection(.selected(self.makeSelectedItemState(
                    for: payload,
                    origin: origin,
                    request: selectionRequest.searchRequest,
                    previousDecoration: self.carriedPreviewDecoration(for: selectionRequest.itemId)
                )))
            } else {
                self.setDisplayedSelection(.selected(SelectedItemState(
                    item: payload.item,
                    origin: origin,
                    previewState: .plain
                )))
            }
            self.prefetchAdjacentItems(
                around: selectionRequest.itemId,
                selectionRequest: selectionRequest
            )
            #if ENABLE_LINK_PREVIEWS
                self.maybeRefreshLinkMetadata(for: payload.item, selectionRequest: selectionRequest)
            #endif
        }
    }

    #if ENABLE_LINK_PREVIEWS
        private func maybeRefreshLinkMetadata(
            for item: ClipboardItem,
            selectionRequest: PreviewRequest
        ) {
            guard case let .link(url, metadataState) = item.content,
                  case .pending = metadataState,
                  shouldGenerateLinkPreviews()
            else {
                return
            }

            metadataTask?.cancel()
            metadataTask = Task { [weak self] in
                guard let self else { return }
                let updatedItem = await self.client.fetchLinkMetadata(
                    url: url,
                    itemId: selectionRequest.itemId
                )
                guard !Task.isCancelled,
                      self.activePreviewRequest == selectionRequest,
                      self.selectedItemId == selectionRequest.itemId,
                      let updatedItem,
                      let selectedItemState = self.selectedItemState
                else { return }

                self.metadataTask = nil

                let currentTags = self.selectedItem?.itemMetadata.tags ?? updatedItem.itemMetadata.tags
                let mergedPreviewMetadata = ItemMetadata(
                    itemId: updatedItem.itemMetadata.itemId,
                    icon: updatedItem.itemMetadata.icon,
                    sourceApp: updatedItem.itemMetadata.sourceApp,
                    sourceAppBundleId: updatedItem.itemMetadata.sourceAppBundleId,
                    timestampUnix: updatedItem.itemMetadata.timestampUnix,
                    tags: currentTags
                )
                let mergedPreviewItem = ClipboardItem(
                    itemMetadata: mergedPreviewMetadata,
                    content: updatedItem.content
                )
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
    #endif

    private let prefetchRadius = 5

    private func beginPreviewRequest(
        itemId: String,
        searchRequest: SearchRequest
    ) -> PreviewRequest {
        cancelPreviewWork()
        let request = PreviewRequest(itemId: itemId, searchRequest: searchRequest)
        activePreviewRequest = request
        return request
    }

    private func cancelPreviewWork() {
        previewTask?.cancel()
        previewTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        previewSpinnerTask?.cancel()
        previewSpinnerTask = nil
        #if ENABLE_LINK_PREVIEWS
            metadataTask?.cancel()
            metadataTask = nil
        #endif
        activePreviewRequest = nil
    }

    private func prefetchAdjacentItems(
        around itemId: String,
        selectionRequest: PreviewRequest
    ) {
        guard let currentIndex = indexOfItem(itemId) else { return }
        let start = max(0, currentIndex - prefetchRadius)
        let end = min(itemIds.count - 1, currentIndex + prefetchRadius)
        guard start <= end else { return }
        let idsToPrefetch = (start ... end).map { itemIds[$0] }.filter { prefetchCache[$0] == nil }
        guard !idsToPrefetch.isEmpty else { return }

        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            for itemId in idsToPrefetch {
                guard !Task.isCancelled else { return }
                guard let item = await self.client.fetchItem(id: itemId) else { continue }
                guard !Task.isCancelled,
                      self.activePreviewRequest == selectionRequest
                else { return }
                if self.indexOfItem(itemId) != nil {
                    self.prefetchCache[itemId] = item
                }
            }
            self.prefetchTask = nil
        }
    }

    private func showSearchSpinnerIfNeeded(token: UUID, request: SearchRequest) {
        guard case let .running(currentToken, _, _, _, _) = searchExecution,
              currentToken == token,
              case let .loading(currentRequest, previous, .runningWaitingForSpinner) = contentState,
              currentRequest == request
        else {
            return
        }
        contentState = .loading(
            request: currentRequest,
            previous: previous,
            phase: .runningShowingSpinner
        )
    }

    private func cancelPreviewSpinner() {
        previewSpinnerTask?.cancel()
        previewSpinnerTask = nil

        switch selectionState {
        case .none, .failed:
            return
        case let .loading(itemId, origin, phase):
            switch phase {
            case .waitingForSpinner:
                return
            case .showingSpinner:
                setDisplayedSelection(.loading(
                    itemId: itemId,
                    origin: origin,
                    phase: .waitingForSpinner
                ))
            }
        case let .selected(selectedItemState):
            switch selectedItemState.previewState {
            case .plain, .highlighted:
                return
            case let .loadingDecoration(previous, phase):
                switch phase {
                case .waitingForSpinner:
                    return
                case .showingSpinner:
                    setDisplayedSelection(.selected(SelectedItemState(
                        item: selectedItemState.item,
                        origin: selectedItemState.origin,
                        previewState: .loadingDecoration(
                            previous: previous,
                            phase: .waitingForSpinner
                        )
                    )))
                }
            }
        }
    }

    private func schedulePreviewSpinner(
        for selectionRequest: PreviewRequest
    ) {
        cancelPreviewSpinner()
        previewSpinnerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            guard let self,
                  self.activePreviewRequest == selectionRequest,
                  self.contentState.request == selectionRequest.searchRequest
            else { return }

            self.previewSpinnerTask = nil

            switch self.selectionState {
            case .none, .failed:
                return
            case let .loading(itemId, origin, phase):
                guard itemId == selectionRequest.itemId else { return }
                switch phase {
                case .waitingForSpinner:
                    self.setDisplayedSelection(.loading(
                        itemId: itemId,
                        origin: origin,
                        phase: .showingSpinner
                    ))
                case .showingSpinner:
                    return
                }
            case let .selected(selectedItemState):
                guard selectedItemState.item.itemMetadata.itemId == selectionRequest.itemId else {
                    return
                }
                switch selectedItemState.previewState {
                case .plain, .highlighted:
                    return
                case let .loadingDecoration(previous, phase):
                    switch phase {
                    case .waitingForSpinner:
                        self.setDisplayedSelection(.selected(SelectedItemState(
                            item: selectedItemState.item,
                            origin: selectedItemState.origin,
                            previewState: .loadingDecoration(
                                previous: previous,
                                phase: .showingSpinner
                            )
                        )))
                    case .showingSpinner:
                        return
                    }
                }
            }
        }
    }

    private func applyOptimisticDelete(itemId: String) {
        discardEdit(for: itemId)
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
            setDisplayedSelection(.loading(
                itemId: nextSelection,
                origin: .automatic,
                phase: .waitingForSpinner
            ))
            loadSelectedItem(itemId: nextSelection, origin: .automatic)
        } else if deletedSelectedItem {
            setDisplayedSelection(.none)
        }
        reconcileEditSessionWithSelection()
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
                actionTitle: String(localized: "Undo"),
                action: { [weak self] in
                    self?.undoPendingDelete()
                }
            )
        )
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
        reconcileEditSessionWithSelection()
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
        case .idle, .saving, .clearing, .failed:
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
        reconcileEditSessionWithSelection()
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
        previousDecoration: PreviewDecoration? = nil,
        decorationLoadPhase: PreviewLoadPhase = .waitingForSpinner
    ) -> SelectedItemState {
        let previewState: SelectedPreviewState
        if let decoration = payload.decoration {
            previewState = .highlighted(decoration)
        } else if requiresPreviewDecoration(for: payload.item, request: request) {
            previewState = .loadingDecoration(
                previous: previousDecoration,
                phase: decorationLoadPhase
            )
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
        case let .loadingDecoration(previous, .waitingForSpinner),
             let .loadingDecoration(previous, .showingSpinner):
            previousDecoration = previous
        case .plain:
            previousDecoration = nil
        }

        return SelectedItemState(
            item: selectedItemState.item,
            origin: origin,
            previewState: .loadingDecoration(
                previous: previousDecoration,
                phase: .waitingForSpinner
            )
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
        case let .loading(itemId, origin, .waitingForSpinner),
             let .loading(itemId, origin, .showingSpinner):
            return .loading(
                itemId: itemId,
                origin: origin,
                phase: .waitingForSpinner
            )
        case .failed, .none:
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
        case .plain:
            return nil
        case .loadingDecoration(_, .waitingForSpinner),
             .loadingDecoration(_, .showingSpinner):
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
            performSelectedItemAction(selectedItem, handler: handler)
            return
        }

        switch editSession {
        case .dirty, .suspendedDirty:
            return
        case .inactive, .focused:
            break
        }

        if let cachedItem = prefetchCache[itemId] {
            performSelectedItemAction(cachedItem, handler: handler)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            guard let item = await self.client.fetchItem(id: itemId) else { return }
            await MainActor.run {
                // Re-check edit ownership after the fetch. A draft may have
                // started while this item was loading, and that draft must
                // not be discarded by a late callback.
                self.performSelectedItemAction(item, handler: handler)
            }
        }
    }

    private func setDisplayedSelection(_ selection: SelectionState) {
        os_signpost(.event, log: poi, name: "setDisplayedSelection", "%{public}s", selection.poiLabel)
        selectionGeneration &+= 1
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

    private func reconcileEditSessionWithSelection() {
        switch editSession {
        case let .focused(focusedId) where focusedId != selectedItemId:
            editSession = .inactive
        case let .dirty(dirtyId, draft) where selectedItemId != dirtyId:
            editSession = .suspendedDirty(itemId: dirtyId, draft: draft)
        case let .suspendedDirty(dirtyId, draft) where selectedItemId == dirtyId:
            editSession = .dirty(itemId: dirtyId, draft: draft)
        default:
            break
        }
    }

    private func discardEdit(for itemId: String) {
        switch editSession {
        case let .focused(editingItemId) where editingItemId == itemId:
            editSession = .inactive
        case let .dirty(editingItemId, _) where editingItemId == itemId:
            editSession = .inactive
        case let .suspendedDirty(editingItemId, _) where editingItemId == itemId:
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
