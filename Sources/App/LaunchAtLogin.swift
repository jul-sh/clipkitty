import Foundation
import ServiceManagement

protocol LaunchAtLoginServiceProtocol {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LaunchAtLoginServiceProtocol {}

enum LaunchAtLoginState: Equatable {
    case available(status: RegistrationStatus, notice: Notice?)

    enum RegistrationStatus: Equatable {
        case enabled
        case disabled
    }

    enum Notice: Equatable {
        case registrationFailed
        case unregistrationFailed
    }

    var displayMessage: String? {
        switch self {
        case .available(_, .registrationFailed):
            return String(localized: "Could not enable launch at login. Please add ClipKitty manually in System Settings.")
        case .available(_, .unregistrationFailed):
            return String(localized: "Could not disable launch at login. Please remove ClipKitty manually in System Settings.")
        case .available(_, nil):
            return nil
        }
    }

    var isEnabled: Bool {
        switch self {
        case .available(.enabled, _):
            return true
        case .available(.disabled, _):
            return false
        }
    }

    var canToggle: Bool {
        true
    }

    var hasFailureNotice: Bool {
        switch self {
        case .available(_, .registrationFailed), .available(_, .unregistrationFailed):
            return true
        case .available(_, nil):
            return false
        }
    }
}

/// Manages the app's launch-at-login registration using SMAppService.
///
/// Key behaviors:
/// - Uses the app's bundle identifier to ensure only one registration exists
/// - Keeps the toggle actionable after transient failures
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    @Published private(set) var state: LaunchAtLoginState

    var isEnabled: Bool {
        state.isEnabled
    }

    var errorMessage: String? {
        state.displayMessage
    }

    private let service: LaunchAtLoginServiceProtocol

    init(
        service: LaunchAtLoginServiceProtocol = SMAppService.mainApp
    ) {
        self.service = service
        state = .available(status: .disabled, notice: nil)
        refreshState()
    }

    func refreshState() {
        refreshState(retaining: nil)
    }

    private func refreshState(retaining notice: LaunchAtLoginState.Notice?) {
        let status: LaunchAtLoginState.RegistrationStatus
        switch service.status {
        case .enabled:
            status = .enabled
        case .notRegistered, .requiresApproval, .notFound:
            status = .disabled
        @unknown default:
            status = .disabled
        }

        state = .available(status: status, notice: notice)
    }

    @discardableResult
    func enable() -> Bool {
        do {
            try service.register()
            objectWillChange.send()
            refreshState()
            return true
        } catch {
            objectWillChange.send()
            refreshState(retaining: .registrationFailed)
            return false
        }
    }

    @discardableResult
    func disable() -> Bool {
        do {
            try service.unregister()
            objectWillChange.send()
            refreshState()
            return true
        } catch {
            objectWillChange.send()
            refreshState(retaining: .unregistrationFailed)
            return false
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        enabled ? enable() : disable()
    }
}
