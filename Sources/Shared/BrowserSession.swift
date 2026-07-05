import ClipKittyRust
import Foundation

public struct SearchRequest: Hashable {
    public let text: String
    public let filter: ItemQueryFilter

    public init(text: String, filter: ItemQueryFilter) {
        self.text = text
        self.filter = filter
    }
}

public struct BrowserSearchResponse {
    public let request: SearchRequest
    public let items: [ItemMatch]
    public let firstPreviewPayload: PreviewPayload?
    public let totalCount: Int

    public var firstItem: ClipboardItem? {
        firstPreviewPayload?.item
    }

    public init(request: SearchRequest, items: [ItemMatch], firstPreviewPayload: PreviewPayload?, totalCount: Int) {
        self.request = request
        self.items = items
        self.firstPreviewPayload = firstPreviewPayload
        self.totalCount = totalCount
    }
}

public enum QueryLoadPhase {
    case debouncing
    case running(spinnerVisible: Bool)
}

public enum BrowserContentState {
    case idle(request: SearchRequest)
    case loading(request: SearchRequest, previous: LoadedBrowserContent?, phase: QueryLoadPhase)
    case loaded(LoadedBrowserContent)
    case failed(request: SearchRequest, message: String, previous: LoadedBrowserContent?)

    public var request: SearchRequest {
        switch self {
        case let .idle(request), let .loading(request, _, _), let .failed(request, _, _):
            return request
        case let .loaded(content):
            return content.response.request
        }
    }

    public var displayedContent: LoadedBrowserContent? {
        switch self {
        case let .loaded(content):
            return content
        case let .loading(_, previous, _), let .failed(_, _, previous):
            return previous
        case .idle:
            return nil
        }
    }

    public var response: BrowserSearchResponse? {
        displayedContent?.response
    }

    public var items: [ItemMatch] {
        switch self {
        case let .loaded(content):
            return content.response.items
        case let .loading(_, previous, _), let .failed(_, _, previous):
            return previous?.response.items ?? []
        case .idle:
            return []
        }
    }

    public var firstPreviewPayload: PreviewPayload? {
        switch self {
        case let .loaded(content):
            return content.response.firstPreviewPayload
        case let .loading(_, previous, _), let .failed(_, _, previous):
            return previous?.response.firstPreviewPayload
        case .idle:
            return nil
        }
    }

    public var isSearchSpinnerVisible: Bool {
        guard case let .loading(_, _, .running(spinnerVisible)) = self else { return false }
        return spinnerVisible
    }
}

public struct LoadedBrowserContent {
    public let response: BrowserSearchResponse

    public init(response: BrowserSearchResponse) {
        self.response = response
    }
}

public struct DisplayRow: Equatable, Identifiable {
    public let metadata: ItemMetadata
    public let presentation: RowPresentation

    public var id: String {
        metadata.itemId
    }

    public init(metadata: ItemMetadata, presentation: RowPresentation) {
        self.metadata = metadata
        self.presentation = presentation
    }
}

/// How a selection change happened. The origin informs two independent view
/// decisions: whether the preview pane auto-scrolls or tracks user highlights,
/// and whether the results list needs to scroll the selection into view.
public enum SelectionOrigin {
    /// Programmatic selection from search results, bookmark activation, or
    /// any flow where the user did not explicitly point at a specific row.
    case automatic
    /// The user clicked or tapped a row. The row is already on-screen.
    case click
    /// The user moved selection via keyboard (arrow keys, Cmd+N, etc.).
    /// The target may be outside the current viewport.
    case keyboard

    /// True when the user explicitly picked this item (click or keyboard),
    /// as opposed to a programmatic selection landing on the current item.
    public var isUserInitiated: Bool {
        switch self {
        case .automatic: return false
        case .click, .keyboard: return true
        }
    }

    /// Whether the results list should scroll the newly-selected item into
    /// view. A click targets a visible row; anything else may not be visible.
    public var requiresScrollIntoView: Bool {
        switch self {
        case .click: return false
        case .automatic, .keyboard: return true
        }
    }
}

public enum SelectedPreviewState: Equatable {
    case plain
    case loadingDecoration(previous: PreviewDecoration?)
    case highlighted(PreviewDecoration)
}

public struct SelectedItemState: Equatable {
    public let item: ClipboardItem
    public let origin: SelectionOrigin
    public let previewState: SelectedPreviewState

    public init(item: ClipboardItem, origin: SelectionOrigin, previewState: SelectedPreviewState) {
        self.item = item
        self.origin = origin
        self.previewState = previewState
    }
}

public enum SelectionState {
    case none
    case loading(itemId: String, origin: SelectionOrigin)
    case selected(SelectedItemState)
    case failed(itemId: String, origin: SelectionOrigin)

