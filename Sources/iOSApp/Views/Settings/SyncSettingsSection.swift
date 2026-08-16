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

            Toggle("Sync via iCloud", isOn: $settings.syncEnabled)
                .onChange(of: settings.syncEnabled) { _, enabled in
                    syncCoordinator?.setSyncEnabled(enabled)
                }
        }
    }

#endif
