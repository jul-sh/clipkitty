@testable import ClipKittyMacPlatform
import XCTest

@MainActor
final class AccessibilityPermissionMonitorPollingTests: XCTestCase {
    private func makeMonitor() -> AccessibilityPermissionMonitor {
        AccessibilityPermissionMonitor(client: AccessibilityPermissionClient(
            isAccessibilityTrusted: { false },
            canPostEvents: { false },
            requestPostEventAccess: { false }
        ))
    }

    func testPollingSurvivesUntilEveryObserverHasStopped() {
        let monitor = makeMonitor()

        // Welcome and Settings can both be on screen during onboarding; the
        // first to disappear used to stop polling for the other.
        monitor.start()
        monitor.start()
        XCTAssertTrue(monitor.isPolling)

        monitor.stop()
        XCTAssertTrue(monitor.isPolling)

        monitor.stop()
        XCTAssertFalse(monitor.isPolling)
    }

    func testUnbalancedStopDoesNotUnderflow() {
        let monitor = makeMonitor()

        monitor.stop()
        monitor.start()
        XCTAssertTrue(monitor.isPolling)

        monitor.stop()
        XCTAssertFalse(monitor.isPolling)
    }
}
