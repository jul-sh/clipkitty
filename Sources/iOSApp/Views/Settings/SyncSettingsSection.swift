#if ENABLE_SYNC

    import ClipKittyAppleServices
    import SwiftUI

    struct SyncSettingsSection: View {
        @Environment(iOSSettingsStore.self) private var settings
        @Environment(iOSSyncCoordinator.self) private var syncCoordinator

        var body: some View {
            @Bindable var settings = settings

            Section("iCloud Sync") {
                Toggle("Sync via iCloud", isOn: $settings.syncEnabled)
                    .onChange(of: settings.syncEnabled) { _, enabled in
                        syncCoordinator.setSyncEnabled(enabled)
                    }

                statusRow
            }
        }

        @ViewBuilder
        private var statusRow: some View {
            switch syncCoordinator.status {
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
                    Text("Synced \(lastSync, style: .relative) ago")
                        .foregroundStyle(.secondary)
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
    }

#endif
