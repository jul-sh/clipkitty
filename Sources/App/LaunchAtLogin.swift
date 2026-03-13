import Foundation
import ServiceManagement

protocol LaunchAtLoginServiceProtocol {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LaunchAtLoginServiceProtocol {}

enum LaunchAtLoginState: Equatable {
    case unavailable(reason: UnavailableReason, notice: Notice?)
    case available(status: RegistrationStatus, notice: Notice?)

    enum RegistrationStatus: Equatable {
        case enabled
        case disabled
    }

    enum UnavailableReason: Equatable {
        case notInApplicationsDirectory
    }

    enum Notice: Equatable {
        case registrationFailed
        case unregistrationFailed
        case disabledDueToLocation
    }

    var displayMessage: String? {
        switch self {
        case .unavailable(.notInApplicationsDirectory, .disabledDueToLocation):
            return String(localized: "Launch at login was disabled because ClipKitty is not in the Applications folder.")
        case .unavailable(.notInApplicationsDirectory, _):
            return String(localized: "Move ClipKitty to the Applications folder to enable this option.")
        case .available(_, .registrationFailed):
            return String(localized: "Could not enable launch at login. Please add ClipKitty manually in System Settings.")
        case .available(_, .unregistrationFailed):
            return String(localized: "Could not disable launch at login. Please remove ClipKitty manually in System Settings.")
        case .available(_, .disabledDueToLocation):
            return String(localized: "Launch at login was disabled because ClipKitty is not in the Applications folder.")
        case .available, .unavailable(_, nil):
            return nil
        }
    }

    var isEnabled: Bool {
        switch self {
        case .available(.enabled, _):
            return true
        case .available(.disabled, _), .unavailable:
            return false
        }
    }

    var canToggle: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    var hasFailureNotice: Bool {
        switch self {
        case .available(_, .registrationFailed), .available(_, .unregistrationFailed):
            return true
        case .available(_, .disabledDueToLocation):
            return true
        case .unavailable(_, .disabledDueToLocation):
            return true
        case .available(_, nil), .unavailable:
            return false
        }
    }
}

/// Manages the app's launch-at-login registration using SMAppService.
///
/// Key behaviors:
/// - Only allows registration when the app is in /Applications or ~/Applications
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

    var isInApplicationsDirectory: Bool {
        Self.isInApplicationsDirectory(bundle: bundle, fileManager: fileManager)
    }

    private let service: LaunchAtLoginServiceProtocol
    private let bundle: BundleInfoProtocol
    private let fileManager: FileManagerProtocol

    init(
        service: LaunchAtLoginServiceProtocol = SMAppService.mainApp,
        bundle: BundleInfoProtocol = Bundle.main,
        fileManager: FileManagerProtocol = FileManager.default
    ) {
        self.service = service
        self.bundle = bundle
        self.fileManager = fileManager
        state = .available(status: .disabled, notice: nil)
        refreshState()
    }

    static func isInApplicationsDirectory(
        bundle: BundleInfoProtocol,
        fileManager: FileManagerProtocol
    ) -> Bool {
        let path = bundle.bundlePath
        let systemApps = "/Applications/"
        let userApps = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications")
            .path + "/"
        return path.hasPrefix(systemApps) || path.hasPrefix(userApps)
    }

    func refreshState() {
        refreshState(retaining: nil)
    }

    private func refreshState(retaining notice: LaunchAtLoginState.Notice?) {
        guard isInApplicationsDirectory else {
            state = .unavailable(reason: .notInApplicationsDirectory, notice: notice)
            return
        }

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
        guard state.canToggle else { return false }

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
        guard state.canToggle else { return false }

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

    func setDisabledDueToLocationError() {
        state = .unavailable(reason: .notInApplicationsDirectory, notice: .disabledDueToLocation)
    }
}
