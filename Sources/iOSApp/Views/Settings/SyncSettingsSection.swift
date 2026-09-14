#if ENABLE_ICLOUD_SYNC

    import SwiftUI

    struct SyncSettingsRow: View {
        @Environment(iOSSettingsStore.self) private var settings
        /// Optional on purpose: the coordinator leaves the environment while
        /// the app suspends but the last session's tree keeps rendering (see
        /// RootView.syncCoordinator).
        @Environment(iOSSyncCoordinator.self) private var syncCoordinator: iOSSyncCoordinator?

        var body: some View {
            @Bindable var settings = settings

            Toggle(String(localized: "Sync via iCloud"), isOn: $settings.syncEnabled)
                .onChange(of: settings.syncEnabled) { _, enabled in
                    syncCoordinator?.setSyncEnabled(enabled)
                }

            // The toolbar button hides itself while sync is healthy or idle, so
            // this row is the one place a user can see what sync is doing and
            // why it might be stuck.
            if settings.syncEnabled {
                let presentation = iOSSyncStatusPresentation(
                    syncEnabled: settings.syncEnabled,
                    status: syncCoordinator?.status
                )
                HStack {
                    Text(presentation.accessibilityValue())
                        .font(.caption)
                        .foregroundStyle(presentation.isFailure ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let syncCoordinator, syncCoordinator.canRequestSync {
                        Button(String(localized: "Sync now")) {
                            syncCoordinator.requestSync()
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("settings.syncNow")
                    }
                }
                .accessibilityIdentifier("settings.syncStatus")
            }
        }
    }

#endif
