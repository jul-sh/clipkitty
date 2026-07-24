@testable import ClipKittyiOS
import XCTest

@MainActor
final class HapticsClientTests: XCTestCase {
    func testFireDoesNothingWhenHapticsDisabled() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HapticsClientTests"))
        defaults.removePersistentDomain(forName: "HapticsClientTests")
        defer { defaults.removePersistentDomain(forName: "HapticsClientTests") }

        let settings = iOSSettingsStore(defaults: defaults)
        settings.hapticsEnabled = false

        let client = HapticsClient(settings: settings)
        client.fire(.copy)
        client.fire(.selection)
        client.fire(.success)
        client.fire(.destructive)
    }

    func testFireDoesNotCrashWhenEnabled() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HapticsClientTests2"))
        defaults.removePersistentDomain(forName: "HapticsClientTests2")
        defer { defaults.removePersistentDomain(forName: "HapticsClientTests2") }

        let settings = iOSSettingsStore(defaults: defaults)
        settings.hapticsEnabled = true

        let client = HapticsClient(settings: settings)
        client.fire(.copy)
        client.fire(.success)
    }
}
