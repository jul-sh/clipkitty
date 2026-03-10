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

enum QueryLoadPhase {
    case debouncing
    case running(spinnerVisible: Bool)
}

enum QuerySession {
    case idle(request: SearchRequest)
    case pending(request: SearchRequest, fallback: [ItemMatch], phase: QueryLoadPhase)
    case ready(response: BrowserSearchResponse)
    case failed(request: SearchRequest, message: String, fallback: [ItemMatch])

    var request: SearchRequest {
        switch self {
        case .idle(let request), .pending(let request, _, _), .failed(let request, _, _):
            return request
        case .ready(let response):
            return response.request
        }
    }

    var items: [ItemMatch] {
        switch self {
        case .idle:
            return []
        case .pending(_, let fallback, _), .failed(_, _, let fallback):
            return fallback
        case .ready(let response):
            return response.items
        }
    }

    var firstItem: ClipboardItem? {
        switch self {
        case .ready(let response):
            return response.firstItem
        case .idle, .pending, .failed:
            return nil
        }
    }

    var isSearchSpinnerVisible: Bool {
        guard case .pending(_, _, .running(let spinnerVisible)) = self else { return false }
        return spinnerVisible
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
    case actions(MenuHighlightState)
}

struct FilterOverlayState {
    var highlightedIndex: Int
}

enum MenuHighlightState {
    case none
    case index(Int)
}

enum MutationSession {
    case idle
    case deleting(DeleteMutation)
    case tagging(TagMutation)
    case clearing(ClearTransaction)
    case failed(ActionFailure)
}

enum DeleteMutation {
    case pending(DeleteTransaction)
    case committing(DeleteTransaction)
}

struct DeleteTransaction {
    let deletedItemId: Int64
    let snapshot: BrowserSearchResponse?
    let preview: PreviewSession
    let selection: SelectionSession
}

enum TagMutation {
    case pending(TagMutationTransaction)
    case settling(TagMutationTransaction)
}

struct TagMutationTransaction {
    let itemId: Int64
    let tag: ItemTag
    let shouldInclude: Bool
}

struct ClearTransaction {
    let snapshot: BrowserSearchResponse?
    let preview: PreviewSession
    let selection: SelectionSession
}

struct ActionFailure {
    let message: String
}
