import Foundation

// MARK: - Decision type

enum PromptDecision: Equatable {
    case shouldPrompt
    case suppressed(Reason)

    enum Reason: Equatable {
        case alreadyEnabled
        case dismissed
        case timeGated
    }
}

// MARK: - Environment protocol

protocol PromptEnvironment {
    var isSystemEnabled: Bool { get }
    var isDismissed: Bool { get }
    var firstLaunchDate: Date { get }
    var now: Date { get }
    var minimumUseDuration: TimeInterval { get }
}

// MARK: - Pure decision function

func evaluatePromptState(_ env: PromptEnvironment) -> PromptDecision {
    if env.isSystemEnabled { return .suppressed(.alreadyEnabled) }
    if env.isDismissed { return .suppressed(.dismissed) }
    let elapsed = env.now.timeIntervalSince(env.firstLaunchDate)
    if elapsed < env.minimumUseDuration { return .suppressed(.timeGated) }
    return .shouldPrompt
}

// MARK: - Production environment

@MainActor
struct LivePromptEnvironment: PromptEnvironment {
    var isSystemEnabled: Bool { LaunchAtLogin.shared.isEnabled }
    var isDismissed: Bool { AppSettings.shared.launchAtLoginPromptDismissed }
    var firstLaunchDate: Date { AppSettings.shared.firstLaunchDate }
    var now: Date { Date() }
    var minimumUseDuration: TimeInterval { 24 * 60 * 60 }
}

// MARK: - Coordinator

@MainActor
final class LaunchAtLoginPromptCoordinator {
    private let makeEnvironment: @MainActor () -> PromptEnvironment

    init(makeEnvironment: @escaping @MainActor () -> PromptEnvironment = { LivePromptEnvironment() }) {
        self.makeEnvironment = makeEnvironment
    }

    func evaluate() -> PromptDecision {
        evaluatePromptState(makeEnvironment())
    }

    func handleEnable() {
        AppSettings.shared.launchAtLoginPromptDismissed = true
        AppSettings.shared.launchAtLoginEnabled = true
        LaunchAtLogin.shared.enable()
        ToastWindow.shared.show(message: String(localized: "Launch at login enabled"))
    }

    func handleDismiss() {
        AppSettings.shared.launchAtLoginPromptDismissed = true
    }

    func syncWithSystem() {
        let settings = AppSettings.shared
        if settings.launchAtLoginEnabled, !LaunchAtLogin.shared.isEnabled {
            settings.launchAtLoginEnabled = false
            settings.launchAtLoginPromptDismissed = false
        }
    }
}
