import Foundation
import ServiceManagement

public protocol LaunchAtLoginServiceProtocol {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: @retroactive LaunchAtLoginServiceProtocol {}

public enum LaunchAtLoginState: Equatable {
    case available(status: RegistrationStatus, notice: Notice?)

    public enum RegistrationStatus: Equatable {
        case enabled
        case disabled
    }

    public enum Notice: Equatable {
        case registrationFailed
        case unregistrationFailed
    }

    public var displayMessage: String? {
        switch self {
        case .available(_, .registrationFailed):
            return String(localized: "Could not enable launch at login. Please add ClipKitty manually in System Settings.")
        case .available(_, .unregistrationFailed):
            return String(localized: "Could not disable launch at login. Please remove ClipKitty manually in System Settings.")
        case .available(_, nil):
            return nil
        }
    }

    public var isEnabled: Bool {
        switch self {
        case .available(.enabled, _):
            return true
        case .available(.disabled, _):
            return false
        }
    }

    public var canToggle: Bool {
        true
    }

    public var hasFailureNotice: Bool {
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
public final class LaunchAtLogin: ObservableObject {
    public static let shared = LaunchAtLogin()

    @Published public private(set) var state: LaunchAtLoginState

    public var isEnabled: Bool {
        state.isEnabled
    }

    public var errorMessage: String? {
        state.displayMessage
    }

    private let service: LaunchAtLoginServiceProtocol

    public init(
        service: LaunchAtLoginServiceProtocol = SMAppService.mainApp
    ) {
        self.service = service
        state = .available(status: .disabled, notice: nil)
        refreshState()
    }

    public func refreshState() {
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
    public func enable() -> Bool {
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
    public func disable() -> Bool {
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
    public func setEnabled(_ enabled: Bool) -> Bool {
        enabled ? enable() : disable()
    }
}
