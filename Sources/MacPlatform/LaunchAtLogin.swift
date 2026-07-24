import Foundation
import ServiceManagement

public protocol LaunchAtLoginServiceProtocol {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LaunchAtLoginServiceProtocol {}

public enum LaunchAtLoginState: Equatable {
    case enabled
    case disabled
    case registrationFailed(currentStatus: RegistrationStatus)
    case unregistrationFailed(currentStatus: RegistrationStatus)

    public enum RegistrationStatus: Equatable {
        case enabled
        case disabled
    }

    public var displayMessage: String? {
        switch self {
        case .registrationFailed:
            return String(localized: "Could not enable launch at login. Please add ClipKitty manually in System Settings.")
        case .unregistrationFailed:
            return String(localized: "Could not disable launch at login. Please remove ClipKitty manually in System Settings.")
        case .enabled, .disabled:
            return nil
        }
    }

    public var registrationStatus: RegistrationStatus {
        switch self {
        case .enabled:
            return .enabled
        case .disabled:
            return .disabled
        case let .registrationFailed(currentStatus), let .unregistrationFailed(currentStatus):
            return currentStatus
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

    private let service: LaunchAtLoginServiceProtocol

    public init(
        service: LaunchAtLoginServiceProtocol = SMAppService.mainApp
    ) {
        self.service = service
        state = .disabled
        refreshState()
    }

    public func refreshState() {
        switch currentRegistrationStatus() {
        case .enabled:
            state = .enabled
        case .disabled:
            state = .disabled
        }
    }

    private func currentRegistrationStatus() -> LaunchAtLoginState.RegistrationStatus {
        switch service.status {
        case .enabled:
            return .enabled
        case .notRegistered, .requiresApproval, .notFound:
            return .disabled
        @unknown default:
            return .disabled
        }
    }

    @discardableResult
    public func enable() -> Bool {
        do {
            try service.register()
            refreshState()
            return true
        } catch {
            state = .registrationFailed(currentStatus: currentRegistrationStatus())
            return false
        }
    }

    @discardableResult
    public func disable() -> Bool {
        do {
            try service.unregister()
            refreshState()
            return true
        } catch {
            state = .unregistrationFailed(currentStatus: currentRegistrationStatus())
            return false
        }
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        enabled ? enable() : disable()
    }
}
