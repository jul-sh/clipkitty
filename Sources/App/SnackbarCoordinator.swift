import Foundation

@MainActor
final class SnackbarCoordinator {
    private let makeEnvironment: @MainActor () -> SnackbarEnvironment
    var showNotification: ((NotificationKind) -> Void)?

    init(
        store: ClipboardStore? = nil,
        makeEnvironment: (@MainActor () -> SnackbarEnvironment)? = nil
    ) {
        if let makeEnvironment {
            self.makeEnvironment = makeEnvironment
        } else {
            weak var weakStore = store
            self.makeEnvironment = { LiveSnackbarEnvironment(store: weakStore) }
        }
    }

    func evaluate() -> SnackbarDecision {
        evaluateSnackbar(makeEnvironment())
    }

    func handleNudgeAction(_ kind: NudgeKind) {
        AppSettings.shared.lastNudgeInteractionDate = Date()

        switch kind {
        case .launchAtLogin:
            AppSettings.shared.launchAtLoginPromptDismissed = true
            AppSettings.shared.launchAtLoginEnabled = true
            LaunchAtLogin.shared.enable()
            showNotification?(.passive(message: String(localized: "Launch at login enabled"), iconSystemName: "checkmark.circle.fill"))
        }
    }

    func handleNudgeDismiss(_ kind: NudgeKind) {
        AppSettings.shared.lastNudgeInteractionDate = Date()

        switch kind {
        case .launchAtLogin:
            AppSettings.shared.launchAtLoginPromptDismissed = true
        }
    }

    func handleInfoDismiss() {
        AppSettings.shared.lastInfoDismissDate = Date()
    }

    func syncWithSystem() {
        let settings = AppSettings.shared
        if settings.launchAtLoginEnabled, !LaunchAtLogin.shared.isEnabled {
            settings.launchAtLoginEnabled = false
            settings.launchAtLoginPromptDismissed = false
        }
    }
}
