import Foundation

/// Persisted lifecycle facts used by onboarding. Deliberately separate from
/// `iOSSettingsStore`: these are facts about what the user has already been
/// shown, not preferences they can configure. Mirrors the macOS
/// `AppLifecycleState`.
@MainActor
@Observable
final class iOSLifecycleState {
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.completedOnboarding) }
    }

    private enum Keys {
        static let completedOnboarding = "iOSHasCompletedOnboarding"
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasCompletedOnboarding = defaults.bool(forKey: Keys.completedOnboarding)
    }
}
