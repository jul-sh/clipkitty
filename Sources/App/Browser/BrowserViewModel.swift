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
        case debouncing(request: SearchRequest, task: Task<Void, Never>)
        case running(id: UUID, operation: BrowserSearchOperation, observer: Task<Void, Never>, spinner: Task<Void, Never>?)

        var id: UUID? {
            guard case let .running(id, _, _, _) = self else { return nil }
            return id
        }

        mutating func cancel() {
            switch self {
            case .idle:
                break
            case let .debouncing(_, task):
                task.cancel()
            case let .running(_, operation, observer, spinner):
                operation.cancel()
                observer.cancel()
                spinner?.cancel()
            }
            self = .idle
        }
    }

    private var searchExecution: SearchExecution = .idle
    private var previewTask: Task<Void, Never>?
    private var previewDecorationTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var rowDecorationTasks: [String: Task<Void, Never>] = [:]
    private var pendingDeleteTask: Task<Void, Never>?
    private var pendingTagSettleTask: Task<Void, Never>?
    private var queryGeneration = 0
    private var previewGeneration = 0
    private var metadataGeneration = 0
    private var hasAppliedInitialSearch = false

    private(set) var contentState: BrowserContentState = .idle(request: SearchRequest(text: "", filter: .all))
    private(set) var overlayState: OverlayState = .none
    private(set) var mutationState: MutationState = .idle
    private(set) var editState: EditState = .init()
    private(set) var rowDecorationsByItemId: [Int64: RowDecoration] = [:]
    private(set) var hasUserNavigated = false
    private(set) var prefetchCache: [Int64: ClipboardItem] = [:]
    private(set) var previewSpinnerVisible = false

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

    var searchText: String {
        contentState.request.text
    }

    var contentTypeFilter: ContentTypeFilter {
        switch contentState.request.filter {
        case let .contentType(contentType):
            return contentType
        case .all, .tagged:
            return .all
        }
    }

    var selectedTagFilter: ItemTag? {
        if case let .tagged(tag) = contentState.request.filter {
            return tag
        }
        return nil
    }

    var searchSpinnerVisible: Bool {
        contentState.isSearchSpinnerVisible
    }

    var itemIds: [Int64] {
        contentState.items.map { $0.itemMetadata.itemId }
    }

    var selection: SelectionState {
        contentState.selection
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
        guard case let .loaded(decoration) = selectedItemState.decorationState else { return nil }
        return decoration
    }

    var selectedIndex: Int? {
        guard let selectedItemId else { return nil }
        return itemIds.firstIndex(of: selectedItemId)
    }

    var itemCount: Int {
        itemIds.count
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

    func onAppear(initialSearchQuery: String) {
        guard !hasAppliedInitialSearch else { return }
        hasAppliedInitialSearch = true
        submitSearch(text: initialSearchQuery, filter: .all)
    }

    func handleDisplayReset(initialSearchQuery: String) {
        searchExecution.cancel()
        previewTask?.cancel()
        previewTask = nil
        previewDecorationTask?.cancel()
        previewDecorationTask = nil
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
        previewSpinnerVisible = false
        hasUserNavigated = false
        prefetchCache.removeAll()
        rowDecorationsByItemId.removeAll()
        overlayState = .none
        mutationState = .idle
        editState = .init()
        contentState = .idle(request: SearchRequest(text: "", filter: .all))
        hasAppliedInitialSearch = false
        onAppear(initialSearchQuery: initialSearchQuery)
    }

    func dismiss() {
        onDismiss()
    }

    func updateSearchText(_ value: String) {
        submitSearch(text: value, filter: contentState.request.filter)
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
        guard displayedContent != nil else { return }
        let request = contentState.request
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
                      self.contentState.request == request
                else {
                    return
                }

                var updates: [Int64: RowDecoration] = [:]
                for result in results {
                    guard let decoration = result.decoration else { continue }
                    guard self.itemIds.contains(result.itemId) else { continue }
                    guard self.rowDecoration(for: result.itemId) == nil else { continue }
                    updates[result.itemId] = decoration
                }

                guard !updates.isEmpty else { return }
                self.rowDecorationsByItemId.merge(updates) { existing, _ in existing }
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

        let request = contentState.request
        contentState = .loaded(LoadedBrowserContent(
            response: BrowserSearchResponse(
                request: request,
                items: [],
                firstItem: nil,
                totalCount: 0
            ),
            selection: .none
        ))
        rowDecorationsByItemId.removeAll()
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

        guard let selectedItemState else {
            ToastWindow.shared.show(message: String(localized: "Saved"))
            return
        }

        let currentItem = selectedItemState.item
        let updatedContent = ClipboardContent.text(value: editedText)
        let updatedSnippet = String(editedText.prefix(200))
        let updatedMetadata = ItemMetadata(
            itemId: currentItem.itemMetadata.itemId,
            icon: currentItem.itemMetadata.icon,
            snippet: updatedSnippet,
            sourceApp: currentItem.itemMetadata.sourceApp,
            sourceAppBundleId: currentItem.itemMetadata.sourceAppBundleId,
            timestampUnix: currentItem.itemMetadata.timestampUnix,
            tags: currentItem.itemMetadata.tags
        )
        let updatedItem = ClipboardItem(itemMetadata: updatedMetadata, content: updatedContent)

        setDisplayedSelection(.selected(SelectedItemState(
            item: updatedItem,
            origin: selectedItemState.origin,
            decorationState: selectedItemState.decorationState
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

    private func submitSearch(text rawText: String, filter: ItemQueryFilter) {
        let request = SearchRequest(text: rawText, filter: filter)

        queryGeneration += 1
        hasUserNavigated = false
        prefetchCache.removeAll()
        rowDecorationsByItemId.removeAll()
        searchExecution.cancel()
        previewDecorationTask?.cancel()
        previewDecorationTask = nil
        rowDecorationTasks.values.forEach { $0.cancel() }
        rowDecorationTasks.removeAll()

        let previous = displayedContent.map { resetDecoration(in: $0, for: request.text) }
        contentState = .loading(request: request, previous: previous, phase: .debouncing)

        if request.text.isEmpty {
            beginSearch(request: request)
            return
        }

        let debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.beginSearch(request: request)
            }
        }
        searchExecution = .debouncing(request: request, task: debounceTask)
    }

    private func beginSearch(request: SearchRequest) {
        let operation = client.startSearch(request: request)
        let operationId = UUID()
        contentState = .loading(request: request, previous: displayedContent, phase: .running(spinnerVisible: false))

        let observer = Task { [weak self] in
            guard let self else { return }
            let outcome = await operation.awaitOutcome()
            await MainActor.run {
                self.applySearchOutcome(outcome, operationId: operationId)
            }
        }

        let spinner = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.showSearchSpinnerIfNeeded(operationId: operationId, request: request)
            }
        }

        searchExecution = .running(id: operationId, operation: operation, observer: observer, spinner: spinner)
    }

    private func applySearchOutcome(_ outcome: BrowserSearchOutcome, operationId: UUID) {
        guard searchExecution.id == operationId else { return }
        searchExecution = .idle

        switch outcome {
        case let .success(response):
            applySearchResponse(response)
        case .cancelled:
            break
        case let .failure(error):
            guard case let .loading(request, previous, _) = contentState else { return }
            contentState = .failed(
                request: request,
                message: error.localizedDescription,
                previous: previous
            )
        }
    }

    private func applySearchResponse(_ response: BrowserSearchResponse) {
        guard contentState.request == response.request else { return }
        let response = responseApplyingPendingMutations(response)

        let previousOrder = itemIds
        let previousSelection = selection
        let previousSelectedItem = selectedItem

        contentState = .loaded(LoadedBrowserContent(response: response, selection: .none))

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
            previousSelectedItem: previousSelectedItem
        )
        clearInactiveEdits()
        finishTagMutationSettleIfNeeded()
    }

    private func refreshSelection(
        itemId: Int64,
        origin: SelectionOrigin,
        response: BrowserSearchResponse,
        previousSelectedItem: ClipboardItem?
    ) {
        if let firstItem = response.firstItem,
           firstItem.itemMetadata.itemId == itemId
        {
            setDisplayedSelection(.selected(makeSelectedItemState(for: firstItem, origin: origin, request: response.request)))
            loadPreviewDecorationIfNeeded(itemId: itemId, request: response.request)
            return
        }

        if let previousSelectedItem,
           previousSelectedItem.itemMetadata.itemId == itemId
        {
            setDisplayedSelection(.selected(makeSelectedItemState(for: previousSelectedItem, origin: origin, request: response.request)))
            loadPreviewDecorationIfNeeded(itemId: itemId, request: response.request)
            return
        }

        if let cachedItem = prefetchCache[itemId] {
            setDisplayedSelection(.selected(makeSelectedItemState(for: cachedItem, origin: origin, request: response.request)))
            loadPreviewDecorationIfNeeded(itemId: itemId, request: response.request)
            return
        }

        setDisplayedSelection(.loading(itemId: itemId, origin: origin))
        loadSelectedItem(itemId: itemId, origin: origin)
    }

    private func loadSelectedItem(itemId: Int64, origin: SelectionOrigin) {
        previewTask?.cancel()
        previewDecorationTask?.cancel()
        metadataTask?.cancel()
        previewGeneration += 1
        let generation = previewGeneration
        let request = contentState.request

        if let firstItem = contentState.firstItem,
           firstItem.itemMetadata.itemId == itemId
        {
            setDisplayedSelection(.selected(makeSelectedItemState(for: firstItem, origin: origin, request: request)))
            loadPreviewDecorationIfNeeded(itemId: itemId, request: request)
            prefetchAdjacentItems(around: itemId)
            maybeRefreshLinkMetadata(for: firstItem, generation: generation)
            return
        }

        if let cachedItem = prefetchCache[itemId] {
            setDisplayedSelection(.selected(makeSelectedItemState(for: cachedItem, origin: origin, request: request)))
            loadPreviewDecorationIfNeeded(itemId: itemId, request: request)
            prefetchAdjacentItems(around: itemId)
            maybeRefreshLinkMetadata(for: cachedItem, generation: generation)
            return
        }

        setDisplayedSelection(.loading(itemId: itemId, origin: origin))
        schedulePreviewSpinner(for: generation, itemId: itemId)

        previewTask = Task { [weak self] in
            guard let self else { return }
            let item = await self.client.fetchItem(id: itemId)
            await MainActor.run {
                guard self.previewGeneration == generation,
                      self.selectedItemId == itemId
                else {
                    return
                }

                self.previewSpinnerVisible = false
                if let item {
                    self.setDisplayedSelection(.selected(self.makeSelectedItemState(for: item, origin: origin, request: self.contentState.request)))
                    self.loadPreviewDecorationIfNeeded(itemId: itemId, request: self.contentState.request)
                    self.prefetchAdjacentItems(around: itemId)
                    self.maybeRefreshLinkMetadata(for: item, generation: generation)
                } else {
                    self.setDisplayedSelection(.failed(itemId: itemId, origin: origin))
                }
            }
        }
    }

    private func loadPreviewDecorationIfNeeded(itemId: Int64, request: SearchRequest) {
        previewDecorationTask?.cancel()
        let decorationState = previewDecorationState(for: request.text)
        updateSelectedDecorationState(decorationState, for: itemId)

        guard case .loading = decorationState else { return }
        let generation = queryGeneration
        previewDecorationTask = Task { [weak self] in
            guard let self else { return }
            let decoration = await self.client.loadPreviewDecoration(itemId: itemId, query: request.text)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.queryGeneration == generation,
                      self.contentState.request == request,
                      self.selectedItemId == itemId,
                      let decoration
                else {
                    return
                }
                self.updateSelectedDecorationState(.loaded(decoration), for: itemId)
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

                self.setDisplayedSelection(.selected(SelectedItemState(
                    item: mergedPreviewItem,
                    origin: selectedItemState.origin,
                    decorationState: selectedItemState.decorationState
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
        guard let currentIndex = itemIds.firstIndex(of: itemId) else { return }
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
                    if self.itemIds.contains(itemId) {
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

    private func schedulePreviewSpinner(for generation: Int, itemId: Int64) {
        previewSpinnerVisible = false
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            await MainActor.run {
                guard let self,
                      self.previewGeneration == generation,
                      self.selectedItemId == itemId,
                      case .loading = self.selection
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
        let deletedSelectedItem = selectedItemId == itemId
        let nextSelection = deletedSelectedItem ? nextSelectionAfterDelete(deleting: itemId) : nil
        updateDisplayedResponse(BrowserSearchResponse(
            request: response.request,
            items: filteredItems,
            firstItem: response.firstItem?.itemMetadata.itemId == itemId ? nil : response.firstItem,
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
        contentState = snapshot
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

    private var displayedContent: LoadedBrowserContent? {
        contentState.displayedContent
    }

    private var currentResponse: BrowserSearchResponse? {
        displayedContent?.response
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
        let filteredFirstItem = response.firstItem?.itemMetadata.itemId == deletedItemId
            ? nil
            : response.firstItem

        return BrowserSearchResponse(
            request: response.request,
            items: filteredItems,
            firstItem: filteredFirstItem,
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
                setDisplayedSelection(.selected(SelectedItemState(
                    item: ClipboardItem(itemMetadata: updatedMetadata, content: selectedItemState.item.content),
                    origin: selectedItemState.origin,
                    decorationState: selectedItemState.decorationState
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
                return nil
            }

            return ItemMatch(itemMetadata: updatedMetadata, rowDecoration: itemMatch.rowDecoration)
        }

        let updatedFirstItem = response.firstItem.flatMap { firstItem -> ClipboardItem? in
            guard firstItem.itemMetadata.itemId == itemId else { return firstItem }
            let updatedMetadata = applyingTagMutation(
                to: firstItem.itemMetadata,
                tag: tag,
                shouldInclude: shouldInclude
            )
            if case let .tagged(activeTag) = response.request.filter,
               activeTag == tag,
               !updatedMetadata.tags.contains(tag)
            {
                return nil
            }
            return ClipboardItem(itemMetadata: updatedMetadata, content: firstItem.content)
        }

        return BrowserSearchResponse(
            request: response.request,
            items: updatedItems,
            firstItem: updatedFirstItem,
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
        if let decoration = rowDecorationsByItemId[itemId] {
            return decoration
        }
        return contentState.items.first { $0.itemMetadata.itemId == itemId }?.rowDecoration
    }

    private func makeSelectedItemState(
        for item: ClipboardItem,
        origin: SelectionOrigin,
        request: SearchRequest
    ) -> SelectedItemState {
        SelectedItemState(
            item: item,
            origin: origin,
            decorationState: previewDecorationState(for: request.text)
        )
    }

    private func previewDecorationState(for query: String) -> PreviewDecorationState {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .loading(query: query)
    }

    private func resetDecoration(in content: LoadedBrowserContent, for query: String) -> LoadedBrowserContent {
        guard let selectedItem = content.selection.selectedItem else { return content }
        return LoadedBrowserContent(
            response: content.response,
            selection: .selected(SelectedItemState(
                item: selectedItem.item,
                origin: selectedItem.origin,
                decorationState: previewDecorationState(for: query)
            ))
        )
    }

    private func updateSelectedDecorationState(_ decorationState: PreviewDecorationState, for itemId: Int64) {
        guard let selectedItemState,
              selectedItemState.item.itemMetadata.itemId == itemId
        else {
            return
        }

        setDisplayedSelection(.selected(SelectedItemState(
            item: selectedItemState.item,
            origin: selectedItemState.origin,
            decorationState: decorationState
        )))
    }

    private func itemIdentifier(at index: Int) -> Int64? {
        guard itemIds.indices.contains(index) else { return nil }
        return itemIds[index]
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
        updateDisplayedContent { content in
            LoadedBrowserContent(response: content.response, selection: selection)
        }
    }

    private func updateDisplayedResponse(_ response: BrowserSearchResponse) {
        updateDisplayedContent { content in
            LoadedBrowserContent(response: response, selection: content.selection)
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
        let firstItem: ClipboardItem? = {
            guard let currentFirstItem = response.firstItem,
                  currentFirstItem.itemMetadata.itemId == itemId
            else {
                return response.firstItem
            }
            return updatedFirstItem
        }()
        updateDisplayedResponse(BrowserSearchResponse(
            request: response.request,
            items: updatedItems,
            firstItem: firstItem,
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
