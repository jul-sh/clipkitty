@testable import ClipKittyiOS
import XCTest

final class FeedSelectionStateTests: XCTestCase {
    func testDeselectingTransferredSubsetKeepsRemainingSelectionActive() {
        var state = FeedSelectionState()
        state.beginSelection()
        state.selectAll(in: ["accepted", "rejected", "also-accepted"])

        state.deselect(itemIDs: ["accepted", "also-accepted"])

        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.selectedItemIDs, ["rejected"])
    }

    func testDefaultStateIsInactiveAndEmpty() {
        let state = FeedSelectionState()

        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.selectedItemIDs.isEmpty)
        XCTAssertEqual(state.selectedCount, 0)
        XCTAssertEqual(state.orderedSelectedItemIDs(in: ["one", "two"]), [])
        XCTAssertFalse(state.areAllSelected(in: ["one", "two"]))
    }

    func testToggleAddsAndRemovesOnlyDuringActiveSession() {
        var state = FeedSelectionState()

        state.toggleSelection(for: "one")
        XCTAssertTrue(state.selectedItemIDs.isEmpty)

        state.beginSelection()
        state.toggleSelection(for: "one")
        state.toggleSelection(for: "two")
        XCTAssertEqual(state.selectedItemIDs, ["one", "two"])
        XCTAssertEqual(state.selectedCount, 2)

        state.toggleSelection(for: "one")
        XCTAssertEqual(state.selectedItemIDs, ["two"])
        XCTAssertEqual(state.selectedCount, 1)
    }

    func testOrderedSelectionUsesCurrentVisibleOrderAndDeduplicatesInput() {
        var state = FeedSelectionState()
        state.beginSelection()
        state.toggleSelection(for: "third")
        state.toggleSelection(for: "first")
        state.toggleSelection(for: "second")

        XCTAssertEqual(
            state.orderedSelectedItemIDs(in: ["first", "second", "second", "third"]),
            ["first", "second", "third"]
        )
        XCTAssertEqual(
            state.orderedSelectedItemIDs(in: ["third", "first"]),
            ["third", "first"]
        )
    }

    func testSelectAllAndDeselectAllKeepSessionActive() {
        var state = FeedSelectionState()
        state.beginSelection()

        state.selectAll(in: ["one", "two", "two", "three"])
        XCTAssertEqual(state.selectedItemIDs, ["one", "two", "three"])
        XCTAssertTrue(state.areAllSelected(in: ["one", "two", "three"]))
        XCTAssertFalse(state.areAllSelected(in: []))

        state.deselectAll()
        XCTAssertTrue(state.isActive)
        XCTAssertTrue(state.selectedItemIDs.isEmpty)
        XCTAssertFalse(state.areAllSelected(in: ["one", "two", "three"]))
    }

    func testSelectAndDeselectAllAreNoOpsWhileInactive() {
        var state = FeedSelectionState()

        state.selectAll(in: ["one", "two"])
        state.deselectAll()

        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.selectedItemIDs.isEmpty)
    }

    func testReconcileRemovesItemsThatAreNoLongerVisible() {
        var state = FeedSelectionState()
        state.beginSelection()
        state.selectAll(in: ["one", "two", "three"])

        state.reconcile(with: ["three", "four", "one"])

        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.selectedItemIDs, ["one", "three"])
        XCTAssertEqual(state.orderedSelectedItemIDs(in: ["three", "four", "one"]), ["three", "one"])
    }

    func testReconcileToEmptyKeepsSelectionSessionActive() {
        var state = FeedSelectionState()
        state.beginSelection()
        state.toggleSelection(for: "one")

        state.reconcile(with: [])

        XCTAssertTrue(state.isActive)
        XCTAssertTrue(state.selectedItemIDs.isEmpty)
    }

    func testCancelClearsSelectionAndReturnsToInactiveState() {
        var state = FeedSelectionState()
        state.beginSelection()
        state.selectAll(in: ["one", "two"])

        state.cancelSelection()

        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.selectedItemIDs.isEmpty)
        XCTAssertEqual(state.selectedCount, 0)

        state.toggleSelection(for: "three")
        XCTAssertTrue(state.selectedItemIDs.isEmpty)
    }
}
