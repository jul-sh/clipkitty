import ClipKittyShared
import SwiftUI

#if ENABLE_ICLOUD_SYNC
    import ClipKittyAppleServices
#endif

struct RootView: View {
    @Environment(AppState.self) private var appState
    #if ENABLE_ICLOUD_SYNC
        @Environment(iOSSyncCoordinator.self) private var syncCoordinator
    #endif

    var body: some View {
        HomeFeedView()
            // Window-wide: anything draggable from another app can be
            // dropped anywhere over ClipKitty to become a clip. Applied
            // beneath the snackbar overlay so the "Added" toast still draws
            // above the drop chrome.
            .addClipDropTarget()
            .overlay(alignment: .bottom) {
                if let item = activeSnackbar {
                    SnackbarOverlay(item: item) {
                        if case .notification(.actionable) = item, let action = appState.toast.action {
                            action()
                            withAnimation(.bouncy) {
                                appState.toast = .init()
                            }
                        }
                    }
                    .padding(.bottom, 80)
                }
            }
            // Drive the slot's transition off the active value so info-state
            // changes (sourced from `@Observable` coordinators that don't wrap
            // mutations in `withAnimation`) still animate.
            .animation(.bouncy, value: activeSnackbar)
    }

    // MARK: - Snackbar resolution

    //
    // Mirrors the Mac's `SnackbarScheduler.evaluateSnackbar`: a single bottom
    // slot rendered from one `SnackbarItem`. Notifications (transient toasts)
    // take precedence over info (ongoing status) so e.g. tapping "Copied"
    // during a sync briefly replaces the sync capsule, exactly like the Mac.

    private var activeSnackbar: SnackbarItem? {
        if let kind = appState.toast.kind {
            return .notification(kind)
        }
        if let info = ongoingInfo {
            return .info(info)
        }
        return nil
    }

    private var ongoingInfo: InfoKind? {
        #if ENABLE_ICLOUD_SYNC
            switch syncCoordinator.status {
            case let .syncing(activity):
                return Self.infoKind(for: activity)
            case .idle, .connecting, .synced, .error, .temporarilyUnavailable, .unavailable:
                return nil
            }
        #else
            return nil
        #endif
    }

    #if ENABLE_ICLOUD_SYNC
        /// Suppress overlay activity for batches smaller than this. Tiny syncs
        /// would just flash the capsule in and out.
        private static let largeDownloadThreshold = 25

        static func infoKind(for activity: SyncEngine.SyncActivity) -> InfoKind? {
            switch activity {
            case let .downloading(download), let .applying(download):
                return infoKindForDownload(download)
            case let .rebuildingIndex(indexActivity):
                switch indexActivity {
                case .localMaintenance:
                    return nil
                case let .downloadedContent(download):
                    // Indexing downloaded content reads to the user as the
                    // tail end of the same iCloud sync; reuse the same copy.
                    return infoKindForDownload(download)
                }
            case .compacting, .uploading, .cleaningUp:
                return nil
            }
        }

        private static func infoKindForDownload(_ download: SyncEngine.SyncDownloadActivity) -> InfoKind? {
            switch download {
            case .startingFullResync:
                return .catchingUpWithCloud
            case let .incremental(records), let .fullResync(records):
                let total = records.total
                guard total >= largeDownloadThreshold else { return nil }
                return .syncingCloudChanges(count: total)
            }
        }
    #endif
}

// MARK: - Snackbar rendering

//
// The iOS counterpart of Mac's `SnackbarView`: one switch over `SnackbarItem`
// renders the bottom slot. iOS doesn't surface `.nudge` items (no launch-at-
// login nudge), so that case falls through to an empty view.

private struct SnackbarOverlay: View {
    let item: SnackbarItem
    let onAction: () -> Void

    var body: some View {
        Group {
            switch item {
            case let .notification(kind):
                NotificationSnackbarCapsule(kind: kind, onAction: onAction)
            case let .info(kind):
                InfoSnackbarCapsule(kind: kind)
            case .nudge:
                EmptyView()
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct NotificationSnackbarCapsule: View {
    let kind: NotificationKind
    let onAction: () -> Void

    var body: some View {
        SnackbarCapsule {
            Image(systemName: kind.iconSystemName)
                .font(.subheadline.weight(.medium))

            Text(kind.message)
                .font(.subheadline.weight(.medium))

            if case let .actionable(_, _, actionTitle) = kind {
                Button(action: onAction) {
                    Text(actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct InfoSnackbarCapsule: View {
    let kind: InfoKind

    var body: some View {
        SnackbarCapsule {
            if let icon = kind.iconSystemName {
                Image(systemName: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tint)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            Text(kind.message)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            // Ongoing status always shows a trailing spinner so it reads as
            // "still working", matching the Mac's rebuilding-index treatment.
            ProgressView()
                .controlSize(.small)
        }
    }
}

/// Glass capsule shared by every snackbar variant. iOS-only styling; the Mac
/// has its own equivalent in `Snackbar.swift` because the platform glass APIs
/// differ enough that a single SwiftUI view would fork on `#if os(...)`
/// throughout.
private struct SnackbarCapsule<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 10) {
                content
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}
