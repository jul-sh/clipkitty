import ClipKittyRust
import Foundation
import Observation

@MainActor
@Observable
final class BrowserViewModel {
    private let client: BrowserStoreClient
    private let onSelect: (Int64, ClipboardContent) -> Void
    private let onCopyOnly: (Int64, ClipboardContent) -> Void
    private let onDismiss: () -> Void

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
    private var metadataTask: Task<Void, Never>?
    private var rowDecorationTasks: [String: Task<Void, Never>] = [:]
    private var pendingDeleteTask: Task<Void, Never>?
    private var pendingTagSettleTask: Task<Void, Never>?
    private var queryGeneration = 0
    private var previewGeneration = 0
    private var metadataGeneration = 0
    private var hasAppliedInitialSearch = false
    private var latestKnownContentRevision = 0
    private var lastLoadedContentRevision: Int?

    private(set) var resultsState: BrowserResultsState = .idle(request: SearchRequest(text: "", filter: .all))
    private(set) var selectionState: SelectionState = .none
    private(set) var overlayState: OverlayState = .none
    private(set) var mutationState: MutationState = .idle
    private(set) var editState: EditState = .init()
    private(set) var rowDecorationsByItemId: [Int64: RowDecoration] = [:]
    private var previewPayloadsByItemId: [Int64: PreviewPayload] = [:]
    private(set) var hasUserNavigated = false
    private(set) var prefetchCache: [Int64: ClipboardItem] = [:]
    private(set) var previewSpinnerVisible = false
    private(set) var itemIds: [Int64] = []
    private(set) var displayRows: [DisplayRow] = []
    private var itemIndexById: [Int64: Int] = [:]

    init(
        client: BrowserStoreClient,
        onSelect: @escaping (Int64, ClipboardContent) -> Void,
        onCopyOnly: @escaping (Int64, ClipboardContent) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.client = client
        self.onSelect = onSelect
        self.onCopyOnly = onCopyOnly
        self.onDismiss = onDismiss
    }

    var contentState: BrowserContentState {
        BrowserContentState.combine(resultsState: resultsState, selection: selectionState)
    }

    var searchText: String {
        resultsState.request.text
    }

    var contentTypeFilter: ContentTypeFilter {
        switch resultsState.request.filter {
        case let .contentType(contentType):
            return contentType
        case .all, .tagged:
            return .all
        }
    }

    var selectedTagFilter: ItemTag? {
        if case let .tagged(tag) = resultsState.request.filter {
            return tag
        }
        return nil
    }

    var searchSpinnerVisible: Bool {
        if case let .loading(_, _, .running(spinnerVisible)) = resultsState {
            return spinnerVisible
        }
        return false
    }

    var selection: SelectionState {
        selectionState
    }

    var selectedItemId: Int64? {
        selection.itemId
    }

    var selectedItemState: SelectedItemState? {
        selection.selectedItem
    }

    var selectedItem: ClipboardItem? {
        selectedItemState?.item
    }

    var previewDecoration: PreviewDecoration? {
        guard let selectedItemState else { return nil }
        switch selectedItemState.previewState {
        case .plain, .loading(.missing):
            return nil
        case let .loading(.stale(decoration)), let .highlighted(decoration):
            return decoration
        }
    }

    var selectedIndex: Int? {
        guard let selectedItemId else { return nil }
        return itemIndexById[selectedItemId]
    }

    var itemCount: Int {
        itemIds.count
    }

    var resultsFailureMessage: String? {
        resultsState.failureMessage
    }

    var mutationFailureMessage: String? {
        guard case let .failed(failure) = mutationState else { return nil }
        return failure.message
    }

    var editFocus: EditState.Focus {
        editState.focus
    }

    var pendingEdits: [Int64: String] {
        editState.pendingEdits
    }

    func onAppear(initialSearchQuery: String, contentRevision: Int = 0) {
        latestKnownContentRevision = max(latestKnownContentRevision, contentRevision)
        guard !hasAppliedInitialSearch else { return }
        startInitialSearch(initialSearchQuery: initialSearchQuery, targetContentRevision: latestKnownContentRevision)
    }

    func handleDisplayReset(initialSearchQuery: String, contentRevision: Int = 0) {
        searchExecution.cancel()
        previewTask?.cancel()
        previewTask = nil
        metadataTask?.cancel()
        metadataTask = nil
        rowDecorationTasks.values.forEach { $0.cancel() }
        rowDecorationTasks.removeAll()
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        pendingTagSettleTask?.cancel()
        pendingTagSettleTask = nil
        queryGeneration += 1
        previewGeneration += 1
        metadataGeneration += 1
        latestKnownContentRevision = contentRevision
        lastLoadedContentRevision = nil
        previewSpinnerVisible = false
        hasUserNavigated = false
        prefetchCache.removeAll()
        previewPayloadsByItemId.removeAll()
        rowDecorationsByItemId.removeAll()
        overlayState = .none
        mutationState = .idle
        editState = .init()
        // Preserve displayed content so the fresh search can enter `.loading(previous:)`
        // instead of flashing the empty state while the new results are loading.
        hasAppliedInitialSearch = false
        startInitialSearch(initialSearchQuery: initialSearchQuery, targetContentRevision: contentRevision)
    }

