#if ENABLE_ICLOUD_SYNC

    import ClipKittyCloudSync
    import ClipKittyCore
    import SwiftUI

    struct SyncSettingsSection: View {
        @Environment(iOSSettingsStore.self) private var settings
        /// Optional on purpose: the coordinator leaves the environment while
        /// the app suspends but the last session's tree keeps rendering (see
        /// RootView.syncCoordinator). Falls back to `.idle` below.
        @Environment(iOSSyncCoordinator.self) private var syncCoordinator: iOSSyncCoordinator?

        /// Tracks the last known sync date so we can suppress brief "Syncing" flashes.
        @State private var lastSyncDate: Date?

        /// Threshold below which a new "syncing" state is suppressed in favor of
        /// continuing to show the "synced" label.
        private static let syncingSuppressionInterval: TimeInterval = 10

        var body: some View {
            @Bindable var settings = settings

            SettingsSyncSection(
                syncEnabled: $settings.syncEnabled,
                availability: syncAvailability,
                onSyncEnabledChange: { enabled in
                    syncCoordinator?.setSyncEnabled(enabled)
                }
            )
            .onChange(of: syncCoordinator?.status) { _, newStatus in
                if case let .synced(date) = newStatus {
                    lastSyncDate = date
                }
            }
        }

        private var syncAvailability: SettingsSyncPreferenceAvailability {
            switch displayStatus {
            case .idle:
                return .available(status: .idle)
            case .connecting:
                return .available(status: .connecting)
            case let .syncing(activity):
                return .available(
                    status: .syncing(activityDescription: activity.statusDescription)
                )
            case let .synced(lastSync):
                return .available(status: .synced(lastSync: lastSync))
            case let .error(message):
                return .available(status: .failed(message: message))
            case .temporarilyUnavailable:
                return .available(status: .temporarilyUnavailable)
            case .unavailable:
                return .available(
                    status: .unavailable(
                        message: String(
                            localized: "Make sure you're signed into iCloud in Settings."
                        )
                    )
                )
            }
        }

        /// Returns the status to display, suppressing brief `.syncing` flashes when
        /// we synced very recently.
        private var displayStatus: SyncEngine.SyncStatus {
            let actual = syncCoordinator?.status ?? .idle
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
