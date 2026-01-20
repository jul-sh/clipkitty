import Foundation
import ServiceManagement

/// Manages the app's launch-at-login registration using SMAppService.
///
/// Key behaviors:
/// - Only allows registration when the app is in /Applications or ~/Applications
/// - Uses the app's bundle identifier to ensure only one registration exists
/// - Silent operation - no terminal windows or user prompts
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    /// Whether the app is currently registered to launch at login
    @Published private(set) var isEnabled: Bool = false

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

        // Read initial state
        isEnabled = service.status == .enabled
    }

    /// Enable launch at login
    /// - Returns: true if successful, false if failed or not in Applications directory
    @discardableResult
    func enable() -> Bool {
        guard isInApplicationsDirectory else {
            logWarning("Cannot enable launch at login: app is not in Applications directory")
            return false
        }

        do {
            try service.register()
            isEnabled = true
            logInfo("Launch at login enabled")
            return true
        } catch {
            logError("Failed to enable launch at login: \(error.localizedDescription)")
            return false
        }
    }

    /// Disable launch at login
    /// - Returns: true if successful
    @discardableResult
    func disable() -> Bool {
        do {
            try service.unregister()
            isEnabled = false
            logInfo("Launch at login disabled")
            return true
        } catch {
            logError("Failed to disable launch at login: \(error.localizedDescription)")
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

    /// Refresh the enabled state from the system
    func refresh() {
        isEnabled = service.status == .enabled
    }
}