    func handleContentRevisionChange(_ contentRevision: Int, isPanelVisible: Bool) {
        latestKnownContentRevision = max(latestKnownContentRevision, contentRevision)
        guard !isPanelVisible else { return }
        refreshCurrentRequestIfStale()
    }

    func handlePanelVisibilityChange(
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

    func dismiss() {
        onDismiss()
    }

    func updateSearchText(_ value: String) {
        submitSearch(text: value, filter: resultsState.request.filter)
    }

    func setContentTypeFilter(_ filter: ContentTypeFilter) {
        let queryFilter: ItemQueryFilter = filter == .all ? .all : .contentType(contentType: filter)
        submitSearch(text: searchText, filter: queryFilter)
    }

    func setTagFilter(_ tag: ItemTag?) {
        let queryFilter: ItemQueryFilter = tag.map { .tagged(tag: $0) } ?? .all
        submitSearch(text: searchText, filter: queryFilter)
    }

    func openFilterOverlay(highlight: FilterOverlayState) {
        overlayState = .filter(highlight)
    }

    func openActionsOverlay(highlight: MenuHighlightState) {
        overlayState = .actions(highlight)
    }

    func closeOverlay() {
        overlayState = .none
    }

    func dismissMutationFailure() {
        guard case .failed = mutationState else { return }
        mutationState = .idle
    }

    func setFilterOverlayState(_ highlight: FilterOverlayState) {
        overlayState = .filter(highlight)
    }

    func setActionsOverlayState(_ highlight: MenuHighlightState) {
        overlayState = .actions(highlight)
    }

    func moveSelection(by offset: Int) {
        hasUserNavigated = true
        guard let currentIndex = selectedIndex else {
            if let firstItemId = itemIds.first {
                select(itemId: firstItemId, origin: .automatic)
            }
            return
        }
        let newIndex = max(0, min(itemCount - 1, currentIndex + offset))
        guard let itemId = itemIdentifier(at: newIndex) else { return }
        select(itemId: itemId, origin: .user)
    }

    func select(itemId: Int64, origin: SelectionOrigin) {
        if case let .focused(focusedId) = editState.focus, focusedId != itemId {
            editState.focus = .idle
        }
        setDisplayedSelection(.loading(itemId: itemId, origin: origin))
        loadSelectedItem(itemId: itemId, origin: origin)
    }

    func confirmSelection() {
        guard let item = selectedItem else { return }
        let content = effectiveContent(for: item)
        commitCurrentEdit()
        onSelect(item.itemMetadata.itemId, content)
    }

    func confirmItem(itemId: Int64) {
        performItemAction(itemId: itemId, handler: onSelect)
    }

    func copyOnlySelection() {
        guard let item = selectedItem else { return }
        let content = effectiveContent(for: item)
        commitCurrentEdit()
        onCopyOnly(item.itemMetadata.itemId, content)
    }

    func copyOnlyItem(itemId: Int64) {
        performItemAction(itemId: itemId, handler: onCopyOnly)
    }

    func loadRowDecorationsForItems(_ ids: [Int64]) {
        guard displayedResponse != nil else { return }
        let request = resultsState.request
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let uniqueIds = Array(Set(ids)).sorted()
        guard !uniqueIds.isEmpty else { return }

        let itemIdsNeedingDecoration = uniqueIds.filter { rowDecoration(for: $0) == nil }
        guard !itemIdsNeedingDecoration.isEmpty else { return }

        let generation = queryGeneration
        let key = "\(generation)|\(request.text)|\(itemIdsNeedingDecoration.map(String.init).joined(separator: ","))"
        guard rowDecorationTasks[key] == nil else { return }

        rowDecorationTasks[key] = Task { [weak self] in
            guard let self else { return }
            let results = await self.client.loadRowDecorations(itemIds: itemIdsNeedingDecoration, query: request.text)
            await MainActor.run {
                defer { self.rowDecorationTasks[key] = nil }
                guard self.queryGeneration == generation,
                      self.resultsState.request == request
                else {
                    return
                }

                var updates: [Int64: RowDecoration] = [:]
                for result in results {
                    guard let decoration = result.decoration else { continue }
                    guard self.indexOfItem(result.itemId) != nil else { continue }
                    guard self.rowDecoration(for: result.itemId) == nil else { continue }
                    updates[result.itemId] = decoration
                }

                guard !updates.isEmpty else { return }
                self.rowDecorationsByItemId.merge(updates) { existing, _ in existing }
                self.rebuildDisplayedRows()
            }
        }
    }

    func deleteSelectedItem() {
        guard let itemId = selectedItemId else { return }
        deleteItem(itemId: itemId)
    }

    func deleteItem(itemId: Int64) {
        guard case .idle = mutationState else { return }

        let transaction = DeleteTransaction(
            deletedItemId: itemId,
            snapshot: contentState
        )
        mutationState = .deleting(.pending(transaction))

        applyOptimisticDelete(itemId: itemId)
        showDeleteUndoToast()

        pendingDeleteTask?.cancel()
        pendingDeleteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.commitPendingDelete()
            }
        }
    }

    func undoPendingDelete() {
        guard case let .deleting(.pending(transaction)) = mutationState else { return }
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        ToastWindow.shared.dismiss()
        restoreSnapshot(transaction.snapshot)
        mutationState = .idle
    }

    func clearAll() {
        mutationState = .clearing(ClearTransaction(snapshot: contentState))

        let request = resultsState.request
        setResultsState(.loaded(BrowserSearchResponse(
            request: request,
            items: [],
            firstPreviewPayload: nil,
            totalCount: 0
        )))
        setDisplayedSelection(.none)
        rowDecorationsByItemId.removeAll()
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

    func addTagToSelectedItem(_ tag: ItemTag) {
        guard let itemId = selectedItemId else { return }
        mutateItemTag(itemId: itemId, tag: tag, shouldInclude: true)
    }

    func removeTagFromSelectedItem(_ tag: ItemTag) {
        guard let itemId = selectedItemId else { return }
        mutateItemTag(itemId: itemId, tag: tag, shouldInclude: false)
    }

    func addTag(_ tag: ItemTag, toItem itemId: Int64) {
        mutateItemTag(itemId: itemId, tag: tag, shouldInclude: true)
    }

    func removeTag(_ tag: ItemTag, fromItem itemId: Int64) {
        mutateItemTag(itemId: itemId, tag: tag, shouldInclude: false)
    }

    func effectiveContent(for item: ClipboardItem) -> ClipboardContent {
        if let editedText = editState.pendingEdits[item.itemMetadata.itemId] {
            return .text(value: editedText)
        }
        return item.content
    }

    func onTextEdit(_ newText: String, for itemId: Int64, originalText: String) {
        if newText == originalText {
            editState.pendingEdits.removeValue(forKey: itemId)
        } else {
            editState.pendingEdits[itemId] = newText
        }
    }

    func onEditingStateChange(_ isEditing: Bool, for itemId: Int64) {
        if isEditing {
            editState.focus = .focused(itemId: itemId)
        } else if case let .focused(id) = editState.focus, id == itemId {
            editState.focus = .idle
        }
    }

    func discardCurrentEdit() {
        if let id = selectedItemId {
            editState.pendingEdits.removeValue(forKey: id)
        }
        editState.focus = .idle
    }

    func commitCurrentEdit() {
        guard let id = selectedItemId,
              let editedText = editState.pendingEdits.removeValue(forKey: id),
              !editedText.isEmpty
        else {
            editState.focus = .idle
            return
        }
        editState.focus = .idle

        let currentMetadata: ItemMetadata
        let selectionOrigin: SelectionOrigin
        if let selectedItemState {
            currentMetadata = selectedItemState.item.itemMetadata
            selectionOrigin = selectedItemState.origin
        } else if let previewPayload = previewPayloadsByItemId[id] {
            currentMetadata = previewPayload.item.itemMetadata
            selectionOrigin = selection.origin ?? .automatic
        } else if let cachedItem = prefetchCache[id] {
            currentMetadata = cachedItem.itemMetadata
            selectionOrigin = selection.origin ?? .automatic
        } else if let firstPreviewPayload = resultsState.firstPreviewPayload,
                  firstPreviewPayload.item.itemMetadata.itemId == id
        {
            currentMetadata = firstPreviewPayload.item.itemMetadata
            selectionOrigin = selection.origin ?? .automatic
        } else if let displayedMetadata = displayedMetadata(for: id) {
            currentMetadata = displayedMetadata
            selectionOrigin = selection.origin ?? .automatic
        } else {
            ToastWindow.shared.show(message: String(localized: "Saved"))
            return
        }

        previewTask?.cancel()
        previewTask = nil
        previewGeneration += 1
        previewSpinnerVisible = false

        let updatedContent = ClipboardContent.text(value: editedText)
        let updatedSnippet = String(editedText.prefix(200))
        let updatedMetadata = ItemMetadata(
            itemId: currentMetadata.itemId,
            icon: currentMetadata.icon,
            snippet: updatedSnippet,
            sourceApp: currentMetadata.sourceApp,
            sourceAppBundleId: currentMetadata.sourceAppBundleId,
            timestampUnix: currentMetadata.timestampUnix,
            tags: currentMetadata.tags
        )
        let updatedItem = ClipboardItem(itemMetadata: updatedMetadata, content: updatedContent)
        let updatedPreviewState: SelectedPreviewState = .plain
        previewPayloadsByItemId[id] = PreviewPayload(item: updatedItem, decoration: nil)
        prefetchCache[id] = updatedItem

        setDisplayedSelection(.selected(SelectedItemState(
            item: updatedItem,
            origin: selectionOrigin,
            previewState: updatedPreviewState
        )))
        updateDisplayedResponseForItem(
            itemId: id,
            updatedMetadata: updatedMetadata,
            updatedFirstItem: updatedItem
        )

        ToastWindow.shared.show(message: String(localized: "Saved"))

        Task { [weak self] in
            guard let self else { return }
            _ = await self.client.updateTextItem(itemId: id, text: editedText)
        }
    }

    enum PreviewInteractionMode: Equatable {
        case browsing
        case previewing(itemId: Int64)
        case editing(itemId: Int64)
    }

    var previewInteractionMode: PreviewInteractionMode {
        guard let id = selectedItemId else { return .browsing }
        if editState.pendingEdits[id] != nil {
            return .editing(itemId: id)
        }
        if editState.focus == .focused(itemId: id) {
            return .previewing(itemId: id)
        }
        return .browsing
    }

    var selectedItemHasPendingEdit: Bool {
        guard let id = selectedItemId else { return false }
        return editState.pendingEdits[id] != nil
    }

    var isEditingPreview: Bool {
        guard let id = selectedItemId else { return false }
        return editState.focus == .focused(itemId: id) || editState.pendingEdits[id] != nil
    }

    func hasPendingEdit(for itemId: Int64) -> Bool {
        editState.pendingEdits[itemId] != nil
    }

    func performAction(
        _ action: BrowserActionItem,
        itemId: Int64,
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
        guard lastLoadedContentRevision != latestKnownContentRevision || displayedResponse == nil else { return }
        guard searchExecution.request != resultsState.request ||
            searchExecution.targetContentRevision != latestKnownContentRevision
        else {
            return
        }
        submitSearch(request: resultsState.request, targetContentRevision: latestKnownContentRevision)
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
        prefetchCache.removeAll()
        previewPayloadsByItemId.removeAll()
        rowDecorationsByItemId.removeAll()
        rebuildDisplayedRows()
        searchExecution.cancel()
        rowDecorationTasks.values.forEach { $0.cancel() }
        rowDecorationTasks.removeAll()

        setDisplayedSelection(resetSelection(selectionState, for: request))
        setResultsState(.loading(
            request: request,
            previous: displayedResponse,
            phase: .debouncing
        ))

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
        setResultsState(.loading(
            request: request,
            previous: displayedResponse,
            phase: .running(spinnerVisible: false)
        ))

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
            break
        case let .failure(error):
            guard case let .loading(request, previous, _) = resultsState else { return }
            setResultsState(.failed(
                request: request,
                message: error.localizedDescription,
                previous: previous
            ))
        }
    }

    private func applySearchResponse(_ response: BrowserSearchResponse, targetContentRevision: Int) {
        guard resultsState.request == response.request else { return }
        let response = responseApplyingPendingMutations(response)
        cachePreviewPayload(response.firstPreviewPayload)
        lastLoadedContentRevision = targetContentRevision

        let previousOrder = itemIds
        let previousSelection = selection
        let previousSelectedItemState = selectedItemState

        setResultsState(.loaded(response))

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
        itemId: Int64,
        origin: SelectionOrigin,
        response: BrowserSearchResponse,
        previousSelectedItemState: SelectedItemState?
    ) {
        if let firstPreviewPayload = response.firstPreviewPayload,
           firstPreviewPayload.item.itemMetadata.itemId == itemId,
           isPreviewPayloadReady(firstPreviewPayload, for: response.request)
        {
            cachePreviewPayload(firstPreviewPayload)
            setDisplayedSelection(.selected(makeSelectedItemState(for: firstPreviewPayload, origin: origin)))
            return
        }

        if let cachedPreviewPayload = previewPayloadsByItemId[itemId],
           isPreviewPayloadReady(cachedPreviewPayload, for: response.request)
        {
            setDisplayedSelection(.selected(makeSelectedItemState(for: cachedPreviewPayload, origin: origin)))
            return
        }

        if let previousSelectedItemState,
           previousSelectedItemState.item.itemMetadata.itemId == itemId
        {
            if requiresAtomicPreviewLoad(for: previousSelectedItemState.item, request: response.request) {
                if let staleSelectedItemState = makeStaleLoadingSelectedItemState(
                    from: previousSelectedItemState,
                    origin: origin
                ) {
                    setDisplayedSelection(.selected(staleSelectedItemState))
                    loadSelectedItem(itemId: itemId, origin: origin)
                    return
                }
            } else {
                let payload = PreviewPayload(item: previousSelectedItemState.item, decoration: nil)
                cachePreviewPayload(payload)
                setDisplayedSelection(.selected(makeSelectedItemState(for: payload, origin: origin)))
                return
            }
        }

        if let cachedItem = prefetchCache[itemId],
           !requiresAtomicPreviewLoad(for: cachedItem, request: response.request)
        {
            let payload = PreviewPayload(item: cachedItem, decoration: nil)
            cachePreviewPayload(payload)
            setDisplayedSelection(.selected(makeSelectedItemState(for: payload, origin: origin)))
            return
        }

        setDisplayedSelection(.loading(itemId: itemId, origin: origin))
        loadSelectedItem(itemId: itemId, origin: origin)
    }

    private func loadSelectedItem(itemId: Int64, origin: SelectionOrigin) {
        previewTask?.cancel()
        metadataTask?.cancel()
        previewGeneration += 1
        let generation = previewGeneration
        let request = resultsState.request

        if let firstPreviewPayload = resultsState.firstPreviewPayload,
           firstPreviewPayload.item.itemMetadata.itemId == itemId,
           isPreviewPayloadReady(firstPreviewPayload, for: request)
        {
            cachePreviewPayload(firstPreviewPayload)
            setDisplayedSelection(.selected(makeSelectedItemState(for: firstPreviewPayload, origin: origin)))
            prefetchAdjacentItems(around: itemId)
            maybeRefreshLinkMetadata(for: firstPreviewPayload.item, generation: generation)
            return
        }

        if let cachedPreviewPayload = previewPayloadsByItemId[itemId],
           isPreviewPayloadReady(cachedPreviewPayload, for: request)
        {
            setDisplayedSelection(.selected(makeSelectedItemState(for: cachedPreviewPayload, origin: origin)))
            prefetchAdjacentItems(around: itemId)
            maybeRefreshLinkMetadata(for: cachedPreviewPayload.item, generation: generation)
            return
        }

        if let cachedItem = prefetchCache[itemId],
           !requiresAtomicPreviewLoad(for: cachedItem, request: request)
        {
            let payload = PreviewPayload(item: cachedItem, decoration: nil)
            cachePreviewPayload(payload)
            setDisplayedSelection(.selected(makeSelectedItemState(for: payload, origin: origin)))
            prefetchAdjacentItems(around: itemId)
            maybeRefreshLinkMetadata(for: cachedItem, generation: generation)
            return
        }

        let retainsStalePreview: Bool
        if let selectedItemState,
           selectedItemState.item.itemMetadata.itemId == itemId,
           case .loading(.stale) = selectedItemState.previewState
        {
            retainsStalePreview = true
        } else {
            retainsStalePreview = false
        }

        if !retainsStalePreview {
            setDisplayedSelection(.loading(itemId: itemId, origin: origin))
        }
        schedulePreviewSpinner(for: generation, itemId: itemId)

        previewTask = Task { [weak self] in
            guard let self else { return }
            let payload = await self.client.loadPreviewPayload(itemId: itemId, query: request.text)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.previewGeneration == generation,
                      self.resultsState.request == request,
                      self.selectedItemId == itemId
                else {
                    return
                }

                self.previewSpinnerVisible = false
                if let payload {
                    self.cachePreviewPayload(payload)
                    self.setDisplayedSelection(.selected(self.makeSelectedItemState(for: payload, origin: origin)))
                    self.prefetchAdjacentItems(around: itemId)
                    self.maybeRefreshLinkMetadata(for: payload.item, generation: generation)
                } else {
                    self.setDisplayedSelection(.failed(itemId: itemId, origin: origin))
                }
            }
        }
    }

    private func maybeRefreshLinkMetadata(for item: ClipboardItem, generation: Int) {
        guard case let .link(url, metadataState) = item.content,
              case .pending = metadataState,
              AppSettings.shared.generateLinkPreviews
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
                    snippet: updatedItem.itemMetadata.snippet,
                    sourceApp: updatedItem.itemMetadata.sourceApp,
                    sourceAppBundleId: updatedItem.itemMetadata.sourceAppBundleId,
                    timestampUnix: updatedItem.itemMetadata.timestampUnix,
                    tags: currentTags
                )
                let mergedPreviewItem = ClipboardItem(itemMetadata: mergedPreviewMetadata, content: updatedItem.content)
                let updatedPreviewPayload = PreviewPayload(
                    item: mergedPreviewItem,
                    decoration: self.previewDecoration
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
                    updatedFirstItem: mergedPreviewItem
                )
            }
        }
    }

    private func prefetchAdjacentItems(around itemId: Int64) {
        guard let currentIndex = indexOfItem(itemId) else { return }
        var idsToPrefetch: [Int64] = []
        if currentIndex > 0 {
            idsToPrefetch.append(itemIds[currentIndex - 1])
        }
        if currentIndex + 1 < itemIds.count {
            idsToPrefetch.append(itemIds[currentIndex + 1])
        }

        Task { [weak self] in
            guard let self else { return }
            for itemId in idsToPrefetch where self.prefetchCache[itemId] == nil {
                guard let item = await self.client.fetchItem(id: itemId) else { continue }
                await MainActor.run {
                    if self.indexOfItem(itemId) != nil {
                        self.prefetchCache[itemId] = item
                    }
                }
            }
        }
    }

    private func showSearchSpinnerIfNeeded(operationId: UUID, request: SearchRequest) {
        guard searchExecution.id == operationId,
              case let .loading(currentRequest, previous, .running(spinnerVisible: false)) = resultsState,
              currentRequest == request
        else {
            return
        }
        setResultsState(.loading(
            request: currentRequest,
            previous: previous,
            phase: .running(spinnerVisible: true)
        ))
    }

    private func schedulePreviewSpinner(for generation: Int, itemId: Int64) {
        previewSpinnerVisible = false
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            await MainActor.run {
                guard let self,
                      self.previewGeneration == generation,
                      self.selectedItemId == itemId,
                      self.isPreviewAwaitingPayload(for: itemId)
                else {
                    return
                }
                self.previewSpinnerVisible = true
            }
        }
    }

    private func applyOptimisticDelete(itemId: Int64) {
        guard let response = currentResponse else { return }
        let filteredItems = response.items.filter { $0.itemMetadata.itemId != itemId }
        rowDecorationsByItemId.removeValue(forKey: itemId)
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

        Task { [weak self] in
            guard let self else { return }
            let result = await self.client.delete(itemId: transaction.deletedItemId)
            await MainActor.run {
                switch result {
                case .success:
                    if case let .deleting(.committing(activeTransaction)) = self.mutationState,
                       activeTransaction.deletedItemId == transaction.deletedItemId
                    {
                        self.mutationState = .idle
                    }
                case let .failure(error):
                    self.restoreDeleteFailure(error: error)
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
        restoreSnapshot(transaction.snapshot)
        mutationState = .failed(ActionFailure(message: error.localizedDescription))
    }

    private func showDeleteUndoToast() {
        ToastWindow.shared.show(
            message: String(localized: "Deleted"),
            iconSystemName: "trash",
            iconColor: .secondaryLabelColor,
            actionTitle: String(localized: "Undo")
        ) { [weak self] in
            self?.undoPendingDelete()
        }
    }

    private func restoreClearFailure(error: ClipboardError) {
        guard case let .clearing(transaction) = mutationState else { return }
        restoreSnapshot(transaction.snapshot)
        mutationState = .failed(ActionFailure(message: error.localizedDescription))
    }

    private func restoreSnapshot(_ snapshot: BrowserContentState) {
        switch snapshot {
        case let .idle(request):
            setResultsState(.idle(request: request))
            setDisplayedSelection(.none)
        case let .loading(request, previous, phase):
            setResultsState(.loading(request: request, previous: previous?.response, phase: phase))
            setDisplayedSelection(previous?.selection ?? .none)
        case let .loaded(content):
            setResultsState(.loaded(content.response))
            setDisplayedSelection(content.selection)
        case let .failed(request, message, previous):
            setResultsState(.failed(request: request, message: message, previous: previous?.response))
            setDisplayedSelection(previous?.selection ?? .none)
        }
        rowDecorationsByItemId = Dictionary(
            uniqueKeysWithValues: snapshot.items.compactMap { itemMatch in
                itemMatch.rowDecoration.map { (itemMatch.itemMetadata.itemId, $0) }
            }
        )
        rebuildDisplayedRows()
        syncPreviewPayloadCacheToDisplayedState()
        clearInactiveEdits()
    }

    private func nextSelectionAfterDelete(deleting _: Int64) -> Int64? {
        guard let currentIndex = selectedIndex else { return nil }
        if currentIndex + 1 < itemCount {
            return itemIdentifier(at: currentIndex + 1)
        }
        if currentIndex > 0 {
            return itemIdentifier(at: currentIndex - 1)
        }
        return nil
    }

    private var displayedResponse: BrowserSearchResponse? {
        resultsState.displayedResponse
    }

    private var currentResponse: BrowserSearchResponse? {
        displayedResponse
    }

    private func responseApplyingPendingMutations(_ response: BrowserSearchResponse) -> BrowserSearchResponse {
        switch mutationState {
        case let .deleting(.pending(transaction)), let .deleting(.committing(transaction)):
            return responseHidingDeletedItem(response, deletedItemId: transaction.deletedItemId)
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

    private func responseHidingDeletedItem(_ response: BrowserSearchResponse, deletedItemId: Int64) -> BrowserSearchResponse {
        guard response.items.contains(where: { $0.itemMetadata.itemId == deletedItemId }) else {
            return response
        }

        let filteredItems = response.items.filter { $0.itemMetadata.itemId != deletedItemId }
        let filteredFirstPreviewPayload = response.firstPreviewPayload?.item.itemMetadata.itemId == deletedItemId
            ? nil
            : response.firstPreviewPayload

        return BrowserSearchResponse(
            request: response.request,
            items: filteredItems,
            firstPreviewPayload: filteredFirstPreviewPayload,
            totalCount: max(0, response.totalCount - 1)
        )
    }

    private func mutateItemTag(itemId: Int64, tag: ItemTag, shouldInclude: Bool) {
        let snapshot = contentState

        pendingTagSettleTask?.cancel()
        pendingTagSettleTask = nil
        let transaction = TagMutationTransaction(itemId: itemId, tag: tag, shouldInclude: shouldInclude)
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
                    self.restoreSnapshot(snapshot)
                    self.mutationState = .failed(ActionFailure(message: error.localizedDescription))
                }
            }
        }
    }

    private func applyOptimisticTagMutation(itemId: Int64, tag: ItemTag, shouldInclude: Bool) {
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
                    decoration: previewDecoration
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

    private func scheduleTagMutationSettleFallback(itemId: Int64, tag: ItemTag, shouldInclude: Bool) {
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
        itemId: Int64,
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
                rowDecorationsByItemId.removeValue(forKey: itemMatch.itemMetadata.itemId)
                previewPayloadsByItemId.removeValue(forKey: itemMatch.itemMetadata.itemId)
                prefetchCache.removeValue(forKey: itemMatch.itemMetadata.itemId)
                return nil
            }

            return ItemMatch(itemMetadata: updatedMetadata, rowDecoration: itemMatch.rowDecoration)
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
            snippet: metadata.snippet,
            sourceApp: metadata.sourceApp,
            sourceAppBundleId: metadata.sourceAppBundleId,
            timestampUnix: metadata.timestampUnix,
            tags: updatedTags
        )
    }

    func rowDecoration(for itemId: Int64) -> RowDecoration? {
        guard let index = itemIndexById[itemId], displayRows.indices.contains(index) else {
            return nil
        }
        return displayRows[index].rowDecoration
    }

    private func makeSelectedItemState(
        for payload: PreviewPayload,
        origin: SelectionOrigin
    ) -> SelectedItemState {
        return SelectedItemState(
            item: payload.item,
            origin: origin,
            previewState: payload.decoration.map(SelectedPreviewState.highlighted) ?? .plain
        )
    }

    private func makeStaleLoadingSelectedItemState(
        from selectedItemState: SelectedItemState,
        origin: SelectionOrigin
    ) -> SelectedItemState? {
        let loadingState: LoadingPreviewState
        switch selectedItemState.previewState {
        case let .highlighted(decoration):
            loadingState = .stale(decoration)
        case let .loading(.stale(decoration)):
            loadingState = .stale(decoration)
        case .plain, .loading(.missing):
            return nil
        }

        return SelectedItemState(
            item: selectedItemState.item,
            origin: origin,
            previewState: .loading(loadingState)
        )
    }

    private func requiresAtomicPreviewLoad(for item: ClipboardItem, request: SearchRequest) -> Bool {
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

    private func resetSelection(_ selection: SelectionState, for request: SearchRequest) -> SelectionState {
        guard let selectedItem = selection.selectedItem else { return selection }
        if requiresAtomicPreviewLoad(for: selectedItem.item, request: request) {
            if let staleSelectedItem = makeStaleLoadingSelectedItemState(
                from: selectedItem,
                origin: selectedItem.origin
            ) {
                return .selected(staleSelectedItem)
            }
            return .loading(
                itemId: selectedItem.item.itemMetadata.itemId,
                origin: selectedItem.origin
            )
        }

        return .selected(selectedItem)
    }

    private func cachePreviewPayload(_ payload: PreviewPayload?) {
        guard let payload else { return }
        let itemId = payload.item.itemMetadata.itemId
        previewPayloadsByItemId[itemId] = payload
        prefetchCache[itemId] = payload.item
    }

    private func isPreviewPayloadReady(_ payload: PreviewPayload, for request: SearchRequest) -> Bool {
        !requiresAtomicPreviewLoad(for: payload.item, request: request) || payload.decoration != nil
    }

    private func isPreviewAwaitingPayload(for itemId: Int64) -> Bool {
        switch selection {
        case let .loading(loadingItemId, _):
            return loadingItemId == itemId
        case let .selected(selectedItemState):
            guard selectedItemState.item.itemMetadata.itemId == itemId else { return false }
            if case .loading = selectedItemState.previewState {
                return true
            }
            return false
        case .failed, .none:
            return false
        }
    }

    private func syncPreviewPayloadCacheToDisplayedState() {
        previewPayloadsByItemId.removeAll()

        if let firstPreviewPayload = resultsState.firstPreviewPayload {
            cachePreviewPayload(firstPreviewPayload)
        }

        if let selectedItemState {
            let payload = PreviewPayload(
                item: selectedItemState.item,
                decoration: previewDecoration
            )
            cachePreviewPayload(payload)
        }
    }

    private func itemIdentifier(at index: Int) -> Int64? {
        guard itemIds.indices.contains(index) else { return nil }
        return itemIds[index]
    }

    func indexOfItem(_ itemId: Int64?) -> Int? {
        guard let itemId else { return nil }
        return itemIndexById[itemId]
    }

    private func displayedMetadata(for itemId: Int64) -> ItemMetadata? {
        guard let index = itemIndexById[itemId], displayRows.indices.contains(index) else {
            return nil
        }
        return displayRows[index].metadata
    }

    private func performItemAction(
        itemId: Int64,
        handler: @escaping (Int64, ClipboardContent) -> Void
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
        selectionState = selection
    }

    private func updateDisplayedResponse(_ response: BrowserSearchResponse) {
        switch resultsState {
        case .idle:
            break
        case .loaded:
            setResultsState(.loaded(response))
        case let .loading(request, _, phase):
            setResultsState(.loading(request: request, previous: response, phase: phase))
        case let .failed(request, message, _):
            setResultsState(.failed(request: request, message: message, previous: response))
        }
    }

    private func updateDisplayedResponseForItem(
        itemId: Int64,
        updatedMetadata: ItemMetadata,
        updatedFirstItem: ClipboardItem
    ) {
        guard let response = currentResponse else { return }
        let updatedItems = response.items.map { itemMatch in
            guard itemMatch.itemMetadata.itemId == itemId else { return itemMatch }
            return ItemMatch(
                itemMetadata: updatedMetadata,
                rowDecoration: itemMatch.rowDecoration
            )
        }
        let firstPreviewPayload: PreviewPayload? = {
            guard let currentFirstPreviewPayload = response.firstPreviewPayload,
                  currentFirstPreviewPayload.item.itemMetadata.itemId == itemId
            else {
                return response.firstPreviewPayload
            }
            let updatedPayload = PreviewPayload(
                item: updatedFirstItem,
                decoration: currentFirstPreviewPayload.decoration
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

    private func setResultsState(_ state: BrowserResultsState) {
        resultsState = state
        rebuildDisplayedRows()
    }

    private func rebuildDisplayedRows() {
        let items = resultsState.items
        var nextItemIds: [Int64] = []
        nextItemIds.reserveCapacity(items.count)
        var nextIndexById: [Int64: Int] = [:]
        nextIndexById.reserveCapacity(items.count)
        var nextDisplayRows: [DisplayRow] = []
        nextDisplayRows.reserveCapacity(items.count)

        for (index, itemMatch) in items.enumerated() {
            let itemId = itemMatch.itemMetadata.itemId
            nextItemIds.append(itemId)
            nextIndexById[itemId] = index
            nextDisplayRows.append(DisplayRow(
                metadata: itemMatch.itemMetadata,
                rowDecoration: rowDecorationsByItemId[itemId] ?? itemMatch.rowDecoration
            ))
        }

        itemIds = nextItemIds
        itemIndexById = nextIndexById
        displayRows = nextDisplayRows
    }

    private func clearInactiveEdits() {
        guard let selectedItemId else {
            editState.pendingEdits.removeAll()
            editState.focus = .idle
            return
        }

        editState.pendingEdits = editState.pendingEdits.filter { $0.key == selectedItemId }
        if case let .focused(focusedId) = editState.focus, focusedId != selectedItemId {
            editState.focus = .idle
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
