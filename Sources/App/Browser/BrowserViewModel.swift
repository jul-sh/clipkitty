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
    private var metadataTask: Task<Void, Never>?
    private var matchDataTasks: [String: Task<Void, Never>] = [:]
    private var pendingDeleteTask: Task<Void, Never>?
    private var pendingTagSettleTask: Task<Void, Never>?
    private var previewGeneration = 0
    private var metadataGeneration = 0
    private var hasAppliedInitialSearch = false

    private(set) var session: BrowserSession = .initial
    private(set) var hasUserNavigated = false
    private(set) var prefetchCache: [Int64: ClipboardItem] = [:]
    private(set) var previewSpinnerVisible = false

    // MARK: - Edit State

    /// Which item's text editor currently has keyboard focus
    enum EditFocusState: Equatable {
        case idle
        case focused(itemId: Int64)
    }

    private(set) var editFocus: EditFocusState = .idle

    /// Per-item cache of unsaved edited text
    private(set) var pendingEdits: [Int64: String] = [:]

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
        session.query.request.text
    }

    var contentTypeFilter: ContentTypeFilter {
        switch session.query.request.filter {
        case let .contentType(contentType):
            return contentType
        case .all, .tagged:
            return .all
        }
    }

    var selectedTagFilter: ItemTag? {
        if case let .tagged(tag) = session.query.request.filter {
            return tag
        }
        return nil
    }

    var searchSpinnerVisible: Bool {
        session.query.isSearchSpinnerVisible
    }

    var itemIds: [Int64] {
        session.query.items.map { $0.itemMetadata.itemId }
    }

    var selectedItemId: Int64? {
        session.selection.itemId
    }

    var selectedItem: ClipboardItem? {
        switch session.preview {
        case let .loaded(selection):
            return selection.item
        case let .loading(_, stale), let .failed(_, stale):
            return stale?.item
        case .empty:
            return nil
        }
    }

    var selectedIndex: Int? {
        guard let selectedItemId else { return nil }
        return itemIds.firstIndex(of: selectedItemId)
    }

    var itemCount: Int {
        itemIds.count
    }

    var mutationFailureMessage: String? {
        guard case let .failed(failure) = session.mutation else { return nil }
        return failure.message
    }

    var previewSelection: PreviewSelection? {
        switch session.preview {
        case let .loaded(selection):
            return selection
        case let .loading(_, stale), let .failed(_, stale):
            return stale
        case .empty:
            return nil
        }
    }

    var stateFirstItem: ClipboardItem? {
        session.query.firstItem
    }

    func onAppear(initialSearchQuery: String) {
        guard !hasAppliedInitialSearch else { return }
        hasAppliedInitialSearch = true
        if initialSearchQuery.isEmpty {
            submitSearch(text: "", filter: .all)
        } else {
            submitSearch(text: initialSearchQuery, filter: .all)
        }
    }

    func handleDisplayReset(initialSearchQuery: String) {
        searchExecution.cancel()
        previewTask?.cancel()
        metadataTask?.cancel()
        matchDataTasks.values.forEach { $0.cancel() }
        matchDataTasks.removeAll()
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        pendingTagSettleTask?.cancel()
        pendingTagSettleTask = nil
        previewGeneration += 1
        metadataGeneration += 1
        previewSpinnerVisible = false
        hasUserNavigated = false
        prefetchCache.removeAll()
        session.overlays = .none
        session.mutation = .idle
        session.selection = .none
        session.preview = .empty
        editFocus = .idle
        pendingEdits.removeAll()
        hasAppliedInitialSearch = false
        onAppear(initialSearchQuery: initialSearchQuery)
    }

    func dismiss() {
        onDismiss()
    }

    func updateSearchText(_ value: String) {
        submitSearch(text: value, filter: session.query.request.filter)
    }

    func setContentTypeFilter(_ filter: ContentTypeFilter) {
        let queryFilter: ItemQueryFilter = filter == .all ? .all : .contentType(contentType: filter)
        submitSearch(text: searchText, filter: queryFilter)
    }

    func setTagFilter(_ tag: ItemTag?) {
        let queryFilter: ItemQueryFilter
        if let tag {
            queryFilter = .tagged(tag: tag)
        } else {
            queryFilter = .all
        }
        submitSearch(text: searchText, filter: queryFilter)
    }

    func openFilterOverlay(highlight: FilterOverlayState) {
        session.overlays = .filter(highlight)
    }

    func openActionsOverlay(highlight: MenuHighlightState) {
        session.overlays = .actions(highlight)
    }

    func closeOverlay() {
        session.overlays = .none
    }

    func dismissMutationFailure() {
        guard case .failed = session.mutation else { return }
        session.mutation = .idle
    }

    func setFilterOverlayState(_ highlight: FilterOverlayState) {
        session.overlays = .filter(highlight)
    }

    func setActionsOverlayState(_ highlight: MenuHighlightState) {
        session.overlays = .actions(highlight)
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
        // Clear edit focus when changing selection
        if case let .focused(focusedId) = editFocus, focusedId != itemId {
            editFocus = .idle
        }
        session.selection = .selected(itemId: itemId, origin: origin)
        loadSelectedItem(itemId: itemId)
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

    func loadMatchDataForItems(_ ids: [Int64]) {
        let uniqueIds = Array(Set(ids)).sorted()
        guard !uniqueIds.isEmpty else { return }
        let request = session.query.request
        guard !request.text.isEmpty else { return }
        let key = "\(request.text)|\(uniqueIds.map(String.init).joined(separator: ","))"
        guard matchDataTasks[key] == nil else { return }

        let itemIdsNeedingData = uniqueIds.filter { matchData(for: $0) == nil }
        guard !itemIdsNeedingData.isEmpty else { return }

        matchDataTasks[key] = Task { [weak self] in
            guard let self else { return }
            let matchData = await self.client.loadMatchData(itemIds: itemIdsNeedingData, query: request.text)
            await MainActor.run {
                defer { self.matchDataTasks[key] = nil }
                guard case let .ready(response) = self.session.query,
                      response.request == request else { return }

                var idToData: [Int64: MatchData] = [:]
                for (index, itemId) in itemIdsNeedingData.enumerated() where index < matchData.count {
                    idToData[itemId] = matchData[index]
                }

                let updatedItems = response.items.map { itemMatch in
                    guard itemMatch.matchData == nil,
                          let newMatchData = idToData[itemMatch.itemMetadata.itemId]
                    else {
                        return itemMatch
                    }
                    return ItemMatch(itemMetadata: itemMatch.itemMetadata, matchData: newMatchData)
                }

                self.session.query = .ready(response: BrowserSearchResponse(
                    request: response.request,
                    items: updatedItems,
                    firstItem: response.firstItem,
                    totalCount: response.totalCount
                ))

                if let selectedItemId = self.selectedItemId,
                   let loadedItem = self.selectedItem,
                   selectedItemId == loadedItem.itemMetadata.itemId,
                   let updatedMatchData = idToData[selectedItemId]
                {
                    self.session.preview = .loaded(PreviewSelection(item: loadedItem, matchData: updatedMatchData))
                }
            }
        }
    }

    func deleteSelectedItem() {
        guard let itemId = selectedItemId else { return }
        deleteItem(itemId: itemId)
    }

    func deleteItem(itemId: Int64) {
        guard case .idle = session.mutation else { return }

        let snapshot = currentResponse
        let previewSnapshot = session.preview
        let selectionSnapshot = session.selection
        let transaction = DeleteTransaction(
            deletedItemId: itemId,
            snapshot: snapshot,
            preview: previewSnapshot,
            selection: selectionSnapshot
        )
        session.mutation = .deleting(.pending(transaction))

        applyOptimisticDelete(itemId: itemId)
        showDeleteUndoToast()

        pendingDeleteTask?.cancel()
        pendingDeleteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await MainActor.run {
                self.commitPendingDelete()
            }
        }
    }

    func undoPendingDelete() {
        guard case let .deleting(.pending(transaction)) = session.mutation else { return }
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        ToastWindow.shared.dismiss()
        restoreSnapshot(
            snapshot: transaction.snapshot,
            preview: transaction.preview,
            selection: transaction.selection
        )
        session.mutation = .idle
    }

    func clearAll() {
        let snapshot = currentResponse
        let previewSnapshot = session.preview
        let selectionSnapshot = session.selection
        session.mutation = .clearing(ClearTransaction(
            snapshot: snapshot,
            preview: previewSnapshot,
            selection: selectionSnapshot
        ))

        let request = session.query.request
        session.query = .ready(response: BrowserSearchResponse(
            request: request,
            items: [],
            firstItem: nil,
            totalCount: 0
        ))
        session.selection = .none
        session.preview = .empty
        prefetchCache.removeAll()

        Task { [weak self] in
            guard let self else { return }
            let result = await self.client.clear()
            await MainActor.run {
                switch result {
                case .success:
                    self.session.mutation = .idle
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

    // MARK: - Editing

    /// Returns the effective content for an item, accounting for pending edits
    func effectiveContent(for item: ClipboardItem) -> ClipboardContent {
        if let editedText = pendingEdits[item.itemMetadata.itemId] {
            return .text(value: editedText)
        }
        return item.content
    }

    /// Called on each text change in the preview pane
    func onTextEdit(_ newText: String, for itemId: Int64, originalText: String) {
        if newText == originalText {
            pendingEdits.removeValue(forKey: itemId)
        } else {
            pendingEdits[itemId] = newText
        }
    }

    /// Called when editing focus state changes
    func onEditingStateChange(_ isEditing: Bool, for itemId: Int64) {
        if isEditing {
            editFocus = .focused(itemId: itemId)
        } else if case let .focused(id) = editFocus, id == itemId {
            editFocus = .idle
        }
    }

    /// Discards the currently selected item's pending edit
    func discardCurrentEdit() {
        if let id = selectedItemId {
            pendingEdits.removeValue(forKey: id)
        }
        editFocus = .idle
    }

    /// Commits the currently selected item's edit by replacing the original item
    func commitCurrentEdit() {
        guard let id = selectedItemId,
              let editedText = pendingEdits.removeValue(forKey: id),
              !editedText.isEmpty
        else {
            editFocus = .idle
            return
        }
        editFocus = .idle

        // Optimistically update the preview to show the edited text without refreshing the list
        if let currentItem = selectedItem {
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
            session.preview = .loaded(PreviewSelection(item: updatedItem, matchData: previewSelection?.matchData))

            // Also update the snippet in the list so it reflects the edit
            if case let .ready(response) = session.query {
                let updatedItems = response.items.map { itemMatch in
                    guard itemMatch.itemMetadata.itemId == id else { return itemMatch }
                    return ItemMatch(
                        itemMetadata: updatedMetadata,
                        matchData: itemMatch.matchData
                    )
                }
                let updatedFirstItem: ClipboardItem? = {
                    guard let firstItem = response.firstItem,
                          firstItem.itemMetadata.itemId == id
                    else {
                        return response.firstItem
                    }
                    return updatedItem
                }()
                session.query = .ready(response: BrowserSearchResponse(
                    request: response.request,
                    items: updatedItems,
                    firstItem: updatedFirstItem,
                    totalCount: response.totalCount
                ))
            }
        }

        ToastWindow.shared.show(message: String(localized: "Saved"))

        // Persist the edit in-place (item keeps its ID and position)
        Task { [weak self] in
            guard let self else { return }
            _ = await self.client.updateTextItem(itemId: id, text: editedText)
        }
    }

    /// Whether the selected item has a pending edit
    var selectedItemHasPendingEdit: Bool {
        guard let id = selectedItemId else { return false }
        return pendingEdits[id] != nil
    }

    /// Whether the preview is currently being edited
    var isEditingPreview: Bool {
        guard let id = selectedItemId else { return false }
        return editFocus == .focused(itemId: id) || pendingEdits[id] != nil
    }

    /// Check if a specific item has a pending edit
    func hasPendingEdit(for itemId: Int64) -> Bool {
        pendingEdits[itemId] != nil
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
        let request = SearchRequest(
            text: rawText,
            filter: filter
        )

        hasUserNavigated = false
        prefetchCache.removeAll()
        searchExecution.cancel()
        let fallback = session.query.items
        session.query = .pending(request: request, fallback: fallback, phase: .debouncing)

        if request.text.isEmpty {
            beginSearch(request: request, fallback: fallback)
            return
        }

        let debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.beginSearch(request: request, fallback: fallback)
            }
        }
        searchExecution = .debouncing(request: request, task: debounceTask)
    }

    private func beginSearch(request: SearchRequest, fallback: [ItemMatch]) {
        let operation = client.startSearch(request: request)
        let operationId = UUID()
        session.query = .pending(request: request, fallback: fallback, phase: .running(spinnerVisible: false))

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
            guard case let .pending(request, fallback, _) = session.query else { return }
            session.query = .failed(
                request: request,
                message: error.localizedDescription,
                fallback: fallback
            )
        }
    }

    private func applySearchResponse(_ response: BrowserSearchResponse) {
        guard session.query.request == response.request else { return }
        let response = responseApplyingPendingMutations(response)

        let previousOrder = itemIds
        let previousSelection = selectedItemId
        let previousPreviewItem = previewSelection?.item

        session.query = .ready(response: response)

        let newOrder = response.items.map { $0.itemMetadata.itemId }
        switch previousSelection {
        case nil:
            if let firstItemId = newOrder.first {
                select(itemId: firstItemId, origin: .automatic)
            } else {
                session.selection = .none
                session.preview = .empty
            }
        case let .some(selectedItemId):
            if !newOrder.contains(selectedItemId) ||
                previousOrder.firstIndex(of: selectedItemId) != newOrder.firstIndex(of: selectedItemId)
            {
                if let firstItemId = newOrder.first {
                    session.selection = .selected(itemId: firstItemId, origin: .automatic)
                    loadSelectedItem(itemId: firstItemId)
                } else {
                    session.selection = .none
                    session.preview = .empty
                }
            } else {
                refreshPreviewSelection(
                    itemId: selectedItemId,
                    response: response,
                    previousPreviewItem: previousPreviewItem
                )
            }
        }

        if case .tagging(.settling) = session.mutation {
            pendingTagSettleTask?.cancel()
            pendingTagSettleTask = nil
            session.mutation = .idle
        }
    }

    private func refreshPreviewSelection(
        itemId: Int64,
        response: BrowserSearchResponse,
        previousPreviewItem: ClipboardItem?
    ) {
        if let firstItem = response.firstItem,
           firstItem.itemMetadata.itemId == itemId
        {
            session.preview = .loaded(makePreviewSelection(for: firstItem))
            loadMatchDataForItems([itemId])
            return
        }

        if let previousPreviewItem,
           previousPreviewItem.itemMetadata.itemId == itemId
        {
            session.preview = .loaded(makePreviewSelection(for: previousPreviewItem))
            loadMatchDataForItems([itemId])
            return
        }

        if let cachedItem = prefetchCache[itemId] {
            session.preview = .loaded(makePreviewSelection(for: cachedItem))
            loadMatchDataForItems([itemId])
            return
        }

        if previewSelection == nil {
            loadSelectedItem(itemId: itemId)
        }
    }

    private func loadSelectedItem(itemId: Int64) {
        previewTask?.cancel()
        metadataTask?.cancel()
        previewGeneration += 1
        let generation = previewGeneration
        let stale = previewSelection

        if let firstItem = stateFirstItem,
           firstItem.itemMetadata.itemId == itemId
        {
            session.preview = .loaded(makePreviewSelection(for: firstItem))
            loadMatchDataForItems([itemId])
            prefetchAdjacentItems(around: itemId)
            maybeRefreshLinkMetadata(for: firstItem, generation: generation)
            return
        }

        if let cachedItem = prefetchCache[itemId] {
            session.preview = .loaded(makePreviewSelection(for: cachedItem))
            loadMatchDataForItems([itemId])
            prefetchAdjacentItems(around: itemId)
            maybeRefreshLinkMetadata(for: cachedItem, generation: generation)
            return
        }

        session.preview = .loading(itemId: itemId, stale: stale)
        schedulePreviewSpinner(for: generation, itemId: itemId)

        previewTask = Task { [weak self] in
            guard let self else { return }
            let item = await self.client.fetchItem(id: itemId)
            await MainActor.run {
                guard self.previewGeneration == generation,
                      self.selectedItemId == itemId else { return }

                self.previewSpinnerVisible = false
                if let item {
                    self.session.preview = .loaded(self.makePreviewSelection(for: item))
                    self.loadMatchDataForItems([itemId])
                    self.prefetchAdjacentItems(around: itemId)
                    self.maybeRefreshLinkMetadata(for: item, generation: generation)
                } else {
                    self.session.preview = .failed(itemId: itemId, stale: stale)
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
                      let updatedItem else { return }

                // Preserve optimistic tags from current preview
                let currentTags = self.previewSelection?.item.itemMetadata.tags ?? updatedItem.itemMetadata.tags
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
                self.session.preview = .loaded(self.makePreviewSelection(for: mergedPreviewItem))
                if case let .ready(response) = self.session.query {
                    let updatedItems = response.items.map { itemMatch in
                        if itemMatch.itemMetadata.itemId == updatedItem.itemMetadata.itemId {
                            // Preserve optimistic tag mutations by merging with current tags
                            let mergedMetadata = ItemMetadata(
                                itemId: updatedItem.itemMetadata.itemId,
                                icon: updatedItem.itemMetadata.icon,
                                snippet: updatedItem.itemMetadata.snippet,
                                sourceApp: updatedItem.itemMetadata.sourceApp,
                                sourceAppBundleId: updatedItem.itemMetadata.sourceAppBundleId,
                                timestampUnix: updatedItem.itemMetadata.timestampUnix,
                                tags: itemMatch.itemMetadata.tags
                            )
                            return ItemMatch(
                                itemMetadata: mergedMetadata,
                                matchData: itemMatch.matchData
                            )
                        }
                        return itemMatch
                    }
                    // Preserve tags for firstItem as well
                    let updatedFirstItem: ClipboardItem? = {
                        guard let firstItem = response.firstItem,
                              firstItem.itemMetadata.itemId == updatedItem.itemMetadata.itemId
                        else {
                            return response.firstItem
                        }
                        let mergedMetadata = ItemMetadata(
                            itemId: updatedItem.itemMetadata.itemId,
                            icon: updatedItem.itemMetadata.icon,
                            snippet: updatedItem.itemMetadata.snippet,
                            sourceApp: updatedItem.itemMetadata.sourceApp,
                            sourceAppBundleId: updatedItem.itemMetadata.sourceAppBundleId,
                            timestampUnix: updatedItem.itemMetadata.timestampUnix,
                            tags: firstItem.itemMetadata.tags
                        )
                        return ClipboardItem(itemMetadata: mergedMetadata, content: updatedItem.content)
                    }()
                    self.session.query = .ready(response: BrowserSearchResponse(
                        request: response.request,
                        items: updatedItems,
                        firstItem: updatedFirstItem,
                        totalCount: response.totalCount
                    ))
                }
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
              case .pending(let currentRequest, let fallback, .running(spinnerVisible: false)) = session.query,
              currentRequest == request else { return }
        session.query = .pending(
            request: currentRequest,
            fallback: fallback,
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
                      case .loading = self.session.preview else { return }
                self.previewSpinnerVisible = true
            }
        }
    }

    private func applyOptimisticDelete(itemId: Int64) {
        guard case let .ready(response) = session.query else { return }
        let filteredItems = response.items.filter { $0.itemMetadata.itemId != itemId }
        let deletedSelectedItem = selectedItemId == itemId
        let nextSelection = deletedSelectedItem ? nextSelectionAfterDelete(deleting: itemId) : nil
        session.query = .ready(response: BrowserSearchResponse(
            request: response.request,
            items: filteredItems,
            firstItem: response.firstItem?.itemMetadata.itemId == itemId ? nil : response.firstItem,
            totalCount: max(0, response.totalCount - 1)
        ))

        if let nextSelection {
            session.selection = .selected(itemId: nextSelection, origin: .automatic)
            loadSelectedItem(itemId: nextSelection)
        } else if deletedSelectedItem {
            session.selection = .none
            session.preview = .empty
        }
    }

    private func commitPendingDelete() {
        guard case let .deleting(.pending(transaction)) = session.mutation else { return }
        pendingDeleteTask = nil
        session.mutation = .deleting(.committing(transaction))

        Task { [weak self] in
            guard let self else { return }
            let result = await self.client.delete(itemId: transaction.deletedItemId)
            await MainActor.run {
                switch result {
                case .success:
                    if case let .deleting(.committing(activeTransaction)) = self.session.mutation,
                       activeTransaction.deletedItemId == transaction.deletedItemId
                    {
                        self.session.mutation = .idle
                    }
                case let .failure(error):
                    self.restoreDeleteFailure(error: error)
                }
            }
        }
    }

    private func restoreDeleteFailure(error: ClipboardError) {
        let transaction: DeleteTransaction
        switch session.mutation {
        case let .deleting(.pending(pendingTransaction)), let .deleting(.committing(pendingTransaction)):
            transaction = pendingTransaction
        default:
            return
        }
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        restoreSnapshot(
            snapshot: transaction.snapshot,
            preview: transaction.preview,
            selection: transaction.selection
        )
        session.mutation = .failed(ActionFailure(message: error.localizedDescription))
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
        guard case let .clearing(transaction) = session.mutation else { return }
        restoreSnapshot(
            snapshot: transaction.snapshot,
            preview: transaction.preview,
            selection: transaction.selection
        )
        session.mutation = .failed(ActionFailure(message: error.localizedDescription))
    }

    private func restoreSnapshot(
        snapshot: BrowserSearchResponse?,
        preview: PreviewSession,
        selection: SelectionSession
    ) {
        if let snapshot {
            session.query = .ready(response: snapshot)
        } else {
            session.query = .idle(request: session.query.request)
        }
        session.preview = preview
        session.selection = selection
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

    private var currentResponse: BrowserSearchResponse? {
        guard case let .ready(response) = session.query else { return nil }
        return response
    }

    private func responseApplyingPendingMutations(_ response: BrowserSearchResponse) -> BrowserSearchResponse {
        switch session.mutation {
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
        let snapshot = currentResponse
        let previewSnapshot = session.preview
        let selectionSnapshot = session.selection

        pendingTagSettleTask?.cancel()
        pendingTagSettleTask = nil
        let transaction = TagMutationTransaction(itemId: itemId, tag: tag, shouldInclude: shouldInclude)
        session.mutation = .tagging(.pending(transaction))
        applyOptimisticTagMutation(itemId: itemId, tag: tag, shouldInclude: shouldInclude)

        Task { [weak self] in
            guard let self else { return }
            let result: Result<Void, ClipboardError>
            if shouldInclude {
                result = await self.client.addTag(itemId: itemId, tag: tag)
            } else {
                result = await self.client.removeTag(itemId: itemId, tag: tag)
            }

            await MainActor.run {
                switch result {
                case .success:
                    if case let .tagging(.pending(mutation)) = self.session.mutation,
                       mutation.itemId == itemId,
                       mutation.tag == tag,
                       mutation.shouldInclude == shouldInclude
                    {
                        self.session.mutation = .tagging(.settling(mutation))
                        self.scheduleTagMutationSettleFallback(
                            itemId: mutation.itemId,
                            tag: mutation.tag,
                            shouldInclude: mutation.shouldInclude
                        )
                    }
                case let .failure(error):
                    self.pendingTagSettleTask?.cancel()
                    self.pendingTagSettleTask = nil
                    self.restoreSnapshot(
                        snapshot: snapshot,
                        preview: previewSnapshot,
                        selection: selectionSnapshot
                    )
                    self.session.mutation = .failed(ActionFailure(message: error.localizedDescription))
                }
            }
        }
    }

    private func applyOptimisticTagMutation(itemId: Int64, tag: ItemTag, shouldInclude: Bool) {
        guard case let .ready(response) = session.query else { return }
        let updatedResponse = responseApplyingTagMutation(
            response,
            itemId: itemId,
            tag: tag,
            shouldInclude: shouldInclude
        )
        session.query = .ready(response: updatedResponse)

        if let selectedItem = selectedItem {
            let updatedMetadata = selectedItem.itemMetadata.itemId == itemId
                ? applyingTagMutation(to: selectedItem.itemMetadata, tag: tag, shouldInclude: shouldInclude)
                : selectedItem.itemMetadata
            if case let .tagged(activeTag) = response.request.filter,
               activeTag == tag,
               !updatedMetadata.tags.contains(tag)
            {
                session.selection = .none
                session.preview = .empty
                if let firstItemId = updatedResponse.items.first?.itemMetadata.itemId {
                    select(itemId: firstItemId, origin: .automatic)
                }
            } else if selectedItem.itemMetadata.itemId == itemId {
                session.preview = .loaded(PreviewSelection(
                    item: ClipboardItem(itemMetadata: updatedMetadata, content: selectedItem.content),
                    matchData: previewSelection?.matchData
                ))
            }
        }

        // Update prefetch cache to reflect tag mutation
        if let cachedItem = prefetchCache[itemId] {
            let updatedMetadata = applyingTagMutation(to: cachedItem.itemMetadata, tag: tag, shouldInclude: shouldInclude)
            prefetchCache[itemId] = ClipboardItem(itemMetadata: updatedMetadata, content: cachedItem.content)
        }
    }

    private func scheduleTagMutationSettleFallback(itemId: Int64, tag: ItemTag, shouldInclude: Bool) {
        pendingTagSettleTask?.cancel()
        pendingTagSettleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if case let .tagging(.settling(mutation)) = self.session.mutation,
                   mutation.itemId == itemId,
                   mutation.tag == tag,
                   mutation.shouldInclude == shouldInclude
                {
                    self.session.mutation = .idle
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
                return nil
            }

            return ItemMatch(itemMetadata: updatedMetadata, matchData: itemMatch.matchData)
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

    func matchData(for itemId: Int64) -> MatchData? {
        session.query.items.first { $0.itemMetadata.itemId == itemId }?.matchData
    }

    func makePreviewSelection(for item: ClipboardItem) -> PreviewSelection {
        PreviewSelection(item: item, matchData: matchData(for: item.itemMetadata.itemId))
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
}
