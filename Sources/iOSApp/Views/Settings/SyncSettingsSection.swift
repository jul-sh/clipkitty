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

            // Sync runs on its own; a healthy or in-flight status is not
            // something the user can act on. Only a failure earns a line, and
            // it explains rather than offers a button.
            if settings.syncEnabled {
                let presentation = iOSSyncStatusPresentation(
                    syncEnabled: settings.syncEnabled,
                    status: syncCoordinator?.status
                )
                if presentation.isVisible {
                    Text(presentation.accessibilityValue())
                        .font(.caption)
                        .foregroundStyle(presentation.isFailure ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.syncStatus")
                }
            }
        }
    }

#endif
