@testable import ClipKittyiOS
import XCTest

@MainActor
final class HapticsClientTests: XCTestCase {
    func testFireDoesNothingWhenHapticsDisabled() {
        let defaults = UserDefaults(suiteName: "HapticsClientTests")!
        defaults.removePersistentDomain(forName: "HapticsClientTests")
        defer { defaults.removePersistentDomain(forName: "HapticsClientTests") }

        let settings = iOSSettingsStore(defaults: defaults)
        settings.hapticsEnabled = false

        let client = HapticsClient(settings: settings)
        client.fire(.copy)
        client.fire(.selection)
        client.fire(.success)
        client.fire(.destructive)
        client.fire(.shortcutCompleted)
        client.fire(.cardActionCommitted)
    }

    func testFireDoesNotCrashWhenEnabled() {
        let defaults = UserDefaults(suiteName: "HapticsClientTests2")!
        defaults.removePersistentDomain(forName: "HapticsClientTests2")
        defer { defaults.removePersistentDomain(forName: "HapticsClientTests2") }

        let settings = iOSSettingsStore(defaults: defaults)
        settings.hapticsEnabled = true

        let client = HapticsClient(settings: settings)
        client.fire(.copy)
        client.fire(.success)
    }
}
