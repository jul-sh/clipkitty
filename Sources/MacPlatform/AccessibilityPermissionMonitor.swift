import ApplicationServices
import CoreGraphics
import Foundation

/// The system's effective authorization for synthetic keyboard events.
public enum AccessibilityPermissionStatus: Equatable, Sendable {
    /// Accessibility has not been granted in System Settings.
    case notGranted

    /// Both the Accessibility trust check and event-posting preflight succeed.
    case granted

    /// macOS reports Accessibility trust, but disagrees about whether this
    /// process may synthesize events. The stale entry must be removed and re-added.
    case requiresRepair
}

struct AccessibilityPermissionClient {
    var isAccessibilityTrusted: @MainActor @Sendable () -> Bool
    var canPostEvents: @MainActor @Sendable () -> Bool
    var requestPostEventAccess: @MainActor @Sendable () -> Bool

    static let live = AccessibilityPermissionClient(
        isAccessibilityTrusted: { AXIsProcessTrusted() },
        canPostEvents: { CGPreflightPostEventAccess() },
        requestPostEventAccess: { CGRequestPostEventAccess() }
    )
}

/// Monitors effective synthetic-event permission and notifies when it changes.
/// Polls while observed since macOS doesn't provide permission change notifications.
@MainActor
@Observable
public final class AccessibilityPermissionMonitor {
    /// Current effective permission state.
    public private(set) var status: AccessibilityPermissionStatus

    private var pollingTask: Task<Void, Never>?
    private let client: AccessibilityPermissionClient

    /// Views currently asking for polling. Several permission-aware views can
    /// be on screen at once (Welcome plus Settings during onboarding); the
    /// first one to disappear must not silence the rest.
    private var observerCount = 0

    /// Polling interval while a permission-related view is visible.
    private let pollingIntervalMs: Int = 500

    public convenience init() {
        self.init(client: .live)
    }

    init(client: AccessibilityPermissionClient) {
        self.client = client
        status = Self.currentStatus(using: client)
    }

    /// Start monitoring for permission changes. Balanced by `stop()`; polling
    /// runs while at least one caller is observing, so revocation and stale
    /// grants are reflected while a permission view is open.
    public func start() {
        observerCount += 1
        guard pollingTask == nil else { return }

        refresh()

        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                try? await Task.sleep(for: .milliseconds(self.pollingIntervalMs))
            }
        }
    }

    /// Stop monitoring for permission changes. Polling ends once every
    /// `start()` has been matched by a `stop()`.
    public func stop() {
        observerCount = max(0, observerCount - 1)
        guard observerCount == 0 else { return }
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Whether polling is active. Exposed for tests.
    public var isPolling: Bool {
        pollingTask != nil
    }

    /// Request accessibility permission.
    /// This triggers the system prompt to add the app to accessibility permissions.
    @discardableResult
    public func requestPermission() -> Bool {
        let result = client.requestPostEventAccess()
        refresh()
        return result
    }

    /// Refresh the current permission state without affecting monitoring.
    public func refresh() {
        status = Self.currentStatus(using: client)
    }

    private static func currentStatus(using client: AccessibilityPermissionClient) -> AccessibilityPermissionStatus {
        switch (client.isAccessibilityTrusted(), client.canPostEvents()) {
        case (true, true):
            return .granted
        case (false, false):
            return .notGranted
        case (true, false), (false, true):
            return .requiresRepair
        }
    }
}
