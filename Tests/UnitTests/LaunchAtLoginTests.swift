import XCTest
import ServiceManagement
@testable import ClipKitty

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

// MARK: - Prompt State Machine Tests

@MainActor
final class LaunchAtLoginPromptStateMachineTests: XCTestCase {
    func testFreshInstallNonAppStore() {
        let env = MockPromptEnvironment()
        XCTAssertEqual(evaluatePromptState(env), .shouldPrompt)
    }

    func testFreshInstallAppStoreBelowTimeGate() {
        let now = Date()
        let env = MockPromptEnvironment(
            firstLaunchDate: now.addingTimeInterval(-1800), // 30 min ago
            now: now,
            isAppStore: true
        )
        XCTAssertEqual(evaluatePromptState(env), .suppressed(.timeGated))
    }

    func testFreshInstallAppStoreAboveTimeGate() {
        let now = Date()
        let env = MockPromptEnvironment(
            firstLaunchDate: now.addingTimeInterval(-7200), // 2 hours ago
            now: now,
            isAppStore: true
        )
        XCTAssertEqual(evaluatePromptState(env), .shouldPrompt)
    }

    func testAlreadyEnabled() {
        let env = MockPromptEnvironment(isSystemEnabled: true)
        XCTAssertEqual(evaluatePromptState(env), .suppressed(.alreadyEnabled))
    }

    func testPreviouslyDismissed() {
        let env = MockPromptEnvironment(isDismissed: true)
        XCTAssertEqual(evaluatePromptState(env), .suppressed(.dismissed))
    }

    func testAlreadyEnabledTakesPrecedenceOverDismissed() {
        let env = MockPromptEnvironment(isSystemEnabled: true, isDismissed: true)
        XCTAssertEqual(evaluatePromptState(env), .suppressed(.alreadyEnabled))
    }

    func testTimeGateExactBoundary() {
        let now = Date()
        let env = MockPromptEnvironment(
            firstLaunchDate: now.addingTimeInterval(-3600), // exactly 1 hour
            now: now,
            isAppStore: true
        )
        XCTAssertEqual(evaluatePromptState(env), .shouldPrompt)
    }

    func testTimeGateJustUnder() {
        let now = Date()
        let env = MockPromptEnvironment(
            firstLaunchDate: now.addingTimeInterval(-3599),
            now: now,
            isAppStore: true
        )
        XCTAssertEqual(evaluatePromptState(env), .suppressed(.timeGated))
    }
}

// MARK: - Mock types

private struct MockPromptEnvironment: PromptEnvironment {
    var isSystemEnabled: Bool = false
    var isDismissed: Bool = false
    var firstLaunchDate: Date = Date.distantPast
    var now: Date = Date()
    var minimumUseDuration: TimeInterval = 3600
    var isAppStore: Bool = false
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
