import ClipKittyShared
import SwiftUI

struct HistorySettingsSection: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var appState

    @State private var usedBytes: Int64 = 0
    @State private var committedLimitGB: Double?
    @State private var showShrinkConfirmation = false
    @State private var historyAction: HistoryAction = .idle

    enum HistoryAction {
        case idle
        case confirmingClear
        case clearing
        case failed(String)
    }

    var body: some View {
        @Bindable var settings = container.settings
        Section("History") {
            VStack(spacing: 10) {
                StorageBarView(
                    limitGB: $settings.maxDatabaseSizeGB,
                    usedBytes: usedBytes,
                    onEditingEnded: handleStorageLimitEdit
                )

                Text("Drag the handle to set how much space history can use. When it fills, the oldest items are overwritten.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
            .alert("Reduce Storage Limit?", isPresented: $showShrinkConfirmation) {
                Button("Remove Oldest Items", role: .destructive) {
                    committedLimitGB = settings.maxDatabaseSizeGB
                    Task { await pruneToLimit() }
                }
                Button("Cancel", role: .cancel) {
                    if let committed = committedLimitGB {
                        settings.maxDatabaseSizeGB = committed
                    }
                }
            } message: {
                Text("History already uses more space than the new limit. The oldest items will be removed to fit.")
            }

            switch historyAction {
            case .idle:
                Button("Clear History", role: .destructive) {
                    historyAction = .confirmingClear
                }
            case .confirmingClear:
                Button("Tap Again to Confirm", role: .destructive) {
                    Task { await clearHistory() }
                }
            case .clearing:
                HStack {
                    Text("Clearing...")
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            case let .failed(message):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Clear failed")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry", role: .destructive) {
                        Task { await clearHistory() }
                    }
                }
            }
        }
        .task {
            committedLimitGB = container.settings.maxDatabaseSizeGB
            await loadDatabaseSize()
        }
    }

    /// Called when the user releases the dial knob. Shrinking the limit below
    /// the space already used deletes the oldest items, so confirm first;
    /// otherwise just remember the new value as the committed one.
    private func handleStorageLimitEdit() {
        if usedBytes > Utilities.bytes(fromGB: container.settings.maxDatabaseSizeGB) {
            showShrinkConfirmation = true
        } else {
            committedLimitGB = container.settings.maxDatabaseSizeGB
        }
    }

    private func pruneToLimit() async {
        await container.pruneToStorageLimit()
        appState.refreshFeed()
        await loadDatabaseSize()
    }

    private func loadDatabaseSize() async {
        if case let .success(bytes) = await container.repository.databaseSize() {
            usedBytes = bytes
        }
    }

    private func clearHistory() async {
        historyAction = .clearing
        let result = await container.storeClient.clear()
        switch result {
        case .success:
            historyAction = .idle
            appState.refreshFeed()
            await loadDatabaseSize()
        case let .failure(error):
            historyAction = .failed(error.localizedDescription)
        }
    }
}
