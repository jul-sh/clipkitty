import Combine
import Foundation

/// Persisted lifecycle facts used by onboarding and informational nudges.
/// They are intentionally separate from user-configurable preferences.
@MainActor
final class AppLifecycleState: ObservableObject {
    static let shared = AppLifecycleState()

    @Published var launchAtLoginPromptDismissed: Bool {
        didSet { defaults.set(launchAtLoginPromptDismissed, forKey: Keys.launchPromptDismissed) }
    }

    @Published var lastInfoDismissDate: Date? {
        didSet { defaults.set(lastInfoDismissDate, forKey: Keys.lastInfoDismissDate) }
    }

    @Published var lastNudgeInteractionDate: Date? {
        didSet { defaults.set(lastNudgeInteractionDate, forKey: Keys.lastNudgeInteractionDate) }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.completedOnboarding) }
    }

    let firstLaunchDate: Date

    private enum Keys {
        static let launchPromptDismissed = "launchAtLoginPromptDismissed"
        static let lastInfoDismissDate = "lastInfoDismissDate"
        static let lastNudgeInteractionDate = "lastNudgeInteractionDate"
        static let completedOnboarding = "hasCompletedOnboarding"
        static let firstLaunchDate = "firstLaunchDate"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, now: () -> Date = Date.init) {
        self.defaults = defaults
        launchAtLoginPromptDismissed = defaults.bool(forKey: Keys.launchPromptDismissed)
        lastInfoDismissDate = defaults.object(forKey: Keys.lastInfoDismissDate) as? Date
        lastNudgeInteractionDate = defaults.object(forKey: Keys.lastNudgeInteractionDate) as? Date
        hasCompletedOnboarding = defaults.bool(forKey: Keys.completedOnboarding)

        if let stored = defaults.object(forKey: Keys.firstLaunchDate) as? Date {
            firstLaunchDate = stored
        } else {
            let date = now()
            firstLaunchDate = date
            defaults.set(date, forKey: Keys.firstLaunchDate)
        }
    }
}
