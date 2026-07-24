import ClipKittyCore
import ClipKittyMacPlatform
import Foundation

@MainActor
final class SnackbarCoordinator {
    private let makeEnvironment: @MainActor () -> SnackbarEnvironment
    var showNotification: ((NotificationRequest) -> Void)?

    init(
        store: ClipboardStore? = nil,
        makeEnvironment: (@MainActor () -> SnackbarEnvironment)? = nil
    ) {
        if let makeEnvironment {
            self.makeEnvironment = makeEnvironment
        } else {
            self.makeEnvironment = { [weak store] in LiveSnackbarEnvironment(store: store) }
        }
    }

    func evaluate() -> SnackbarDecision {
        evaluateSnackbar(makeEnvironment())
    }

    func handleNudgeAction(_ kind: NudgeKind) {
        AppLifecycleState.shared.lastNudgeInteractionDate = Date()

        switch kind {
        case .launchAtLogin:
            AppLifecycleState.shared.launchAtLoginPromptDismissed = true
            AppSettings.shared.launchAtLoginEnabled = true
            LaunchAtLogin.shared.enable()
            showNotification?(.passive(message: String(localized: "Launch at login enabled"), iconSystemName: "checkmark.circle.fill"))
        }
    }

    func handleNudgeDismiss(_ kind: NudgeKind) {
        AppLifecycleState.shared.lastNudgeInteractionDate = Date()

        switch kind {
        case .launchAtLogin:
            AppLifecycleState.shared.launchAtLoginPromptDismissed = true
        }
    }

    func handleInfoDismiss() {
        AppLifecycleState.shared.lastInfoDismissDate = Date()
    }

    func syncWithSystem() {
        let settings = AppSettings.shared
        if settings.launchAtLoginEnabled,
           case .disabled = LaunchAtLogin.shared.state.registrationStatus
        {
            settings.launchAtLoginEnabled = false
            AppLifecycleState.shared.launchAtLoginPromptDismissed = false
        }
    }
}
