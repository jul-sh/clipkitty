import Foundation
import Observation
import ClipKittyRust

@MainActor
@Observable
final class BrowserViewModel {
    private let client: BrowserStoreClient
    private let onSelect: (Int64, ClipboardContent) -> Void
    private let onCopyOnly: (Int64, ClipboardContent) -> Void
    private let onDismiss: () -> Void

    private var searchTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var matchDataTasks: [String: Task<Void, Never>] = [:]
    private var searchGeneration = 0
    private var previewGeneration = 0
    private var metadataGeneration = 0
    private var hasAppliedInitialSearch = false

    private(set) var session: BrowserSession = .initial
    private(set) var hasUserNavigated = false
    private(set) var prefetchCache: [Int64: ClipboardItem] = [:]
    private(set) var searchSpinnerVisible = false
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
        session.query.request.text
    }

    var contentTypeFilter: ContentTypeFilter {
        switch session.query.request.filter {
        case .contentType(let contentType):
            return contentType
        case .all, .tagged:
            return .all
        }
    }

    var selectedTagFilter: ItemTag? {
        if case .tagged(let tag) = session.query.request.filter {
            return tag
        }
        return nil
    }

    var itemIds: [Int64] {
        session.query.items.map { $0.itemMetadata.itemId }
    }

    var selectedItemId: Int64? {
        session.selection.itemId
    }

    var selectedItem: ClipboardItem? {
        switch session.preview {
        case .loaded(let selection):
            return selection.item
        case .loading(_, let stale), .failed(_, let stale):
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
        guard case .failed(let failure) = session.mutation else { return nil }
        return failure.message
    }

    var previewSelection: PreviewSelection? {
        switch session.preview {
        case .loaded(let selection):
            return selection
        case .loading(_, let stale), .failed(_, let stale):
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
        searchTask?.cancel()
        previewTask?.cancel()
        metadataTask?.cancel()
        matchDataTasks.values.forEach { $0.cancel() }
        matchDataTasks.removeAll()
        searchGeneration += 1
        previewGeneration += 1
        metadataGeneration += 1
        searchSpinnerVisible = false
        previewSpinnerVisible = false
        hasUserNavigated = false
        prefetchCache.removeAll()
        session.overlays = .none
        session.mutation = .idle
        session.selection = .none
        session.preview = .empty
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

    func openFilterOverlay(highlightedIndex: Int) {
        session.overlays = .filter(FilterOverlayState(highlightedIndex: highlightedIndex))
    }

    func openActionsOverlay(highlightedIndex: Int) {
        session.overlays = .actions(.actions(highlightedIndex: highlightedIndex))
    }

    func openDeleteConfirmation(highlightedIndex: Int = 0) {
        session.overlays = .actions(.confirmDelete(highlightedIndex: highlightedIndex))
    }

    func closeOverlay() {
        session.overlays = .none
    }

    func dismissMutationFailure() {
        guard case .failed = session.mutation else { return }
        session.mutation = .idle
    }

    func updateFilterHighlight(_ index: Int) {
        guard case .filter = session.overlays else { return }
        session.overlays = .filter(FilterOverlayState(highlightedIndex: index))
    }

    func updateActionsHighlight(_ index: Int) {
        guard case .actions(let state) = session.overlays else { return }
        switch state {
        case .actions:
            session.overlays = .actions(.actions(highlightedIndex: index))
        case .confirmDelete:
            session.overlays = .actions(.confirmDelete(highlightedIndex: index))
        }
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
        session.selection = .selected(itemId: itemId, origin: origin)
        loadSelectedItem(itemId: itemId)
    }

    func confirmSelection() {
        guard let item = selectedItem else { return }
        onSelect(item.itemMetadata.itemId, item.content)
    }

    func copyOnlySelection() {
        guard let item = selectedItem else { return }
        onCopyOnly(item.itemMetadata.itemId, item.content)
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
                guard case .ready(let response) = self.session.query,
                      response.request == request else { return }

                var idToData: [Int64: MatchData] = [:]
                for (index, itemId) in itemIdsNeedingData.enumerated() where index < matchData.count {
                    idToData[itemId] = matchData[index]
                }

                let updatedItems = response.items.map { itemMatch in
                    guard itemMatch.matchData == nil,
                          let newMatchData = idToData[itemMatch.itemMetadata.itemId] else {
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
                   let updatedMatchData = idToData[selectedItemId] {
                    self.session.preview = .loaded(PreviewSelection(item: loadedItem, matchData: updatedMatchData))
                }
            }
        }
    }

    func deleteSelectedItem() {
        guard let itemId = selectedItemId else { return }
        let snapshot = currentResponse
        let previewSnapshot = session.preview
        let selectionSnapshot = session.selection
        session.mutation = .deleting(DeleteTransaction(
            deletedItemId: itemId,
            snapshot: snapshot,
            preview: previewSnapshot,
            selection: selectionSnapshot
        ))

        applyOptimisticDelete(itemId: itemId)

        Task { [weak self] in
            guard let self else { return }
            let result = await self.client.delete(itemId: itemId)
            await MainActor.run {
                switch result {
                case .success:
                    self.session.mutation = .idle
                case .failure(let error):
                    self.restoreDeleteFailure(error: error)
                }
            }
        }
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
                case .failure(let error):
                    self.restoreClearFailure(error: error)
                }
            }
        }
    }

    func addTagToSelectedItem(_ tag: ItemTag) {
        mutateSelectedItemTag(tag, shouldInclude: true)
    }

    func removeTagFromSelectedItem(_ tag: ItemTag) {
        mutateSelectedItemTag(tag, shouldInclude: false)
    }

    private func submitSearch(text rawText: String, filter: ItemQueryFilter) {
        let request = SearchRequest(
            text: rawText.trimmingCharacters(in: .whitespacesAndNewlines),
            filter: filter
        )
        searchGeneration += 1
        let generation = searchGeneration

        hasUserNavigated = false
        prefetchCache.removeAll()
        searchTask?.cancel()
        let fallback = session.query.items
        session.query = .searching(request: request, fallback: fallback)
        scheduleSearchSpinner(for: request, generation: generation)

        searchTask = Task { [weak self] in
            guard let self else { return }
            if !request.text.isEmpty {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
            }

            do {
                let response = try await self.client.search(request: request)
                await MainActor.run {
                    self.applySearchResponse(response, generation: generation)
                }
            } catch {
                await MainActor.run {
                    guard self.searchGeneration == generation,
                          self.session.query.request == request else { return }
                    self.searchSpinnerVisible = false
                    self.session.query = .failed(
                        request: request,
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func applySearchResponse(_ response: BrowserSearchResponse, generation: Int) {
        guard searchGeneration == generation,
              session.query.request == response.request else { return }

        let previousOrder = itemIds
        let previousSelection = selectedItemId

        searchSpinnerVisible = false
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
        case .some(let selectedItemId):
            if !newOrder.contains(selectedItemId) ||
                previousOrder.firstIndex(of: selectedItemId) != newOrder.firstIndex(of: selectedItemId) {
                if let firstItemId = newOrder.first {
                    session.selection = .selected(itemId: firstItemId, origin: .automatic)
                    loadSelectedItem(itemId: firstItemId)
                } else {
                    session.selection = .none
                    session.preview = .empty
                }
            } else if let firstItem = response.firstItem,
                      firstItem.itemMetadata.itemId == selectedItemId,
                      previewSelection == nil {
                session.preview = .loaded(makePreviewSelection(for: firstItem))
            }
        }
    }

    private func loadSelectedItem(itemId: Int64) {
        previewTask?.cancel()
        metadataTask?.cancel()
        previewGeneration += 1
        let generation = previewGeneration
        let stale = previewSelection

        if let firstItem = stateFirstItem,
           firstItem.itemMetadata.itemId == itemId {
            session.preview = .loaded(makePreviewSelection(for: firstItem))
            prefetchAdjacentItems(around: itemId)
            maybeRefreshLinkMetadata(for: firstItem, generation: generation)
            return
        }

        if let cachedItem = prefetchCache[itemId] {
            session.preview = .loaded(makePreviewSelection(for: cachedItem))
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
                    self.prefetchAdjacentItems(around: itemId)
                    self.maybeRefreshLinkMetadata(for: item, generation: generation)
                } else {
                    self.session.preview = .failed(itemId: itemId, stale: stale)
                }
            }
        }
    }

    private func maybeRefreshLinkMetadata(for item: ClipboardItem, generation: Int) {
        guard case .link(let url, let metadataState) = item.content,
              case .pending = metadataState,
              AppSettings.shared.generateLinkPreviews else {
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

                self.session.preview = .loaded(self.makePreviewSelection(for: updatedItem))
                if case .ready(let response) = self.session.query {
                    let updatedItems = response.items.map { itemMatch in
                        if itemMatch.itemMetadata.itemId == updatedItem.itemMetadata.itemId {
                            return ItemMatch(
                                itemMetadata: updatedItem.itemMetadata,
                                matchData: itemMatch.matchData
                            )
                        }
                        return itemMatch
                    }
                    self.session.query = .ready(response: BrowserSearchResponse(
                        request: response.request,
                        items: updatedItems,
                        firstItem: response.firstItem?.itemMetadata.itemId == updatedItem.itemMetadata.itemId ? updatedItem : response.firstItem,
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

    private func scheduleSearchSpinner(for request: SearchRequest, generation: Int) {
        searchSpinnerVisible = false
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            await MainActor.run {
                guard let self,
                      self.searchGeneration == generation,
                      case .searching(let currentRequest, _) = self.session.query,
                      currentRequest == request else { return }
                self.searchSpinnerVisible = true
            }
        }
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
        guard case .ready(let response) = session.query else { return }
        let filteredItems = response.items.filter { $0.itemMetadata.itemId != itemId }
        let nextSelection = nextSelectionAfterDelete(deleting: itemId)
        session.query = .ready(response: BrowserSearchResponse(
            request: response.request,
            items: filteredItems,
            firstItem: response.firstItem?.itemMetadata.itemId == itemId ? nil : response.firstItem,
            totalCount: max(0, response.totalCount - 1)
        ))

        if let nextSelection {
            session.selection = .selected(itemId: nextSelection, origin: .automatic)
            loadSelectedItem(itemId: nextSelection)
        } else {
            session.selection = .none
            session.preview = .empty
        }
    }

    private func restoreDeleteFailure(error: ClipboardError) {
        guard case .deleting(let transaction) = session.mutation else { return }
        restoreSnapshot(
            snapshot: transaction.snapshot,
            preview: transaction.preview,
            selection: transaction.selection
        )
        session.mutation = .failed(ActionFailure(message: error.localizedDescription))
    }

    private func restoreClearFailure(error: ClipboardError) {
        guard case .clearing(let transaction) = session.mutation else { return }
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
        guard case .ready(let response) = session.query else { return nil }
        return response
    }

    private func mutateSelectedItemTag(_ tag: ItemTag, shouldInclude: Bool) {
        guard let itemId = selectedItemId else { return }
        let snapshot = currentResponse
        let previewSnapshot = session.preview
        let selectionSnapshot = session.selection

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
                    self.session.mutation = .idle
                case .failure(let error):
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
        guard case .ready(let response) = session.query else { return }
        session.mutation = .idle

        let updatedItems = response.items.compactMap { itemMatch -> ItemMatch? in
            let isTarget = itemMatch.itemMetadata.itemId == itemId
            let updatedMetadata = isTarget
                ? applyingTagMutation(to: itemMatch.itemMetadata, tag: tag, shouldInclude: shouldInclude)
                : itemMatch.itemMetadata

            if case .tagged(let activeTag) = response.request.filter,
               activeTag == tag,
               !updatedMetadata.tags.contains(tag) {
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
            if case .tagged(let activeTag) = response.request.filter,
               activeTag == tag,
               !updatedMetadata.tags.contains(tag) {
                return nil
            }
            return ClipboardItem(itemMetadata: updatedMetadata, content: firstItem.content)
        }

        session.query = .ready(response: BrowserSearchResponse(
            request: response.request,
            items: updatedItems,
            firstItem: updatedFirstItem,
            totalCount: updatedItems.count
        ))

        if let selectedItem = selectedItem {
            let updatedMetadata = selectedItem.itemMetadata.itemId == itemId
                ? applyingTagMutation(to: selectedItem.itemMetadata, tag: tag, shouldInclude: shouldInclude)
                : selectedItem.itemMetadata
            if case .tagged(let activeTag) = response.request.filter,
               activeTag == tag,
               !updatedMetadata.tags.contains(tag) {
                session.selection = .none
                session.preview = .empty
                if let firstItemId = updatedItems.first?.itemMetadata.itemId {
                    select(itemId: firstItemId, origin: .automatic)
                }
            } else if selectedItem.itemMetadata.itemId == itemId {
                session.preview = .loaded(PreviewSelection(
                    item: ClipboardItem(itemMetadata: updatedMetadata, content: selectedItem.content),
                    matchData: previewSelection?.matchData
                ))
            }
        }
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
}
