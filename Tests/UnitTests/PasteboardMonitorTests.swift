import AppKit
@testable import ClipKitty
import XCTest

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
        XCTAssertEqual(mode.intervalMilliseconds, 2000)
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
            guard case let .text(text, _, _) = content else {
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
        var detectionCount = 0

        let monitor = PasteboardMonitor(pasteboard: pasteboard, workspace: workspace) { _ in
            detectionCount += 1
        }

        monitor.start()
        defer { monitor.stop() }

        _ = pasteboard.setData(Data([0x1]), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))

        // Wait for at least one poll cycle to process the change
        while pasteboard.typesReadCount < 1 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(detectionCount, 0, "Concealed pasteboard content should be ignored")
        XCTAssertEqual(pasteboard.fileURLReadCount, 0)
        XCTAssertTrue(pasteboard.dataReadTypes.isEmpty)
        XCTAssertTrue(pasteboard.stringReadTypes.isEmpty)
    }
}
