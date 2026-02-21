import Foundation
import ServiceManagement

enum LaunchAtLoginState: Equatable {
    case enabled
    case disabled
    case unavailable(reason: UnavailableReason)
    case error(type: ErrorType)

    enum UnavailableReason: Equatable {
        case notInApplicationsDirectory
        case serviceNotFound
    }

    enum ErrorType: Equatable {
        case registrationFailed
        case unregistrationFailed
        case disabledDueToLocation
    }

    var displayMessage: String? {
        switch self {
        case .enabled, .disabled:
            return nil
        case .unavailable(.notInApplicationsDirectory):
            return String(localized: "Move ClipKitty to the Applications folder to enable this option.")
        case .unavailable(.serviceNotFound):
            return String(localized: "Launch at login service not found.")
        case .error(.registrationFailed):
            return String(localized: "Could not enable launch at login. Please add ClipKitty manually in System Settings.")
        case .error(.unregistrationFailed):
            return String(localized: "Could not disable launch at login. Please remove ClipKitty manually in System Settings.")
        case .error(.disabledDueToLocation):
            return String(localized: "Launch at login was disabled because ClipKitty is not in the Applications folder.")
        }
    }
}

/// Manages the app's launch-at-login registration using SMAppService.
///
/// Key behaviors:
/// - Only allows registration when the app is in /Applications or ~/Applications
/// - Uses the app's bundle identifier to ensure only one registration exists
/// - Silent operation - no terminal windows or user prompts
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    /// The current state of launch at login
    @Published private(set) var state: LaunchAtLoginState = .disabled

    /// Whether the app is currently registered to launch at login (reads directly from system)
    var isEnabled: Bool {
        service.status == .enabled
    }

    /// Error message to display to user, if any (for backward compatibility)
    var errorMessage: String? {
        state.displayMessage
    }

    /// Whether the app is in a valid location to enable launch at login
    var isInApplicationsDirectory: Bool {
        guard let bundlePath = Bundle.main.bundlePath as NSString? else {
            return false
        }

        let path = bundlePath as String

        // Check for /Applications or ~/Applications
        let systemApps = "/Applications/"
        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications")
            .path + "/"

        return path.hasPrefix(systemApps) || path.hasPrefix(userApps)
    }

    private let service: SMAppService

    private init() {
        // SMAppService uses the app's bundle identifier automatically
        // This ensures only one registration per bundle ID (no duplicates)
        service = SMAppService.mainApp
        updateState()
    }

    /// Updates the state based on current service status and app location
    private func updateState() {
        // First check if we're in the Applications directory
        guard isInApplicationsDirectory else {
            state = .unavailable(reason: .notInApplicationsDirectory)
            return
        }

        // Check service status
        switch service.status {
        case .enabled:
            state = .enabled
        case .notRegistered, .requiresApproval:
            state = .disabled
        case .notFound:
            state = .unavailable(reason: .serviceNotFound)
        @unknown default:
            state = .disabled
        }
    }

    /// Enable launch at login
    /// - Returns: true if successful, false if failed or not in Applications directory
    @discardableResult
    func enable() -> Bool {
        switch state {
        case .enabled, .disabled:
            break
        case .unavailable, .error:
            return false
        }

        do {
            try service.register()
            objectWillChange.send()
            updateState()
            return true
        } catch {
            objectWillChange.send()
            state = .error(type: .registrationFailed)
            return false
        }
    }

    /// Disable launch at login
    /// - Returns: true if successful
    @discardableResult
    func disable() -> Bool {
        switch state {
        case .enabled, .disabled:
            break
        case .unavailable, .error:
            return false
        }

        do {
            try service.unregister()
            objectWillChange.send()
            updateState()
            return true
        } catch {
            objectWillChange.send()
            state = .error(type: .unregistrationFailed)
            return false
        }
    }

    /// Set the launch at login state
    /// - Parameter enabled: whether to enable or disable
    /// - Returns: true if the operation succeeded
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            return enable()
        } else {
            return disable()
        }
    }

    /// Sets an error state indicating launch at login was disabled due to location
    /// This is used when the app is moved out of the Applications directory
    func setDisabledDueToLocationError() {
        state = .error(type: .disabledDueToLocation)
    }
}

