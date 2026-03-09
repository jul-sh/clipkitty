import XCTest
import ServiceManagement
@testable import ClipKitty

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    func testUnavailableStateSeparatesLocationFromFailureNotice() {
        let launchAtLogin = makeSubject(
            status: .enabled,
            bundlePath: "/tmp/ClipKitty.app"
        )

        XCTAssertEqual(
            launchAtLogin.state,
            .unavailable(reason: .notInApplicationsDirectory, notice: nil)
        )

        launchAtLogin.setDisabledDueToLocationError()

        XCTAssertEqual(
            launchAtLogin.state,
            .unavailable(reason: .notInApplicationsDirectory, notice: .disabledDueToLocation)
        )
        XCTAssertFalse(launchAtLogin.state.canToggle)
    }

    func testRegistrationFailureKeepsToggleActionable() {
        let service = MockLaunchAtLoginService(status: .notRegistered)
        service.registerError = NSError(domain: "Test", code: 1)
        let launchAtLogin = makeSubject(service: service)

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
        let launchAtLogin = makeSubject(service: service)

        XCTAssertFalse(launchAtLogin.enable())

        service.registerError = nil
        service.status = .enabled

        XCTAssertTrue(launchAtLogin.enable())
        XCTAssertEqual(
            launchAtLogin.state,
            .available(status: .enabled, notice: nil)
        )
    }

    private func makeSubject(
        service: MockLaunchAtLoginService = MockLaunchAtLoginService(status: .notRegistered),
        status: SMAppService.Status = .notRegistered,
        bundlePath: String = "/Applications/ClipKitty.app"
    ) -> LaunchAtLogin {
        service.status = status
        return LaunchAtLogin(
            service: service,
            bundle: MockBundleInfo(bundlePath: bundlePath),
            fileManager: MockFileManager()
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

private struct MockBundleInfo: BundleInfoProtocol {
    var bundleIdentifier: String? = "com.example.clipkitty"
    var bundlePath: String
}
