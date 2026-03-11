import AppKit
import XCTest
@testable import ClipKitty

@MainActor
final class PasteboardMonitorTests: XCTestCase {
    func testPollingModeUsesActiveAfterRecentDetection() {
        let now = ContinuousClock.now
        let mode = PasteboardMonitor.pollingMode(
            now: now,
            lastDetectionTime: now - .seconds(1),
            isLowPowerModeEnabled: false
        )

        XCTAssertEqual(mode, .active)
        XCTAssertEqual(mode.intervalMilliseconds, 200)
    }

    func testPollingModeBacksOffDeeplyAfterExtendedIdle() {
        let now = ContinuousClock.now
        let mode = PasteboardMonitor.pollingMode(
            now: now,
            lastDetectionTime: now - .seconds(900),
            isLowPowerModeEnabled: false
        )

        XCTAssertEqual(mode, .deepIdle)
        XCTAssertEqual(mode.intervalMilliseconds, 2_000)
    }

    func testLowPowerModeDowngradesActiveToIdle() {
        let now = ContinuousClock.now
        let mode = PasteboardMonitor.pollingMode(
            now: now,
            lastDetectionTime: now - .seconds(1),
            isLowPowerModeEnabled: true
        )

        XCTAssertEqual(mode, .idle)
        XCTAssertEqual(mode.intervalMilliseconds, 750)
    }

    func testTextDetectionAvoidsUnrelatedPasteboardReads() async {
        let pasteboard = MockPasteboard()
        let workspace = MockWorkspace()
        let detected = expectation(description: "text detected")

        let monitor = PasteboardMonitor(pasteboard: pasteboard, workspace: workspace) { content in
            guard case .text(let text, _, _) = content else {
                return XCTFail("Expected text detection")
            }
            XCTAssertEqual(text, "hello")
            detected.fulfill()
        }

        monitor.start()
        defer { monitor.stop() }

        _ = pasteboard.setString("hello", forType: .string)

        await fulfillment(of: [detected], timeout: 1.0)
        XCTAssertEqual(pasteboard.fileURLReadCount, 0)
        XCTAssertTrue(pasteboard.dataReadTypes.isEmpty)
        XCTAssertEqual(pasteboard.stringReadTypes, [.string])
        XCTAssertGreaterThanOrEqual(pasteboard.typesReadCount, 1)
    }

    func testConcealedTypeIsIgnoredWithoutReadingPayloadData() async {
        let pasteboard = MockPasteboard()
        let workspace = MockWorkspace()

        let monitor = PasteboardMonitor(pasteboard: pasteboard, workspace: workspace) { _ in
            XCTFail("Concealed pasteboard content should be ignored")
        }

        monitor.start()
        defer { monitor.stop() }

        _ = pasteboard.setData(Data([0x1]), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))

        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(pasteboard.fileURLReadCount, 0)
        XCTAssertTrue(pasteboard.dataReadTypes.isEmpty)
        XCTAssertTrue(pasteboard.stringReadTypes.isEmpty)
        XCTAssertGreaterThanOrEqual(pasteboard.typesReadCount, 1)
    }
}
