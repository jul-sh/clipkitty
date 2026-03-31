import ApplicationServices
import Foundation

/// Monitors accessibility permission state and notifies when it changes.
/// Polls at regular intervals since macOS doesn't provide permission change notifications.
@MainActor
@Observable
public final class AccessibilityPermissionMonitor {
    /// Current permission state
    public private(set) var isGranted: Bool

    /// Whether the monitor is actively polling
    public private(set) var isMonitoring: Bool = false

    private var pollingTask: Task<Void, Never>?

    /// Polling interval when waiting for permission
    private let pollingIntervalMs: Int = 500

    public init() {
        isGranted = AXIsProcessTrusted()
    }

    /// Start monitoring for permission changes.
    /// Polling continues until permission is granted or `stop()` is called.
    public func start() {
        guard !isMonitoring else { return }

        // Check current state first
        isGranted = AXIsProcessTrusted()

        // If already granted, no need to poll
        guard !isGranted else { return }

        isMonitoring = true

        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                // AXIsProcessTrusted() checks the current state without caching
                let granted = AXIsProcessTrusted()
                if granted != self.isGranted {
                    self.isGranted = granted

                    // Stop polling once permission is granted
                    if granted {
                        self.stop()
                        return
                    }
                }

                try? await Task.sleep(for: .milliseconds(self.pollingIntervalMs))
            }
        }
    }

    /// Stop monitoring for permission changes.
    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        isMonitoring = false
    }

    /// Request accessibility permission.
    /// This triggers the system prompt to add the app to accessibility permissions.
    @discardableResult
    public func requestPermission() -> Bool {
        // Using AXIsProcessTrustedWithOptions with prompt option triggers the system dialog
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let result = AXIsProcessTrustedWithOptions(options)
        // Update state immediately after request
        isGranted = AXIsProcessTrusted()
        return result
    }

    /// Refresh the current permission state without affecting monitoring.
    public func refresh() {
        isGranted = AXIsProcessTrusted()
    }
}
