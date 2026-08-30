import Foundation
import UIKit

enum iOSPasteboardIngestAttemptResult {
    /// The generation was saved, deliberately ignored, or became obsolete.
    case handled
    /// The generation is still pending (for example, paste access or the store
    /// was temporarily unavailable). Retry on a later signal or after backoff.
    case retry
}

enum iOSPasteboardMonitorStopWork {
    case quiescent
    case awaiting(Task<Void, Never>)
}

/// Session-owned monitoring for the iOS general pasteboard.
///
/// UIKit updates `changeCount` at the end of the event loop when an app becomes
/// active. A one-shot scene-phase callback can therefore observe the previous
/// generation and miss the change until the next activation. This monitor
/// combines the canonical pasteboard notification with an immediate check, a
/// delayed activation check, and change-count-only polling while the scene is
/// foreground-visible (including `.inactive`). Reads remain behind the existing
/// Auto-Add opt-in.
///
/// Only one ingest attempt can run at a time. Signals received during an attempt
/// are coalesced, and a newer generation is checked before the worker exits.
@MainActor
final class iOSPasteboardMonitor {
    typealias Ingest = @MainActor (Int) async -> iOSPasteboardIngestAttemptResult

    private let isEnabled: @MainActor () -> Bool
    private let changeCount: @MainActor () -> Int
    private let acknowledgedChangeCount: @MainActor () -> Int
    private let ingest: Ingest
    private let notificationCenter: NotificationCenter?
    private let pasteboard: UIPasteboard?
    private let waitForActivationRetry: @MainActor () async -> Void
    private let pollingInterval: Duration
    private let retryPollCount: Int
    private let maximumAutomaticRetryCount: Int

    private var isMonitoring = false
    private var isStopped = false
    private var pendingCheck = false
    private var pendingForce = false
    private var lastAttemptedGeneration: Int?
    private var retryGeneration: Int?
    private var retryPollsRemaining = 0
    private var automaticRetriesRemaining = 0
    private var pollingTask: Task<Void, Never>?
    private var ingestTask: Task<Void, Never>?
    private var pasteboardObserver: NSObjectProtocol?

    init(
        isEnabled: @escaping @MainActor () -> Bool,
        changeCount: @escaping @MainActor () -> Int,
        acknowledgedChangeCount: @escaping @MainActor () -> Int,
        notificationCenter: NotificationCenter? = .default,
        pasteboard: UIPasteboard? = .general,
        activationRetryDelay: Duration = .milliseconds(100),
        waitForActivationRetry: (@MainActor () async -> Void)? = nil,
        pollingInterval: Duration = .milliseconds(350),
        retryPollCount: Int = 8,
        maximumAutomaticRetryCount: Int = 2,
        ingest: @escaping Ingest
    ) {
        self.isEnabled = isEnabled
        self.changeCount = changeCount
        self.acknowledgedChangeCount = acknowledgedChangeCount
        self.notificationCenter = notificationCenter
        self.pasteboard = pasteboard
        self.waitForActivationRetry = waitForActivationRetry ?? {
            try? await Task.sleep(for: activationRetryDelay)
        }
        self.pollingInterval = pollingInterval
        self.retryPollCount = max(0, retryPollCount)
        self.maximumAutomaticRetryCount = max(0, maximumAutomaticRetryCount)
        self.ingest = ingest
    }

    /// Begins foreground-visible monitoring or schedules another activation
    /// retry. iPad Slide Over commonly leaves ClipKitty `.inactive` while the
    /// other app owns input, so monitoring deliberately continues until stop.
    func sceneBecameActive() {
        guard !isStopped else { return }
        isMonitoring = true
        retryGeneration = nil
        retryPollsRemaining = 0
        automaticRetriesRemaining = 0
        installPasteboardObserverIfNeeded()
        startPolling()
        requestCheck(force: true)
    }

