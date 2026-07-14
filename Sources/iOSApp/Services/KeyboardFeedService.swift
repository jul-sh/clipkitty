import ClipKittyShared
import Foundation
import os

/// Keeps the keyboard extension's snapshot (`KeyboardFeedStore`) in step with
/// clipboard history.
///
/// Snapshot generation uses a bounded SQLite read rather than a search. That
/// distinction is essential: the Rust store has one interactive search slot,
/// and synchronization work must never cancel a user's query. Change bursts
/// are coalesced, while suspension forces a final pass before store release.
@MainActor
final class KeyboardFeedService {
    private nonisolated static let logger = Logger(subsystem: "com.clipkitty", category: "KeyboardFeed")

    private let writer: KeyboardFeedSnapshotWriter
    private enum PendingRefresh {
        case none
        case debouncing(Task<Void, Never>)
    }

    private var pendingRefresh: PendingRefresh = .none
    private var requestedGeneration: UInt64 = 0

    /// Coalesces change bursts (a sync batch reports one change per item).
    private static let debounceInterval: Duration = .milliseconds(150)

    init(repository: ClipboardRepository, baseDirectory: URL? = nil) {
        writer = KeyboardFeedSnapshotWriter(
            repository: repository,
            baseDirectory: baseDirectory
        )
    }

    /// Called whenever persisted feed content may have changed.
    func scheduleRefresh() {
        requestedGeneration &+= 1
        let generation = requestedGeneration
        cancelPendingRefresh()

        let task = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled, let self else { return }
            guard generation == self.requestedGeneration else { return }
            self.pendingRefresh = .none
            await self.refresh(generation: generation)
        }
        pendingRefresh = .debouncing(task)
    }

    /// Called while the app prepares for suspension, before the store is
    /// released. This is the moment the snapshot has to be right: the user is
    /// leaving for another app, where the keyboard may come up next.
    func refreshOnSuspension() async {
        requestedGeneration &+= 1
        let generation = requestedGeneration
        cancelPendingRefresh()
        await refresh(generation: generation)
    }

    private func refresh(generation: UInt64) async {
        let loadOutcome = await writer.prepareCurrentSnapshot()
        guard generation == requestedGeneration else { return }

        let candidate: KeyboardFeedSnapshotWriter.Candidate
        switch loadOutcome {
        case let .success(current):
            candidate = current
        case let .failure(error):
            Self.logger.error("Keyboard feed refresh failed: \(error.localizedDescription)")
            return
        }

        if case let .failure(error) = writer.write(candidate) {
            Self.logger.error("Keyboard feed refresh failed: \(error.localizedDescription)")
        }
    }

    private func cancelPendingRefresh() {
        switch pendingRefresh {
        case .none:
            break
        case let .debouncing(task):
            task.cancel()
            pendingRefresh = .none
        }
    }
}
