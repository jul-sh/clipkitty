#if ENABLE_ICLOUD_SYNC

    import ClipKittyCloudSync
    import Foundation
    import SwiftUI

    /// A stable, testable projection of every CloudKit state shown by the
    /// toolbar control. The symbol itself never changes, so status changes do
    /// not make the leading toolbar item jump; only active work rotates it.
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

        var isAnimating: Bool {
            switch phase {
            case .connecting, .syncing:
                return true
            case .off, .idle, .synced, .error, .temporarilyUnavailable, .unavailable:
                return false
            }
        }

        /// Whether the toolbar shows the control at all. Sync is ambient: a
        /// resting spinner is chrome the user cannot act on, so the slot is
        /// occupied only while work is actually in flight. Failures stay
        /// visible because they are the one state the user may need to see.
        var isVisible: Bool {
            switch phase {
            case .connecting, .syncing, .error, .temporarilyUnavailable:
                return true
            case .off, .idle, .synced, .unavailable:
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

    /// Top-toolbar-ready iCloud status and manual sync control.
    ///
    /// The navigation toolbar supplies the circular Liquid Glass material. The
    /// control appears only while sync is working or has something the user
    /// needs to see (see `isVisible`), so a resting feed carries no idle
    /// spinner in its leading slot.
    struct SyncStatusButton: View {
        @Environment(iOSSettingsStore.self) private var settings
        @Environment(iOSSyncCoordinator.self) private var syncCoordinator: iOSSyncCoordinator?
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let presentation = iOSSyncStatusPresentation(
                syncEnabled: settings.syncEnabled,
                status: syncCoordinator?.status
            )
            let canRequestSync = settings.syncEnabled &&
                (syncCoordinator?.canRequestSync ?? false)

            if presentation.isVisible {
                if canRequestSync {
                    button(presentation: presentation, canRequestSync: true)
                        .accessibilityHint(String(localized: "Sync now"))
                } else {
                    button(presentation: presentation, canRequestSync: false)
                }
            }
        }

        private func button(
            presentation: iOSSyncStatusPresentation,
            canRequestSync: Bool
        ) -> some View {
            Button {
                syncCoordinator?.requestSync()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .symbolEffect(
                        .rotate.clockwise,
                        options: .repeat(.continuous),
                        isActive: presentation.isAnimating && !reduceMotion
                    )
            }
            .disabled(!canRequestSync)
            .accessibilityLabel(String(localized: "iCloud Sync"))
            .accessibilityValue(presentation.accessibilityValue())
            .accessibilityIdentifier("home.syncStatusButton")
        }
    }

#endif
