import SwiftUI

struct iOSSettingsView: View {
    @EnvironmentObject private var store: iOSClipboardStore
    @State private var databaseSize: Int64 = 0
    @State private var showClearConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                syncSection
                storageSection
                aboutSection
            }
            .navigationTitle("Settings")
        }
        .task {
            databaseSize = await store.databaseSize()
        }
    }

    // MARK: - Sync Section

    @ViewBuilder
    private var syncSection: some View {
        Section {
            Toggle("iCloud Sync", isOn: $store.syncEnabled)

            #if ENABLE_SYNC
                HStack {
                    Text("Status")
                    Spacer()
                    syncStatusView
                }
            #endif
        } header: {
            Text("Sync")
        } footer: {
            Text(
                "When enabled, clipboard items copied on your Mac are synced to this device via iCloud."
            )
        }
    }

    #if ENABLE_SYNC
        @ViewBuilder
        private var syncStatusView: some View {
            switch store.syncStatus {
            case .idle:
                Label("Idle", systemImage: "circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

            case .syncing:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Syncing")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

            case let .synced(lastSync):
                Label(
                    "Synced \(lastSync, format: .relative(presentation: .named))",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.subheadline)
                .foregroundStyle(.green)

            case let .error(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .lineLimit(1)

            case .unavailable:
                Label("iCloud Unavailable", systemImage: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    #endif

    // MARK: - Storage Section

    @ViewBuilder
    private var storageSection: some View {
        Section("Storage") {
            LabeledContent("Database Size") {
                Text(FormattingHelpers.formatBytes(databaseSize))
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                showClearConfirmation = true
            } label: {
                Label("Clear All History", systemImage: "trash")
            }
            .confirmationDialog(
                "Clear all clipboard history?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear All", role: .destructive) {
                    Task {
                        _ = await store.clearAll()
                        databaseSize = await store.databaseSize()
                    }
                }
            } message: {
                Text(
                    "This will permanently delete all clipboard items on this device. Items on other devices will not be affected until the next sync."
                )
            }
        }
    }

    // MARK: - About Section

    @ViewBuilder
    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version") {
                Text(appVersion)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Build") {
                Text(buildNumber)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "Unknown"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

}
