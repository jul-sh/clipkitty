#if ENABLE_ICLOUD_SYNC

    import ClipKittyAppleServices
    import SwiftUI

    struct SyncSettingsSection: View {
        @Environment(iOSSettingsStore.self) private var settings
        @Environment(iOSSyncCoordinator.self) private var syncCoordinator

        /// Tracks the last known sync date so we can suppress brief "Syncing" flashes.
        @State private var lastSyncDate: Date?

        /// Threshold below which a new "syncing" state is suppressed in favor of
        /// continuing to show the "synced" label.
        private static let syncingSuppressionInterval: TimeInterval = 10

        var body: some View {
            @Bindable var settings = settings

            Section("iCloud Sync") {
                Toggle("Sync via iCloud", isOn: $settings.syncEnabled)
                    .onChange(of: settings.syncEnabled) { _, enabled in
                        syncCoordinator.setSyncEnabled(enabled)
                    }

                statusRow
            }
            .onChange(of: syncCoordinator.status) { _, newStatus in
                if case let .synced(date) = newStatus {
                    lastSyncDate = date
                }
            }
        }

        @ViewBuilder
        private var statusRow: some View {
            switch displayStatus {
            case .idle:
                LabeledContent("Status", value: "Off")
            case .connecting:
                HStack {
                    Text("Status")
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting")
                        .foregroundStyle(.secondary)
                }
            case .syncing:
                HStack {
                    Text("Status")
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Syncing")
                        .foregroundStyle(.secondary)
                }
            case let .synced(lastSync):
                LabeledContent("Status") {
                    if -lastSync.timeIntervalSinceNow < 60 {
                        Text("Synced just now")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Synced \(lastSync, style: .relative) ago")
                            .foregroundStyle(.secondary)
                    }
                }
            case let .error(message):
                LabeledContent("Status") {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            case .temporarilyUnavailable:
                LabeledContent("Status", value: "Temporarily unavailable")
            case .unavailable:
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Status", value: "Unavailable")
                    Text("Make sure you're signed into iCloud in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        /// Returns the status to display, suppressing brief `.syncing` flashes when
        /// we synced very recently.
        private var displayStatus: SyncEngine.SyncStatus {
            let actual = syncCoordinator.status
            if case .syncing = actual,
               let last = lastSyncDate,
               -last.timeIntervalSinceNow < Self.syncingSuppressionInterval
            {
                return .synced(lastSync: last)
            }
            return actual
        }
    }

#endif