    /// Permanently stops this session's monitor and returns any in-flight ingest
    /// so suspension can join it before draining the store.
    func stop() -> iOSPasteboardMonitorStopWork {
        guard !isStopped else {
            if let ingestTask { return .awaiting(ingestTask) }
            return .quiescent
        }

        isStopped = true
        isMonitoring = false
        pendingCheck = false
        pendingForce = false
        pollingTask?.cancel()
        pollingTask = nil
        if let pasteboardObserver {
            notificationCenter?.removeObserver(pasteboardObserver)
            self.pasteboardObserver = nil
        }

        // Cancellation prevents another coalesced attempt. The current store
        // operation, if already admitted, is still awaited by the returned task.
        ingestTask?.cancel()
        if let ingestTask { return .awaiting(ingestTask) }
        return .quiescent
    }

    /// Internal entry point used by the notification adapter and focused tests.
    func pasteboardDidChange() {
        requestCheck(force: true)
    }

    private func installPasteboardObserverIfNeeded() {
        guard pasteboardObserver == nil,
              let notificationCenter,
              let pasteboard
        else { return }

        pasteboardObserver = notificationCenter.addObserver(
            forName: UIPasteboard.changedNotification,
            object: pasteboard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pasteboardDidChange()
            }
        }
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Cross-app `changeCount` updates are deferred until the activation
            // event loop finishes. This check closes that deterministic race.
            await self.waitForActivationRetry()
            guard !Task.isCancelled, self.isMonitoring, !self.isStopped else { return }
            self.requestCheck(force: true)

            while !Task.isCancelled, self.isMonitoring, !self.isStopped {
                try? await Task.sleep(for: self.pollingInterval)
                guard !Task.isCancelled, self.isMonitoring, !self.isStopped else { return }
                self.requestCheck(force: false)
            }
        }
    }

    private func requestCheck(force: Bool) {
        guard isMonitoring, !isStopped else { return }

        guard isEnabled() else {
            pendingCheck = false
            pendingForce = false
            lastAttemptedGeneration = nil
            retryGeneration = nil
            retryPollsRemaining = 0
            automaticRetriesRemaining = 0
            ingestTask?.cancel()
            return
        }

        pendingCheck = true
        pendingForce = pendingForce || force
        guard ingestTask == nil else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainChecks()
        }
        ingestTask = task
    }

    private func drainChecks() async {
        defer {
            ingestTask = nil
            if pendingCheck, isMonitoring, !isStopped, isEnabled() {
                requestCheck(force: pendingForce)
            }
        }

        while pendingCheck, isMonitoring, !isStopped, !Task.isCancelled {
            let force = pendingForce
            pendingCheck = false
            pendingForce = false

            guard isEnabled() else { return }
            let generation = changeCount()
            guard generation != acknowledgedChangeCount() else {
                lastAttemptedGeneration = nil
                retryGeneration = nil
                retryPollsRemaining = 0
                automaticRetriesRemaining = 0
                continue
            }

            if force {
                // A lifecycle activation or real pasteboard notification is a
                // fresh opportunity even after this generation exhausted its
                // background retry budget.
                retryGeneration = generation
                retryPollsRemaining = 0
                automaticRetriesRemaining = maximumAutomaticRetryCount
            } else if generation == lastAttemptedGeneration {
                guard retryGeneration == generation,
                      automaticRetriesRemaining > 0
                else { continue }
                if retryPollsRemaining > 0 {
                    retryPollsRemaining -= 1
                    continue
                }
                automaticRetriesRemaining -= 1
            } else {
                retryGeneration = generation
                retryPollsRemaining = 0
                automaticRetriesRemaining = maximumAutomaticRetryCount
            }

            lastAttemptedGeneration = generation
            switch await ingest(generation) {
            case .handled:
                retryGeneration = nil
                retryPollsRemaining = 0
                automaticRetriesRemaining = 0
            case .retry:
                retryPollsRemaining = retryPollCount
            }

            // If the pasteboard changed while its snapshot was being saved, run
            // the latest generation without waiting for another timer tick.
            if changeCount() != generation, isMonitoring, !isStopped {
                pendingCheck = true
                pendingForce = true
            }
        }
    }
}
