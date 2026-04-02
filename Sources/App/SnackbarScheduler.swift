import Foundation

// MARK: - Decision type

enum SnackbarDecision: Equatable {
    case show(SnackbarItem)
    case showNothing
}

// MARK: - Environment protocol

protocol SnackbarEnvironment {
    // Info conditions
    var isRebuildingIndex: Bool { get }

    // Cooldowns
    var lastInfoDismissDate: Date? { get }
    var lastNudgeInteractionDate: Date? { get }
    var cooldownAfterInfo: TimeInterval { get }
    var cooldownAfterNudgeInteraction: TimeInterval { get }
    var now: Date { get }

    // Launch-at-login nudge conditions
    var isLaunchAtLoginSystemEnabled: Bool { get }
    var isLaunchAtLoginDismissed: Bool { get }
    var firstLaunchDate: Date { get }
    var minimumUseDuration: TimeInterval { get }
}

// MARK: - Pure decision function

func evaluateSnackbar(_ env: SnackbarEnvironment) -> SnackbarDecision {
    // 1. Info conditions take priority
    if env.isRebuildingIndex {
        return .show(.info(.rebuildingIndex))
    }

    // 2. Cooldown after info dismissed
    if let lastInfo = env.lastInfoDismissDate,
       env.now.timeIntervalSince(lastInfo) < env.cooldownAfterInfo
    {
        return .showNothing
    }

    // 3. Cooldown after nudge interaction
    if let lastNudge = env.lastNudgeInteractionDate,
       env.now.timeIntervalSince(lastNudge) < env.cooldownAfterNudgeInteraction
    {
        return .showNothing
    }

    // 4. Evaluate nudges in priority order
    if evaluateLaunchAtLoginNudge(env) {
        return .show(.nudge(.launchAtLogin))
    }

    return .showNothing
}

// MARK: - Nudge evaluation helpers

private func evaluateLaunchAtLoginNudge(_ env: SnackbarEnvironment) -> Bool {
    if env.isLaunchAtLoginSystemEnabled { return false }
    if env.isLaunchAtLoginDismissed { return false }
    let elapsed = env.now.timeIntervalSince(env.firstLaunchDate)
    if elapsed < env.minimumUseDuration { return false }
    return true
}

// MARK: - Production environment

@MainActor
struct LiveSnackbarEnvironment: SnackbarEnvironment {
    private weak var store: ClipboardStore?

    init(store: ClipboardStore? = nil) {
        self.store = store
    }

    var isRebuildingIndex: Bool { store?.lifecycle == .rebuildingIndex }

    var lastInfoDismissDate: Date? { AppSettings.shared.lastInfoDismissDate }
    var lastNudgeInteractionDate: Date? { AppSettings.shared.lastNudgeInteractionDate }
    var cooldownAfterInfo: TimeInterval { 10 * 60 }
    var cooldownAfterNudgeInteraction: TimeInterval { 7 * 24 * 60 * 60 }
    var now: Date { Date() }

    var isLaunchAtLoginSystemEnabled: Bool { LaunchAtLogin.shared.isEnabled }
    var isLaunchAtLoginDismissed: Bool { AppSettings.shared.launchAtLoginPromptDismissed }
    var firstLaunchDate: Date { AppSettings.shared.firstLaunchDate }
    var minimumUseDuration: TimeInterval { 3 * 24 * 60 * 60 }
}
