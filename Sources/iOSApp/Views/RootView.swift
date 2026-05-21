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
            case let .visible(title, detail):
                GlassEffectContainer {
                    HStack(spacing: 12) {
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.headline)
                            .foregroundStyle(.tint)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                        Spacer(minLength: 8)

                        ProgressView()
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: 420, minHeight: 52)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                }
            }
        }

        private enum Content {
            case hidden
            case visible(title: String, detail: String)
        }

        private var content: Content {
            switch activity {
            case let .downloading(download):
                return downloadContent(download, verb: String(localized: "Downloading"))
            case let .applying(download):
                return downloadContent(download, verb: String(localized: "Updating"))
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

        private func downloadContent(
            _ download: SyncEngine.SyncDownloadActivity,
            verb: String
        ) -> Content {
            switch download {
            case .startingFullResync:
                return .visible(
                    title: String(localized: "Downloading iCloud history"),
                    detail: String(localized: "ClipKitty is catching up")
                )
            case let .incremental(records), let .fullResync(records):
                let total = records.total
                guard total >= Self.largeDownloadThreshold else { return .hidden }
                return .visible(
                    title: String(localized: "\(verb) iCloud content"),
                    detail: String(localized: "\(total) changes")
                )
            }
        }

        private func indexContent(_ download: SyncEngine.SyncDownloadActivity) -> Content {
            switch download {
            case .startingFullResync:
                return .visible(
                    title: String(localized: "Indexing downloaded content"),
                    detail: String(localized: "Preparing search")
                )
            case let .incremental(records), let .fullResync(records):
                let total = records.total
                guard total >= Self.largeDownloadThreshold else { return .hidden }
                return .visible(
                    title: String(localized: "Indexing downloaded content"),
                    detail: String(localized: "\(total) changes")
                )
            }
        }
    }
#endif
