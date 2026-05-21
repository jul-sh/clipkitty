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
            .overlay(alignment: .top) {
                syncActivityOverlay
                    .padding(.top, 12)
                    .padding(.horizontal, 18)
            }
            .overlay(alignment: .bottom) {
                toastOverlay
                    .padding(.bottom, 80)
            }
    }

    @ViewBuilder
    private var syncActivityOverlay: some View {
        #if ENABLE_ICLOUD_SYNC
            Group {
                switch syncCoordinator.status {
                case let .syncing(activity):
                    ICloudSyncActivityOverlay(activity: activity)
                        .transition(.move(edge: .top).combined(with: .opacity))
                case .idle, .connecting, .synced, .error, .temporarilyUnavailable, .unavailable:
                    EmptyView()
                }
            }
            // The status comes from an `@Observable` coordinator, so updates
            // aren't wrapped in `withAnimation` at the mutation site; drive the
            // overlay's transition from the status value itself.
            .animation(.bouncy, value: syncCoordinator.status)
        #else
            EmptyView()
        #endif
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let message = appState.toast.message {
            GlassEffectContainer {
                HStack(spacing: 10) {
                    Image(systemName: message.iconSystemName)
                        .font(.subheadline.weight(.medium))
                    Text(message.text)
                        .font(.subheadline.weight(.medium))

                    if let actionTitle = message.actionTitle, let action = appState.toast.action {
                        Button {
                            action()
                            withAnimation(.bouncy) {
                                appState.toast = .init()
                            }
                        } label: {
                            Text(actionTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

#if ENABLE_ICLOUD_SYNC
    private struct ICloudSyncActivityOverlay: View {
        private static let largeDownloadThreshold = 25

        let activity: SyncEngine.SyncActivity

        var body: some View {
            switch content {
            case .hidden:
                EmptyView()
            case let .visible(icon, label):
                // Mirror `toastOverlay`: a single-line glass capsule with a
                // leading icon, `.subheadline.weight(.medium)` text, and a
                // trailing affordance (here a spinner instead of an action).
                GlassEffectContainer {
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.tint)

                        Text(label)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        ProgressView()
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
        }

        private enum Content {
            case hidden
            case visible(icon: String, label: String)
        }

        private var content: Content {
            switch activity {
            case let .downloading(download), let .applying(download):
                return downloadContent(download)
            case let .rebuildingIndex(indexActivity):
                switch indexActivity {
                case .localMaintenance:
                    return .hidden
                case let .downloadedContent(download):
                    return indexContent(download)
                }
            case .compacting, .uploading, .cleaningUp:
                return .hidden
            }
        }

        private func downloadContent(_ download: SyncEngine.SyncDownloadActivity) -> Content {
            switch download {
            case .startingFullResync:
                return .visible(
                    icon: "icloud.and.arrow.down",
                    label: String(localized: "Catching up with iCloud")
                )
            case let .incremental(records), let .fullResync(records):
                let total = records.total
                guard total >= Self.largeDownloadThreshold else { return .hidden }
                return .visible(
                    icon: "icloud.and.arrow.down",
                    label: String(localized: "Syncing \(total) changes from iCloud")
                )
            }
        }

        private func indexContent(_ download: SyncEngine.SyncDownloadActivity) -> Content {
            switch download {
            case .startingFullResync:
                return .visible(
                    icon: "magnifyingglass",
                    label: String(localized: "Preparing search")
                )
            case let .incremental(records), let .fullResync(records):
                let total = records.total
                guard total >= Self.largeDownloadThreshold else { return .hidden }
                return .visible(
                    icon: "magnifyingglass",
                    label: String(localized: "Indexing \(total) changes")
                )
            }
        }
    }
#endif
