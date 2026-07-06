@testable import ClipKittyiOS
import XCTest

/// Covers the settle debounce in `ImageLoadActivity`: the gauge must not
/// report settled while work is in flight, nor in the handoff gap between a
/// fetch ending and the decode it feeds beginning — that transient zero is
/// exactly when a screenshot capture polling the signal must not fire.
@MainActor
final class ImageLoadActivityTests: XCTestCase {
    private var activity: ImageLoadActivity!

    override func setUp() {
        super.setUp()
        activity = ImageLoadActivity()
    }

    func testBeginFlipsSettledFalseImmediately() {
        XCTAssertTrue(activity.isSettled)
        activity.begin()
        XCTAssertFalse(activity.isSettled)
    }

    func testEndDoesNotSettleSynchronously() {
        activity.begin()
        activity.end()
        XCTAssertFalse(activity.isSettled, "settling must wait out the debounce delay")
    }

    func testSettlesAfterDebounceDelay() async throws {
        activity.begin()
        activity.end()
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(activity.isSettled)
    }

    func testBeginDuringDebounceKeepsLoading() async throws {
        activity.begin()
        activity.end()
        // A new load starting inside the debounce window (the fetch -> decode
        // handoff) must cancel the pending settle.
        activity.begin()
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertFalse(activity.isSettled)
    }

    func testOverlappingLoadsSettleOnlyWhenAllFinish() async throws {
        activity.begin()
        activity.begin()
        activity.end()
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertFalse(activity.isSettled, "one load is still in flight")
        activity.end()
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(activity.isSettled)
    }
}
