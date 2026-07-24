import SwiftUI

/// The status shown while the iCloud preference remains configurable.
public enum SettingsSyncStatus: Equatable, Sendable {
    case idle
    case connecting
    case syncing(activityDescription: String)
    case synced(lastSync: Date)
    case temporarilyUnavailable
    case unavailable(message: String)
    case failed(message: String)
}

/// Whether the iCloud preference can currently be changed.
///
/// A display status is associated only with the available case, so callers
/// cannot accidentally present a normal sync state while the preference is
/// still being checked or is unavailable in the current build.
public enum SettingsSyncPreferenceAvailability: Equatable, Sendable {
    case checking
    case available(status: SettingsSyncStatus)
    case unavailable(message: String)
}

/// The shared iCloud Sync section used by both Apple apps. Platform adapters
/// translate their service state into the presentation enums and provide only
/// the side effect that should run when the preference changes.
public struct SettingsSyncSection: View {
    @Binding private var syncEnabled: Bool
    private let availability: SettingsSyncPreferenceAvailability
    private let onSyncEnabledChange: (Bool) -> Void

    public init(
        syncEnabled: Binding<Bool>,
        availability: SettingsSyncPreferenceAvailability,
        onSyncEnabledChange: @escaping (Bool) -> Void = { _ in }
    ) {
        _syncEnabled = syncEnabled
        self.availability = availability
        self.onSyncEnabledChange = onSyncEnabledChange
    }

    public var body: some View {
        Section(String(localized: "iCloud Sync")) {
            switch availability {
            case .checking, .unavailable:
                syncToggle
                    .disabled(true)
            case .available:
                syncToggle
            }

            switch availability {
            case .checking:
                SettingsSyncProgressStatus(
                    value: String(localized: "Checking")
                )
            case let .available(status):
                SettingsSyncStatusRow(
                    status: status,
                    syncEnabled: syncEnabled
                )
            case let .unavailable(message):
                SettingsSyncUnavailableStatus(message: message)
            }
        }
    }

    private var syncToggle: some View {
        SettingsToggleRow(
            title: String(localized: "Sync via iCloud"),
            description: String(
                localized: "Sync clipboard history across devices via iCloud"
            ),
            isOn: $syncEnabled
        )
        .onChange(of: syncEnabled) { _, enabled in
            onSyncEnabledChange(enabled)
        }
    }
}

private struct SettingsSyncStatusRow: View {
    let status: SettingsSyncStatus
    let syncEnabled: Bool

    var body: some View {
        switch status {
        case .idle:
            LabeledContent(
                String(localized: "Status"),
                value: syncEnabled ? String(localized: "On") : String(localized: "Off")
            )
        case .connecting:
            SettingsSyncProgressStatus(value: String(localized: "Connecting"))
        case let .syncing(activityDescription):
            SettingsSyncProgressStatus(value: activityDescription)
        case let .synced(lastSync):
            LabeledContent(String(localized: "Status")) {
                if -lastSync.timeIntervalSinceNow < 60 {
                    Text(String(localized: "Synced just now"))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Synced \(lastSync, style: .relative) ago")
                        .foregroundStyle(.secondary)
                }
            }
        case .temporarilyUnavailable:
            LabeledContent(
                String(localized: "Status"),
                value: String(localized: "Temporarily unavailable")
            )
        case let .unavailable(message):
            SettingsSyncUnavailableStatus(message: message)
        case let .failed(message):
            LabeledContent(String(localized: "Status")) {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }
}

private struct SettingsSyncProgressStatus: View {
    let value: String

    var body: some View {
        HStack {
            Text(String(localized: "Status"))
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsSyncUnavailableStatus: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(
                String(localized: "Status"),
                value: String(localized: "Unavailable")
            )
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
