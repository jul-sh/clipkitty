import Foundation
import ClipKittyRust

struct BrowserSession {
    var query: QuerySession
    var selection: SelectionSession
    var preview: PreviewSession
    var overlays: OverlaySession
    var mutation: MutationSession

    static let initial = BrowserSession(
        query: .idle(request: SearchRequest(text: "", filter: .all)),
        selection: .none,
        preview: .empty,
        overlays: .none,
        mutation: .idle
    )
}

struct SearchRequest: Hashable {
    let text: String
    let filter: ItemQueryFilter
}

struct BrowserSearchResponse {
    let request: SearchRequest
    let items: [ItemMatch]
    let firstItem: ClipboardItem?
    let totalCount: Int
}

enum QuerySession {
    case idle(request: SearchRequest)
    case searching(request: SearchRequest, fallback: [ItemMatch])
    case ready(response: BrowserSearchResponse)
    case failed(request: SearchRequest, message: String)

    var request: SearchRequest {
        switch self {
        case .idle(let request), .searching(let request, _), .failed(let request, _):
            return request
        case .ready(let response):
            return response.request
        }
    }

    var items: [ItemMatch] {
        switch self {
        case .idle:
            return []
        case .searching(_, let fallback):
            return fallback
        case .ready(let response):
            return response.items
        case .failed:
            return []
        }
    }

    var firstItem: ClipboardItem? {
        switch self {
        case .ready(let response):
            return response.firstItem
        case .idle, .searching, .failed:
            return nil
        }
    }
}

enum SelectionOrigin {
    case automatic
    case user
}

enum SelectionSession {
    case none
    case selected(itemId: Int64, origin: SelectionOrigin)

    var itemId: Int64? {
        guard case .selected(let itemId, _) = self else { return nil }
        return itemId
    }

    var origin: SelectionOrigin? {
        guard case .selected(_, let origin) = self else { return nil }
        return origin
    }
}

struct PreviewSelection {
    let item: ClipboardItem
    let matchData: MatchData?
}

enum PreviewSession {
    case empty
    case loading(itemId: Int64, stale: PreviewSelection?)
    case loaded(PreviewSelection)
    case failed(itemId: Int64, stale: PreviewSelection?)

    var currentSelection: PreviewSelection? {
        switch self {
        case .loaded(let selection):
            return selection
        case .loading(_, let stale), .failed(_, let stale):
            return stale
        case .empty:
            return nil
        }
    }
}

enum OverlaySession {
    case none
    case filter(FilterOverlayState)
    case actions(ActionsOverlayState)
}

struct FilterOverlayState {
    var highlightedIndex: Int
}

enum ActionsOverlayState {
    case actions(highlightedIndex: Int)
    case confirmDelete(highlightedIndex: Int)

    var highlightedIndex: Int {
        switch self {
        case .actions(let highlightedIndex), .confirmDelete(let highlightedIndex):
            return highlightedIndex
        }
    }
}

enum MutationSession {
    case idle
    case deleting(DeleteTransaction)
    case clearing(ClearTransaction)
    case failed(ActionFailure)
}

struct DeleteTransaction {
    let deletedItemId: Int64
    let snapshot: BrowserSearchResponse?
    let preview: PreviewSession
    let selection: SelectionSession
}

struct ClearTransaction {
    let snapshot: BrowserSearchResponse?
    let preview: PreviewSession
    let selection: SelectionSession
}

struct ActionFailure {
    let message: String
}
