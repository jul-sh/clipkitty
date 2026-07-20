import ClipKittyShared
import SwiftUI

struct AdvancedSettingsSection: View {
    var body: some View {
        Section {
            NavigationLink {
                AdvancedSettingsScreen()
            } label: {
                Label(String(localized: "Advanced"), systemImage: "gearshape.2")
            }
        }
    }
}

private struct AdvancedSettingsScreen: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var appState

    @State private var storageState = StorageState.loading
    @State private var historyAction = HistoryAction.idle

    private enum StorageState {
        case loading
        case ready(usedBytes: Int64, committedLimitGB: Double)
        case confirmingShrink(usedBytes: Int64, previousLimitGB: Double)
        case pruning(usedBytes: Int64, committedLimitGB: Double)
        case loadFailed(message: String)
    }

    private enum HistoryAction {
        case idle
        case confirmingClear
        case clearing
        case failed(String)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    var body: some View {
        @Bindable var settings = container.settings

        Form {
            Section(String(localized: "Storage Limit")) {
                switch storageState {
                case .loading:
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                case let .ready(usedBytes, _),
                     let .confirmingShrink(usedBytes, _):
                    storageControls(usedBytes: usedBytes, limitGB: $settings.maxDatabaseSizeGB)
                case .pruning:
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                case .loadFailed:
                    EmptyView()
                }

                if case let .loadFailed(message) = storageState {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button(String(localized: "Retry")) {
                            storageState = .loading
                            Task {
                                await loadDatabaseSize(
                                    committedLimitGB: settings.maxDatabaseSizeGB
                                )
                            }
                        }
                    }
                }
            }

            Section("History") {
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

            Section {
                Toggle(
                    String(localized: "Allow Shortcuts to Read History"),
                    isOn: $settings.allowShortcutsReadAccess
                )
            } header: {
                Text(String(localized: "Shortcuts"))
            } footer: {
                Text(String(localized: "When off, Shortcuts and automations cannot read or search your clipboard history; saving new clips from Shortcuts still works. Turn this off if you do not want automations to access your history."))
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: buildNumber)
            }
        }
        .navigationTitle(String(localized: "Advanced"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadDatabaseSize(committedLimitGB: settings.maxDatabaseSizeGB)
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
        guard case let .confirmingShrink(usedBytes, _) = storageState else { return }
        let committedLimitGB = container.settings.maxDatabaseSizeGB
        storageState = .pruning(
            usedBytes: usedBytes,
            committedLimitGB: committedLimitGB
        )
        Task {
            await container.pruneToStorageLimit()
            appState.refreshFeed()
            await loadDatabaseSize(committedLimitGB: committedLimitGB)
        }
    }

    private func loadDatabaseSize(committedLimitGB: Double) async {
        switch await container.repository.databaseSize() {
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
        let result = await container.storeClient.clear()
        switch result {
        case .success:
            historyAction = .idle
            appState.refreshFeed()
        case let .failure(error):
            historyAction = .failed(error.localizedDescription)
        }
    }
}
