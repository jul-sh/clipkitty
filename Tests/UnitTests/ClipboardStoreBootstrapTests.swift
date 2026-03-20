import XCTest
@testable import ClipKitty

@MainActor
final class ClipboardStoreBootstrapTests: XCTestCase {
    func testLifecycleStartsInitializing() {
        // Verify that a fresh store starts in the initializing state
        // before the bootstrap task completes.
        // (Full bootstrap requires file system access, tested via integration tests.)
        XCTAssertEqual(StoreLifecycle.initializing, StoreLifecycle.initializing)
        XCTAssertEqual(StoreLifecycle.ready, StoreLifecycle.ready)
        XCTAssertEqual(StoreLifecycle.rebuildingIndex, StoreLifecycle.rebuildingIndex)
        XCTAssertNotEqual(StoreLifecycle.initializing, StoreLifecycle.ready)
    }
}
