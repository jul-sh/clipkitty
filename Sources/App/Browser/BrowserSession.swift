import ClipKittyRust
import Foundation

struct SearchRequest: Hashable {
    let text: String
    let filter: ItemQueryFilter
}

struct BrowserSearchResponse {
    let request: SearchRequest
    let items: [ItemMatch]
    let firstPreviewPayload: PreviewPayload?
    let totalCount: Int

    var firstItem: ClipboardItem? {
        firstPreviewPayload?.item
    }
}

enum QueryLoadPhase {
    case debouncing
    case running(spinnerVisible: Bool)
}

enum BrowserContentState {
    case idle(request: SearchRequest)
    case loading(request: SearchRequest, previous: LoadedBrowserContent?, phase: QueryLoadPhase)
    case loaded(LoadedBrowserContent)
    case failed(request: SearchRequest, message: String, previous: LoadedBrowserContent?)

    var request: SearchRequest {
        switch self {
        case let .idle(request), let .loading(request, _, _), let .failed(request, _, _):
            return request
        case let .loaded(content):
            return content.response.request
        }
    }

    var displayedContent: LoadedBrowserContent? {
        switch self {
        case let .loaded(content):
            return content
        case let .loading(_, previous, _), let .failed(_, _, previous):
            return previous
        case .idle:
            return nil
        }
    }

    var response: BrowserSearchResponse? {
        displayedContent?.response
    }

    var items: [ItemMatch] {
        switch self {
        case let .loaded(content):
            return content.response.items
        case let .loading(_, previous, _), let .failed(_, _, previous):
            return previous?.response.items ?? []
        case .idle:
            return []
        }
    }

    var firstPreviewPayload: PreviewPayload? {
        switch self {
        case let .loaded(content):
            return content.response.firstPreviewPayload
        case let .loading(_, previous, _), let .failed(_, _, previous):
            return previous?.response.firstPreviewPayload
        case .idle:
            return nil
        }
    }

    var selection: SelectionState {
        displayedContent?.selection ?? .none
    }

    var isSearchSpinnerVisible: Bool {
        guard case let .loading(_, _, .running(spinnerVisible)) = self else { return false }
        return spinnerVisible
    }
}

struct LoadedBrowserContent {
    let response: BrowserSearchResponse
    let selection: SelectionState
}

enum SelectionOrigin {
    case automatic
    case user
}

enum SelectedPreviewState: Equatable {
    case plain
    case loadingDecoration(previous: PreviewDecoration?)
    case highlighted(PreviewDecoration)
}

struct SelectedItemState: Equatable {
    let item: ClipboardItem
    let origin: SelectionOrigin
    let previewState: SelectedPreviewState
}

enum SelectionState {
    case none
    case loading(itemId: Int64, origin: SelectionOrigin)
    case selected(SelectedItemState)
    case failed(itemId: Int64, origin: SelectionOrigin)

    var itemId: Int64? {
        switch self {
        case .none:
            return nil
        case let .loading(itemId, _), let .failed(itemId, _):
            return itemId
        case let .selected(selectedItem):
            return selectedItem.item.itemMetadata.itemId
        }
    }

    var origin: SelectionOrigin? {
        switch self {
        case .none:
            return nil
        case let .loading(_, origin), let .failed(_, origin):
            return origin
        case let .selected(selectedItem):
            return selectedItem.origin
        }
    }

    var selectedItem: SelectedItemState? {
        guard case let .selected(selectedItem) = self else { return nil }
        return selectedItem
    }

    /// Lightweight label for os_signpost Points of Interest.
    var poiLabel: String {
        switch self {
        case .none: return "none"
        case let .loading(itemId, _): return "loading(\(itemId))"
        case let .selected(state): return "selected(\(state.item.itemMetadata.itemId))"
        case let .failed(itemId, _): return "failed(\(itemId))"
        }
    }
}

enum OverlayState {
    case none
    case filter(FilterOverlayState)
    case actions(MenuHighlightState)
}

enum FilterOverlayState {
    case none
    case index(Int)
}

enum MenuHighlightState {
    case none
    case index(Int)
}

enum MutationState {
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
    let snapshot: BrowserContentState
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
    let snapshot: BrowserContentState
}

struct ActionFailure {
    let message: String
}

struct EditState {
    enum Focus: Equatable {
        case idle
        case focused(itemId: Int64)
    }

    var focus: Focus = .idle
    var pendingEdits: [Int64: String] = [:]
}
