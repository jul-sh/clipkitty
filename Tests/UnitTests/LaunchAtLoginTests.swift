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
