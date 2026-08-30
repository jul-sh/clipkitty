import Foundation

/// Session-local multiple selection for the iOS history feed.
///
/// The browser's shared `SelectionState` intentionally represents one item
/// whose preview is loaded. Feed selection is a separate concern: it stores
/// only stable item identifiers and lets the caller supply the current visible
/// order whenever an action needs deterministic ordering.
struct FeedSelectionState: Equatable {
    private(set) var isActive = false
    private(set) var selectedItemIDs: Set<String> = []

    var selectedCount: Int {
        selectedItemIDs.count
    }

    mutating func beginSelection() {
        isActive = true
        selectedItemIDs.removeAll()
    }

    mutating func cancelSelection() {
        isActive = false
        selectedItemIDs.removeAll()
    }

    mutating func toggleSelection(for itemID: String) {
        guard isActive else { return }

        if selectedItemIDs.contains(itemID) {
            selectedItemIDs.remove(itemID)
        } else {
            selectedItemIDs.insert(itemID)
        }
    }

    mutating func selectAll(in visibleItemIDs: [String]) {
        guard isActive else { return }
        selectedItemIDs = Set(visibleItemIDs)
    }

    mutating func deselectAll() {
        guard isActive else { return }
        selectedItemIDs.removeAll()
    }

    mutating func deselect(itemIDs: [String]) {
        guard isActive else { return }
        selectedItemIDs.subtract(itemIDs)
    }

    /// Drops selections that disappeared after a search, filter, sync, or
    /// mutation refresh. The selection session remains active even when no
    /// selected items survive.
    mutating func reconcile(with visibleItemIDs: [String]) {
        guard isActive else {
            selectedItemIDs.removeAll()
            return
        }
        selectedItemIDs.formIntersection(visibleItemIDs)
    }

    /// Selected identifiers in the feed's current visible order, independent
    /// of the order in which the user tapped the cards. Defensive de-duplication
    /// keeps an invalid repeated visible identifier from producing two actions.
    func orderedSelectedItemIDs(in visibleItemIDs: [String]) -> [String] {
        guard isActive, !selectedItemIDs.isEmpty else { return [] }

        var emitted: Set<String> = []
        return visibleItemIDs.filter { itemID in
            selectedItemIDs.contains(itemID) && emitted.insert(itemID).inserted
        }
    }

    func areAllSelected(in visibleItemIDs: [String]) -> Bool {
        guard isActive, !visibleItemIDs.isEmpty else { return false }
        return Set(visibleItemIDs).isSubset(of: selectedItemIDs)
    }
}
