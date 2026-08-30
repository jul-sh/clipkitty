import ClipKittyCore
import SwiftUI

struct StorageSettingsSection: View {
    var body: some View {
        NavigationLink {
            StorageSettingsScreen()
        } label: {
            Label(String(localized: "Storage"), systemImage: "externaldrive")
        }
        .accessibilityIdentifier("settings.storageLink")
    }
}

private struct StorageSettingsScreen: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var appState

    @State private var storageState = StorageState.loading
    @State private var historyAction = HistoryAction.idle

    private enum StorageState {
        case loading
        case ready(usedBytes: Int64, committedLimitGB: Double)
        case confirmingShrink(usedBytes: Int64, previousLimitGB: Double)
        case pruning
        case loadFailed(message: String)
    }

    private enum HistoryAction {
        case idle
        case confirmingClear
        case clearing
        case failed(String)
    }

    var body: some View {
        @Bindable var settings = container.settings

        Form {
            Section(String(localized: "Storage Limit")) {
                switch storageState {
                case .loading, .pruning:
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                case let .ready(usedBytes, _),
                     let .confirmingShrink(usedBytes, _):
                    storageControls(usedBytes: usedBytes, limitGB: $settings.maxDatabaseSizeGB)
                case let .loadFailed(message):
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button(String(localized: "Retry")) {
                            storageState = .loading
                            startForegroundTask {
                                await loadDatabaseSize(
                                    committedLimitGB: settings.maxDatabaseSizeGB
                                )
                            }
                        }
                    }
                }
            }

            Section(String(localized: "History")) {
                switch historyAction {
                case .idle:
                    Button("Clear History", role: .destructive) {
                        historyAction = .confirmingClear
                    }
                case .confirmingClear:
                    Button("Tap Again to Confirm", role: .destructive) {
                        startForegroundTask {
                            await clearHistory()
                        }
                    }
                case .clearing:
                    HStack {
                        Text(String(localized: "Clearing..."))
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                    }
                case let .failed(message):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Clear failed"))
                            .foregroundStyle(.red)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Retry", role: .destructive) {
                            startForegroundTask {
                                await clearHistory()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Storage"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !Task.isCancelled else { return }
            let task = startForegroundTask {
                await loadDatabaseSize(committedLimitGB: settings.maxDatabaseSizeGB)
            }
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
        .alert(
            String(localized: "Reduce Storage Limit?"),
            isPresented: shrinkConfirmationBinding
        ) {
            Button(String(localized: "Remove Oldest Items"), role: .destructive) {
                startPruning()
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                restorePreviousLimit()
            }
        } message: {
            Text(String(localized: "History already uses more space than the new limit. The oldest items will be removed to fit."))
        }
    }

    private func storageControls(usedBytes: Int64, limitGB: Binding<Double>) -> some View {
        VStack(spacing: 10) {
            StorageBarView(
                limitGB: limitGB,
                usedBytes: usedBytes,
                onEditingEnded: handleStorageLimitEdit
            )

            Text(String(localized: "Drag the handle to set how much space history can use. When it fills, the oldest items are overwritten."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }

    private var shrinkConfirmationBinding: Binding<Bool> {
        Binding(
            get: {
                if case .confirmingShrink = storageState { return true }
                return false
            },
            set: { presented in
                guard !presented else { return }
                restorePreviousLimit()
            }
        )
    }

    private func handleStorageLimitEdit() {
        switch storageState {
        case let .ready(usedBytes, committedLimitGB):
            if usedBytes > Utilities.bytes(fromGB: container.settings.maxDatabaseSizeGB) {
                storageState = .confirmingShrink(
                    usedBytes: usedBytes,
                    previousLimitGB: committedLimitGB
                )
            } else {
                storageState = .ready(
                    usedBytes: usedBytes,
                    committedLimitGB: container.settings.maxDatabaseSizeGB
                )
            }
        case .loading, .confirmingShrink, .pruning, .loadFailed:
            break
        }
    }

    private func restorePreviousLimit() {
        guard case let .confirmingShrink(usedBytes, previousLimitGB) = storageState else {
            return
        }
        container.settings.maxDatabaseSizeGB = previousLimitGB
        storageState = .ready(usedBytes: usedBytes, committedLimitGB: previousLimitGB)
    }

    private func startPruning() {
        guard case .confirmingShrink = storageState else { return }
        let committedLimitGB = container.settings.maxDatabaseSizeGB
        storageState = .pruning
        startForegroundTask {
            await container.pruneToStorageLimit()
            // The prune may have committed even if terminal suspension
            // cancelled this UI task while its store call was in flight.
            // Preserve an authoritative invalidation for the next session,
            // then suppress writes to this outgoing screen's local state.
            appState.refreshFeed()
            guard !Task.isCancelled else { return }
            await loadDatabaseSize(committedLimitGB: committedLimitGB)
        }
    }

    /// Store-backed settings work belongs to the current foreground session.
    /// AppState cancels and joins the exact task before sealing that session's
    /// store, while the task's defer removes completed work from the registry.
    @discardableResult
    private func startForegroundTask(
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let taskID = UUID()
        let task = Task { @MainActor in
            defer { appState.finishForegroundTask(id: taskID) }
            guard !Task.isCancelled else { return }
            await operation()
        }
        _ = appState.registerForegroundTask(id: taskID, task: task)
        return task
    }

    private func loadDatabaseSize(committedLimitGB: Double) async {
        let result = await container.repository.databaseSize()
        guard !Task.isCancelled else { return }

        switch result {
        case let .success(usedBytes):
            storageState = .ready(
                usedBytes: usedBytes,
                committedLimitGB: committedLimitGB
            )
        case let .failure(error):
            storageState = .loadFailed(message: error.localizedDescription)
        }
    }

    private func clearHistory() async {
        historyAction = .clearing
        guard !Task.isCancelled else { return }
        let result = await container.storeClient.clear()

        // Store calls are not transactional with Swift task cancellation. A
        // successful clear remains committed, so invalidate the feed even if
        // the current screen/session is already being torn down.
        if case .success = result {
            appState.refreshFeed()
        }
        guard !Task.isCancelled else { return }

        switch result {
        case .success:
            historyAction = .idle
        case let .failure(error):
            historyAction = .failed(error.localizedDescription)
        }
    }
}
