import Foundation
import ClipKittyRust

// MARK: - Browser Session State

/// Root state container for the browser view.
/// Uses sum types to make illegal state combinations unrepresentable.
struct BrowserSession: Equatable {
    var query: QuerySession
    var selection: SelectionSession
    var preview: PreviewSession
    var overlays: OverlaySession

    init() {
        self.query = .idle(filter: .all)
        self.selection = .none
        self.preview = .empty
        self.overlays = .none
    }
}

// MARK: - Query Session

/// Represents the current search/browse state.
enum QuerySession: Equatable {
    case idle(filter: ContentTypeFilter)
    case searching(request: SearchRequest, fallback: [ItemMatch])
    case ready(request: SearchRequest, response: SearchResponse)
    case failed(request: SearchRequest, message: String)

    var filter: ContentTypeFilter {
        switch self {
        case .idle(let filter): return filter
        case .searching(let req, _), .ready(let req, _), .failed(let req, _): return req.filter
        }
    }

    var queryText: String {
        switch self {
        case .idle: return ""
        case .searching(let req, _), .ready(let req, _), .failed(let req, _): return req.text
        }
    }

    var items: [ItemMatch] {
        switch self {
        case .idle: return []
        case .searching(_, let fallback): return fallback
        case .ready(_, let response): return response.items
        case .failed: return []
        }
    }

    var isSearching: Bool {
        if case .searching = self { return true }
        return false
    }
}

struct SearchRequest: Equatable, Hashable {
    let text: String
    let filter: ContentTypeFilter
    let generation: Int
}

struct SearchResponse: Equatable {
    let items: [ItemMatch]
    let firstItem: ClipboardItem?
    let totalCount: UInt64
}

// MARK: - Selection Session

enum SelectionSession: Equatable {
    case none
    case selected(itemId: Int64, origin: SelectionOrigin)

    var selectedItemId: Int64? {
        if case .selected(let itemId, _) = self { return itemId }
        return nil
    }
}

enum SelectionOrigin: Equatable {
    case keyboard
    case click
    case commandNumber(Int)
    case automatic
}

// MARK: - Preview Session

enum PreviewSession: Equatable {
    case empty
    case loading(itemId: Int64, stale: PreviewData?)
    case loaded(PreviewData)
    case failed(itemId: Int64, message: String, stale: PreviewData?)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var displayedData: PreviewData? {
        switch self {
        case .empty: return nil
        case .loading(_, let stale): return stale
        case .loaded(let data): return data
        case .failed(_, _, let stale): return stale
        }
    }
}

struct PreviewData: Equatable {
    let item: ClipboardItem
    let matchData: MatchData?
    let loadGeneration: Int
}

// MARK: - Overlay Session

enum OverlaySession: Equatable {
    case none
    case filter(FilterOverlayState)
    case actions(ActionsOverlayState)
}

struct FilterOverlayState: Equatable {
    var isPresented: Bool
    var selectedFilter: ContentTypeFilter

    init(currentFilter: ContentTypeFilter) {
        self.isPresented = true
        self.selectedFilter = currentFilter
    }
}

struct ActionsOverlayState: Equatable {
    var isPresented: Bool
    var targetItemId: Int64
    var showDeleteConfirmation: Bool

    init(targetItemId: Int64) {
        self.isPresented = true
        self.targetItemId = targetItemId
        self.showDeleteConfirmation = false
    }
}

struct ActionSnapshot: Equatable {
    let displayState: DisplayState
    let previewSession: PreviewSession
}