    public var itemId: String? {
        switch self {
        case .none:
            return nil
        case let .loading(itemId, _), let .failed(itemId, _):
            return itemId
        case let .selected(selectedItem):
            return selectedItem.item.itemMetadata.itemId
        }
    }

    public var origin: SelectionOrigin? {
        switch self {
        case .none:
            return nil
        case let .loading(_, origin), let .failed(_, origin):
            return origin
        case let .selected(selectedItem):
            return selectedItem.origin
        }
    }

    public var selectedItem: SelectedItemState? {
        guard case let .selected(selectedItem) = self else { return nil }
        return selectedItem
    }

    /// Lightweight label for os_signpost Points of Interest.
    public var poiLabel: String {
        switch self {
        case .none: return "none"
        case let .loading(itemId, _): return "loading(\(itemId))"
        case let .selected(state): return "selected(\(state.item.itemMetadata.itemId))"
        case let .failed(itemId, _): return "failed(\(itemId))"
        }
    }
}

public enum OverlayState {
    case none
    case actions(MenuHighlightState)
}

public enum MenuHighlightState {
    case none
    case index(Int)
}

/// The typed-filter suggestion surfaced above the results list, together with
/// the current keyboard target. The target is modeled here — not as list
/// selection — so the pending chip can own Enter without disturbing which item
/// is selected for the preview pane.
public enum PendingFilterState: Equatable {
    case none
    case suggested(TypedFilterSuggestion, keyboardTarget: PendingFilterKeyboardTarget)

    public var suggestion: TypedFilterSuggestion? {
        guard case let .suggested(suggestion, _) = self else { return nil }
        return suggestion
    }
}

/// What the keyboard currently addresses while a filter suggestion is visible.
/// A fresh suggestion surfaces with `.results`; the chip is opt-in.
public enum PendingFilterKeyboardTarget: Equatable {
    /// The suggestion chip, reached with Up from the first row: Enter applies
    /// the filter, Down returns to the results.
    case suggestion
    /// The result list (the default): keys behave as if no suggestion were
    /// showing, except Up from the first row moves to the chip.
    case results
}

/// What Enter and row-only shortcuts currently address, derived from
/// ``PendingFilterState``. Consumers switch on this instead of combining
/// booleans, so "chip owns the keyboard" and "a row owns the keyboard" stay
/// mutually exclusive by construction.
public enum BrowserKeyboardTarget: Equatable {
    /// The pending filter chip: Enter applies the suggested filter, and the
    /// preview pane advertises the filter instead of the selected item.
    case pendingFilterChip(TypedFilterSuggestion)
    /// The result list: Enter activates the selected row.
    case results
}

public enum MutationState {
    case idle
    case deleting(DeleteMutation)
    case tagging(TagMutation)
    case clearing(ClearTransaction)
    case failed(ActionFailure)
}

public enum DeleteMutation {
    case pending(DeleteTransaction)
    case committing(DeleteTransaction)
}

public struct DeleteTransaction {
    public var deletedItemIds: [String]
    public let snapshot: BrowserContentState
    public let selectionSnapshot: SelectionState

    public init(deletedItemIds: [String], snapshot: BrowserContentState, selectionSnapshot: SelectionState) {
        self.deletedItemIds = deletedItemIds
        self.snapshot = snapshot
        self.selectionSnapshot = selectionSnapshot
    }
}

public enum TagMutation {
    case pending(TagMutationTransaction)
    case settling(TagMutationTransaction)
}

public struct TagMutationTransaction {
    public let itemId: String
    public let tag: ItemTag
    public let shouldInclude: Bool
    public let snapshot: BrowserContentState
    public let selectionSnapshot: SelectionState

    public init(itemId: String, tag: ItemTag, shouldInclude: Bool, snapshot: BrowserContentState, selectionSnapshot: SelectionState) {
        self.itemId = itemId
        self.tag = tag
        self.shouldInclude = shouldInclude
        self.snapshot = snapshot
        self.selectionSnapshot = selectionSnapshot
    }
}

public struct ClearTransaction {
    public let snapshot: BrowserContentState
    public let selectionSnapshot: SelectionState

    public init(snapshot: BrowserContentState, selectionSnapshot: SelectionState) {
        self.snapshot = snapshot
        self.selectionSnapshot = selectionSnapshot
    }
}

public struct ActionFailure {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// Sum type representing the valid preview-edit session states.
///
/// This replaces the previous product-type `EditState` (focus + pendingEdits map)
/// to make invalid states unrepresentable. Call sites should pattern-match directly
/// on this enum rather than using derived booleans.
public enum PreviewEditSession: Equatable {
    /// No editing activity.
    case inactive

    /// User has focused the text surface but not yet changed text.
    case focused(itemId: String)

    /// User has unsaved edits. The draft text lives inside the editing state.
    case dirty(itemId: String, draft: String)
}
