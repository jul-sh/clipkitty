@testable import ClipKitty
@testable import ClipKittyMacPlatform
import ServiceManagement
import XCTest

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    func testRegistrationFailureKeepsToggleActionable() {
        let service = MockLaunchAtLoginService(status: .notRegistered)
        service.registerError = NSError(domain: "Test", code: 1)
        let launchAtLogin = LaunchAtLogin(service: service)

        XCTAssertFalse(launchAtLogin.enable())
        XCTAssertEqual(
            launchAtLogin.state,
            .available(status: .disabled, notice: .registrationFailed)
        )
        XCTAssertTrue(launchAtLogin.state.canToggle)
    }

    func testSuccessfulRetryClearsFailureNotice() {
        let service = MockLaunchAtLoginService(status: .notRegistered)
        service.registerError = NSError(domain: "Test", code: 1)
        let launchAtLogin = LaunchAtLogin(service: service)

        XCTAssertFalse(launchAtLogin.enable())

        service.registerError = nil
        service.status = .enabled

        XCTAssertTrue(launchAtLogin.enable())
        XCTAssertEqual(
            launchAtLogin.state,
            .available(status: .enabled, notice: nil)
        )
    }
}

// MARK: - Snackbar Scheduler Tests

@MainActor
final class SnackbarSchedulerTests: XCTestCase {

    // MARK: - Nudge tests (migrated from LaunchAtLoginPromptStateMachineTests)

    func testFreshInstallAboveTimeGate() {
        let env = MockSnackbarEnvironment()
        XCTAssertEqual(evaluateSnackbar(env), .show(.nudge(.launchAtLogin)))
    }

    func testFreshInstallBelowTimeGate() {
        let now = Date()
        let env = MockSnackbarEnvironment(
            firstLaunchDate: now.addingTimeInterval(-1800), // 30 min ago
            now: now
        )
        XCTAssertEqual(evaluateSnackbar(env), .showNothing)
    }

    func testAlreadyEnabled() {
        let env = MockSnackbarEnvironment(isLaunchAtLoginSystemEnabled: true)
        XCTAssertEqual(evaluateSnackbar(env), .showNothing)
    }

    func testPreviouslyDismissed() {
        let env = MockSnackbarEnvironment(isLaunchAtLoginDismissed: true)
        XCTAssertEqual(evaluateSnackbar(env), .showNothing)
    }

    func testAlreadyEnabledTakesPrecedenceOverDismissed() {
        let env = MockSnackbarEnvironment(isLaunchAtLoginSystemEnabled: true, isLaunchAtLoginDismissed: true)
        XCTAssertEqual(evaluateSnackbar(env), .showNothing)
    }

    func testTimeGateExactBoundary() {
        let now = Date()
        let env = MockSnackbarEnvironment(
            firstLaunchDate: now.addingTimeInterval(-3600), // exactly 1 hour
            now: now
        )
        XCTAssertEqual(evaluateSnackbar(env), .show(.nudge(.launchAtLogin)))
    }

    func testTimeGateJustUnder() {
        let now = Date()
        let env = MockSnackbarEnvironment(
            firstLaunchDate: now.addingTimeInterval(-3599),
            now: now
        )
        XCTAssertEqual(evaluateSnackbar(env), .showNothing)
    }

    // MARK: - Info priority tests

    func testInfoTrumpsNudge() {
        let env = MockSnackbarEnvironment(isRebuildingIndex: true)
        XCTAssertEqual(evaluateSnackbar(env), .show(.info(.rebuildingIndex)))
    }

    func testInfoShownDuringRebuild() {
        let env = MockSnackbarEnvironment(isRebuildingIndex: true)
        XCTAssertEqual(evaluateSnackbar(env), .show(.info(.rebuildingIndex)))
    }

    // MARK: - Cooldown tests

    func testCooldownAfterInfoBlocksNudge() {
        let now = Date()
        let env = MockSnackbarEnvironment(
            lastInfoDismissDate: now.addingTimeInterval(-60), // 1 min ago
            now: now
        )
        XCTAssertEqual(evaluateSnackbar(env), .showNothing)
    }

    func testCooldownAfterInfoExpired() {
        let now = Date()
        let env = MockSnackbarEnvironment(
            lastInfoDismissDate: now.addingTimeInterval(-3601), // over 1 hour ago
            now: now
        )
        XCTAssertEqual(evaluateSnackbar(env), .show(.nudge(.launchAtLogin)))
    }

    func testCooldownAfterNudgeInteraction() {
        let now = Date()
        let env = MockSnackbarEnvironment(
            lastNudgeInteractionDate: now.addingTimeInterval(-3600), // 1 hour ago, well within 7 days
            now: now
        )
        XCTAssertEqual(evaluateSnackbar(env), .showNothing)
    }

    func testCooldownAfterNudgeExpired() {
        let now = Date()
        let env = MockSnackbarEnvironment(
            lastNudgeInteractionDate: now.addingTimeInterval(-8 * 24 * 60 * 60), // 8 days ago
            now: now
        )
        XCTAssertEqual(evaluateSnackbar(env), .show(.nudge(.launchAtLogin)))
    }

    func testNothingActiveShowsNothing() {
        let env = MockSnackbarEnvironment(isLaunchAtLoginSystemEnabled: true)
        XCTAssertEqual(evaluateSnackbar(env), .showNothing)
    }
}

// MARK: - Mock types

private struct MockSnackbarEnvironment: SnackbarEnvironment {
    var isRebuildingIndex: Bool = false

    var lastInfoDismissDate: Date? = nil
    var lastNudgeInteractionDate: Date? = nil
    var cooldownAfterInfo: TimeInterval = 3600
    var cooldownAfterNudgeInteraction: TimeInterval = 7 * 24 * 60 * 60

    var isLaunchAtLoginSystemEnabled: Bool = false
    var isLaunchAtLoginDismissed: Bool = false
    var firstLaunchDate: Date = Date.distantPast
    var minimumUseDuration: TimeInterval = 3600
    var now: Date = Date()

    var isUpdateAvailable: Bool = false
}

private final class MockLaunchAtLoginService: LaunchAtLoginServiceProtocol {
    var status: SMAppService.Status
    var registerError: Error?
    var unregisterError: Error?

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        if let registerError {
            throw registerError
        }
    }

    func unregister() throws {
        if let unregisterError {
            throw unregisterError
        }
    }
}
