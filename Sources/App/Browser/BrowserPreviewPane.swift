import SwiftUI
import AppKit
import ClipKittyRust

struct BrowserPreviewPane: View {
    @Bindable var viewModel: BrowserViewModel
    let focusSearchField: () -> Void
    let focusTarget: FocusState<BrowserView.FocusTarget?>.Binding

    var body: some View {
        Group {
            switch viewModel.session.preview {
            case .loaded(let selection):
                VStack(spacing: 0) {
                    previewContent(for: selection.item, matchData: selection.matchData)
                    Divider()
                    metadataFooter(for: selection.item)
                }
            case .loading(_, let stale):
                ZStack {
                    if let stale {
                        previewContent(for: stale.item, matchData: stale.matchData)
                            .allowsHitTesting(false)
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if viewModel.previewSpinnerVisible {
                        ProgressView()
                    }
                }
            case .failed:
                Self.error(String(localized: "Unable to load preview"))
            case .empty:
                if viewModel.itemIds.isEmpty {
                    emptyState
                } else {
                    Text("No item selected")
                        .font(.custom(FontManager.sansSerif, size: 16))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(.black.opacity(0.05))
    }

    static func error(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.custom(FontManager.sansSerif, size: 15))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func previewContent(for item: ClipboardItem, matchData: MatchData?) -> some View {
        switch item.content {
        case .text, .color:
            TextPreviewView(
                text: item.content.textContent,
                fontName: FontManager.mono,
                fontSize: 15,
                highlights: matchData?.fullContentHighlights ?? [],
                densestHighlightStart: matchData?.densestHighlightStart ?? 0
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image(let data, let description, _):
            ScrollView(.vertical, showsIndicators: true) {
                if let image = NSImage(data: data) {
                    VStack(spacing: 8) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                        if !description.isEmpty {
                            Text(description)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                }
            }
        case .link(let url, let metadataState):
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    LinkPreviewView(url: url, metadataState: metadataState)
                        .frame(maxWidth: .infinity)

                    Text(url)
                        .font(.custom(FontManager.mono, size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer()
                }
                .padding(16)
            }
        case .file(_, let files):
            FilePreviewView(files: files, searchQuery: viewModel.searchText)
        }
    }

    private func metadataFooter(for item: ClipboardItem) -> some View {
        HStack(spacing: 12) {
            Label(item.timeAgo, systemImage: "clock")
                .lineLimit(1)

            // Show bookmark icon and "Bookmark" for bookmarked items, otherwise show source app
            if item.itemMetadata.tags.contains(.bookmark) {
                HStack(spacing: 4) {
                    Image("BookmarkIcon")
                        .resizable()
                        .frame(width: 14, height: 14)
                    Text("Bookmark")
                        .lineLimit(1)
                }
            } else if let app = item.itemMetadata.sourceApp {
                HStack(spacing: 4) {
                    if let bundleID = item.itemMetadata.sourceAppBundleId,
                       let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                            .resizable()
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "app")
                    }
                    Text(app)
                        .lineLimit(1)
                }
            }

            BrowserActionsOverlay(
                viewModel: viewModel,
                focusSearchField: focusSearchField,
                focusTarget: focusTarget
            )
            .fixedSize()

            Spacer(minLength: 0)

            Button {
                viewModel.confirmSelection()
            } label: {
                Text("⏎ \(AppSettings.shared.pasteMode.buttonLabel)")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .subtleHover()
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 17)
        .padding(.vertical, 11)
        .background(.black.opacity(0.05))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clipboard")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(emptyStateMessage)
                .font(.custom(FontManager.sansSerif, size: 15))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateMessage: String {
        if viewModel.searchText.isEmpty,
           viewModel.contentTypeFilter == .all,
           viewModel.selectedTagFilter == nil {
            return String(localized: "No clipboard history")
        }
        return String(localized: "No results")
    }
}
