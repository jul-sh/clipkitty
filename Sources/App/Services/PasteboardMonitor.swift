import AppKit
import Combine
import Foundation

// MARK: - Pasteboard Change

struct PasteboardChange: Sendable {
    let changeCount: Int
    let types: [NSPasteboard.PasteboardType]
}

// MARK: - Pasteboard Monitor Delegate

protocol PasteboardMonitorDelegate: AnyObject, Sendable {
    func pasteboardDidChange(_ change: PasteboardChange) async
}

// MARK: - Pasteboard Monitor

/// Monitors the system pasteboard for changes.
/// Handles adaptive polling, sleep/wake, and change count tracking.
final class PasteboardMonitor: @unchecked Sendable {
    private let pasteboard: NSPasteboard
    private var lastChangeCount: Int
    private var pollTask: Task<Void, Never>?
    private var isActive = false

    private let baseInterval: TimeInterval = 0.5
    private let maxInterval: TimeInterval = 2.0
    private var currentInterval: TimeInterval

    weak var delegate: PasteboardMonitorDelegate?

    // Bundle IDs to ignore clipboard changes from
    var ignoredBundleIds: Set<String> = []

    // Transient types that should be ignored
    private let transientTypes: Set<String> = [
        "org.nspasteboard.TransientType",
        "org.nspasteboard.ConcealedType",
        "com.agilebits.onepassword"
    ]

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
        self.currentInterval = baseInterval
    }

    deinit {
        stop()
    }

    // MARK: - Control

    func start() {
        guard !isActive else { return }
        isActive = true
        lastChangeCount = pasteboard.changeCount
        startPolling()
        setupNotifications()
    }

    func stop() {
        isActive = false
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, self.isActive else { break }

                let currentCount = self.pasteboard.changeCount
                if currentCount != self.lastChangeCount {
                    self.lastChangeCount = currentCount

                    // Reset to fast polling on change
                    self.currentInterval = self.baseInterval

                    // Check for transient/ignored content
                    if !self.shouldIgnoreCurrentContent() {
                        let types = self.pasteboard.types ?? []
                        let change = PasteboardChange(changeCount: currentCount, types: types)
                        await self.delegate?.pasteboardDidChange(change)
                    }
                } else {
                    // Gradually slow down polling when idle
                    self.currentInterval = min(self.currentInterval * 1.2, self.maxInterval)
                }

                try? await Task.sleep(for: .milliseconds(Int(self.currentInterval * 1000)))
            }
        }
    }

    private func shouldIgnoreCurrentContent() -> Bool {
        guard let types = pasteboard.types else { return true }

        // Check for transient types
        for type in types {
            if transientTypes.contains(type.rawValue) {
                return true
            }
        }

        return false
    }

    // MARK: - Sleep/Wake

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
    }

    @objc private func handleWake() {
        guard isActive else { return }
        // Reset change count to detect changes that happened during sleep
        lastChangeCount = pasteboard.changeCount
        currentInterval = baseInterval
        startPolling()
    }

    @objc private func handleSleep() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Ignore Management

    func addIgnoredBundleId(_ bundleId: String) {
        ignoredBundleIds.insert(bundleId)
    }

    func removeIgnoredBundleId(_ bundleId: String) {
        ignoredBundleIds.remove(bundleId)
    }

    func temporarilyIgnoreNextChange() {
        // Bump change count to ignore the next change we cause ourselves
        lastChangeCount = pasteboard.changeCount + 1
    }
}
