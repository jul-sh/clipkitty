import Foundation
import ClipKittyRust
import Combine

// MARK: - Browser View Model

/// View model for the browser view managing all browser state and actions.
///
/// NOTE: This is the target architecture for state management.
/// Currently ContentView manages state inline.
/// This file serves as documentation of the intended boundary.
@MainActor
@Observable
final class BrowserViewModel {
    // MARK: - State

    private(set) var session: BrowserSession

    // Generation tracking for async operations
    private var searchGeneration: Int = 0
    private var previewGeneration: Int = 0
    private var linkMetadataGeneration: Int = 0

    // Dependencies
    private let store: ClipKittyRust.ClipboardStore

    // Debounce
    private var searchTask: Task<Void, Never>?
    private let searchDebounceMs: Int = 150

    // MARK: - Initialization

    init(store: ClipKittyRust.ClipboardStore) {
        self.store = store
        self.session = BrowserSession()
    }

    // MARK: - Query Actions

    func updateSearchText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            // Return to idle state
            session.query = .idle(filter: session.query.filter)
            searchTask?.cancel()
            return
        }

        // Increment generation and start debounced search
        searchGeneration += 1
        let generation = searchGeneration
        let filter = session.query.filter
        let fallback = session.query.items

        let request = SearchRequest(text: trimmed, filter: filter, generation: generation)
        session.query = .searching(request: request, fallback: fallback)

        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(searchDebounceMs))
            guard !Task.isCancelled, generation == searchGeneration else { return }
            await executeSearch(request: request)
        }
    }

    func updateFilter(_ filter: ContentTypeFilter) {
        let currentText = session.query.queryText

        if currentText.isEmpty {
            session.query = .idle(filter: filter)
        } else {
            searchGeneration += 1
            let request = SearchRequest(text: currentText, filter: filter, generation: searchGeneration)
            session.query = .searching(request: request, fallback: session.query.items)
            Task {
                await executeSearch(request: request)
            }
        }

        dismissOverlay()
    }

    private func executeSearch(request: SearchRequest) async {
        do {
            let result = try await store.searchFiltered(query: request.text, filter: request.filter)

            // Check for stale completion
            guard request.generation == searchGeneration else { return }

            let firstItem: ClipboardItem?
            if let firstMatch = result.matches.first {
                let items = try store.fetchByIds(itemIds: [firstMatch.itemMetadata.itemId])
                firstItem = items.first
            } else {
                firstItem = nil
            }

            let response = SearchResponse(
                items: result.matches,
                firstItem: firstItem,
                totalCount: result.totalCount
            )
            session.query = .ready(request: request, response: response)

            // Auto-select first item
            if let firstMatch = result.matches.first {
                selectItem(id: firstMatch.itemMetadata.itemId, origin: .automatic)
            }
        } catch {
            guard request.generation == searchGeneration else { return }
            session.query = .failed(request: request, message: error.localizedDescription)
        }
    }

    // MARK: - Selection Actions

    func selectItem(id: Int64, origin: SelectionOrigin) {
        session.selection = .selected(itemId: id, origin: origin)
        loadPreview(itemId: id)
    }

    func clearSelection() {
        session.selection = .none
        session.preview = .empty
    }

    // MARK: - Preview Loading

    private func loadPreview(itemId: Int64) {
        previewGeneration += 1
        let generation = previewGeneration
        let staleData = session.preview.displayedData

        session.preview = .loading(itemId: itemId, stale: staleData)

        Task {
            do {
                let items = try store.fetchByIds(itemIds: [itemId])
                guard let item = items.first else {
                    guard generation == previewGeneration else { return }
                    session.preview = .failed(itemId: itemId, message: "Item not found", stale: staleData)
                    return
                }

                guard generation == previewGeneration else { return }

                // Get match data if searching
                let matchData: MatchData?
                if case .ready(_, let response) = session.query,
                   let match = response.items.first(where: { $0.itemMetadata.itemId == itemId }) {
                    matchData = match.matchData
                } else {
                    matchData = nil
                }

                let previewData = PreviewData(item: item, matchData: matchData, loadGeneration: generation)
                session.preview = .loaded(previewData)

                // Trigger link metadata refresh if needed
                refreshLinkMetadataIfNeeded(item: item)
            } catch {
                guard generation == previewGeneration else { return }
                session.preview = .failed(itemId: itemId, message: error.localizedDescription, stale: staleData)
            }
        }
    }

    private func refreshLinkMetadataIfNeeded(item: ClipboardItem) {
        // Check if item is a link with pending metadata
        guard case .link(_, let metadataState) = item.content,
              case .pending = metadataState else { return }

        linkMetadataGeneration += 1
        let generation = linkMetadataGeneration
        let itemId = item.id

        Task {
            // Fetch link metadata asynchronously
            // This would integrate with LinkPresentation framework
            // For now, we just track the generation to prevent stale updates

            guard generation == linkMetadataGeneration else { return }
            guard session.selection.selectedItemId == itemId else { return }

            // Reload preview to get updated metadata
            loadPreview(itemId: itemId)
        }
    }

    // MARK: - Overlay Actions

    func showFilterOverlay() {
        session.overlays = .filter(FilterOverlayState(currentFilter: session.query.filter))
    }

    func showActionsOverlay(for itemId: Int64) {
        session.overlays = .actions(ActionsOverlayState(targetItemId: itemId))
    }

    func dismissOverlay() {
        session.overlays = .none
    }

    func confirmDelete() {
        guard case .actions(var state) = session.overlays else { return }
        state.showDeleteConfirmation = true
        session.overlays = .actions(state)
    }

    // MARK: - Delete/Clear Actions with Rollback

    func deleteItem(id: Int64) async {
        // Snapshot current state for rollback
        let snapshot = captureStateSnapshot()

        // Optimistic UI update
        removeItemFromResults(id: id)

        do {
            try store.deleteItem(itemId: id)
            dismissOverlay()
        } catch {
            // Rollback on failure
            restoreFromSnapshot(snapshot)
            // Error reporting would go here
        }
    }

    func clearAllItems() async {
        // Snapshot current state for rollback
        let snapshot = captureStateSnapshot()

        // Optimistic UI update
        session.query = .idle(filter: session.query.filter)
        session.selection = .none
        session.preview = .empty

        do {
            try store.clear()
            dismissOverlay()
        } catch {
            // Rollback on failure
            restoreFromSnapshot(snapshot)
            // Error reporting would go here
        }
    }

    // MARK: - State Snapshot

    private struct StateSnapshot {
        let query: QuerySession
        let selection: SelectionSession
        let preview: PreviewSession
    }

    private func captureStateSnapshot() -> StateSnapshot {
        StateSnapshot(
            query: session.query,
            selection: session.selection,
            preview: session.preview
        )
    }

    private func restoreFromSnapshot(_ snapshot: StateSnapshot) {
        session.query = snapshot.query
        session.selection = snapshot.selection
        session.preview = snapshot.preview
    }

    private func removeItemFromResults(id: Int64) {
        switch session.query {
        case .idle:
            break
        case .searching(let request, let fallback):
            let filtered = fallback.filter { $0.itemMetadata.itemId != id }
            session.query = .searching(request: request, fallback: filtered)
        case .ready(let request, let response):
            let filtered = response.items.filter { $0.itemMetadata.itemId != id }
            let newResponse = SearchResponse(
                items: filtered,
                firstItem: response.firstItem?.id == id ? nil : response.firstItem,
                totalCount: response.totalCount - 1
            )
            session.query = .ready(request: request, response: newResponse)
        case .failed:
            break
        }

        // Clear selection if deleted item was selected
        if session.selection.selectedItemId == id {
            clearSelection()
        }
    }

    // MARK: - Navigation

    func selectNextItem() {
        guard let currentId = session.selection.selectedItemId else {
            if let firstMatch = session.query.items.first {
                selectItem(id: firstMatch.itemMetadata.itemId, origin: .keyboard)
            }
            return
        }

        let items = session.query.items
        guard let currentIndex = items.firstIndex(where: { $0.itemMetadata.itemId == currentId }),
              currentIndex + 1 < items.count else { return }

        selectItem(id: items[currentIndex + 1].itemMetadata.itemId, origin: .keyboard)
    }

    func selectPreviousItem() {
        guard let currentId = session.selection.selectedItemId else { return }

        let items = session.query.items
        guard let currentIndex = items.firstIndex(where: { $0.itemMetadata.itemId == currentId }),
              currentIndex > 0 else { return }

        selectItem(id: items[currentIndex - 1].itemMetadata.itemId, origin: .keyboard)
    }

    func selectItemByCommandNumber(_ number: Int) {
        let items = session.query.items
        guard number > 0, number <= items.count else { return }
        selectItem(id: items[number - 1].itemMetadata.itemId, origin: .commandNumber(number))
    }
}
