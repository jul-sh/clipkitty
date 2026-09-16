#if ENABLE_ICLOUD_SYNC

    import ClipKittyCloudSync
    import Foundation
    import SwiftUI

    /// A stable, testable projection of every CloudKit state. Only the failure
    /// states reach the toolbar (see `isVisible`); the rest exist so Settings
    /// and VoiceOver can describe what sync is doing.
    struct iOSSyncStatusPresentation: Equatable {
        enum Phase: Equatable {
            case off
            case idle
            case connecting
            case syncing(SyncEngine.SyncActivity)
            case synced(lastSync: Date)
            case error(String)
            case temporarilyUnavailable
            case unavailable
        }

        let phase: Phase

        /// The one phase that needs the user's attention rather than patience.
        var isFailure: Bool {
            if case .error = phase { return true }
            return false
        }

        init(syncEnabled: Bool, status: SyncEngine.SyncStatus?) {
            guard syncEnabled else {
                phase = .off
                return
            }
            guard let status else {
                phase = .unavailable
                return
            }

            switch status {
            case .idle:
                phase = .idle
            case .connecting:
                phase = .connecting
            case let .syncing(activity):
                phase = .syncing(activity)
            case let .synced(lastSync):
                phase = .synced(lastSync: lastSync)
            case let .error(message):
                phase = .error(message)
            case .temporarilyUnavailable:
                phase = .temporarilyUnavailable
            case .unavailable:
                phase = .unavailable
            }
        }

        /// Whether the toolbar shows the control at all. Sync is ambient, and
        /// in-flight work is no more actionable than a resting state, so the
        /// slot is occupied only by a failure the user may need to resolve.
        var isVisible: Bool {
            switch phase {
            case .error, .temporarilyUnavailable:
                return true
            case .off, .idle, .connecting, .syncing, .synced, .unavailable:
                return false
            }
        }

        func accessibilityValue(
            now: Date = Date(),
            locale: Locale = .current
        ) -> String {
            switch phase {
            case .off:
                return String(localized: "Sync is off", locale: locale)
            case .idle:
                return String(localized: "Waiting to sync", locale: locale)
            case .connecting:
                return String(localized: "Connecting", locale: locale)
            case let .syncing(activity):
                return activity.statusDescription
            case let .synced(lastSync):
                guard abs(lastSync.timeIntervalSince(now)) >= 60 else {
                    return String(localized: "Synced just now", locale: locale)
                }

                let formatter = RelativeDateTimeFormatter()
                formatter.locale = locale
                formatter.unitsStyle = .full
                let relative = formatter.localizedString(for: lastSync, relativeTo: now)
                let format = String(localized: "Synced %@", locale: locale)
                return String(format: format, locale: locale, arguments: [relative])
            case let .error(message):
                guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return String(localized: "Sync failed", locale: locale)
                }
                return message
            case .temporarilyUnavailable:
                return String(localized: "iCloud temporarily unavailable", locale: locale)
            case .unavailable:
                return String(localized: "iCloud not available", locale: locale)
            }
        }
    }

    /// Top-toolbar-ready iCloud failure indicator.
    ///
    /// The navigation toolbar supplies the circular Liquid Glass material. The
    /// indicator appears only when sync has failed or iCloud is unavailable
    /// (see `isVisible`), so a healthy feed carries nothing in its leading
    /// slot. It reports state and does not offer a manual trigger.
    struct SyncStatusButton: View {
        @Environment(iOSSettingsStore.self) private var settings
        @Environment(iOSSyncCoordinator.self) private var syncCoordinator: iOSSyncCoordinator?

        var body: some View {
            let presentation = iOSSyncStatusPresentation(
                syncEnabled: settings.syncEnabled,
                status: syncCoordinator?.status
            )

            if presentation.isVisible {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.body.weight(.medium))
                    .foregroundStyle(presentation.isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .accessibilityLabel(String(localized: "iCloud Sync"))
                    .accessibilityValue(presentation.accessibilityValue())
                    .accessibilityIdentifier("home.syncStatusButton")
            }
        }
    }

#endif
