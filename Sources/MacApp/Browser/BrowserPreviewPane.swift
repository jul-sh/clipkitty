import AppKit
import ClipKittyAppleServices
import ClipKittyMacPlatform
import ClipKittyRust
import ClipKittyShared
import SwiftUI

struct BrowserPreviewPane: View {
    @Bindable var viewModel: BrowserViewModel
    let focusSearchField: () -> Void
    let focusTarget: FocusState<BrowserView.FocusTarget?>.Binding

    private let isUITestPreviewDebugEnabled = CommandLine.arguments.contains("--use-simulated-db")

    var body: some View {
        Group {
            switch viewModel.selection {
            case let .selected(content):
                VStack(spacing: 0) {
                    ZStack {
                        previewContent(for: content)
                        if case .loadingDecoration = content.previewState,
                           viewModel.previewSpinnerVisible
                        {
                            ProgressView()
                        }
                    }
                    Divider()
                    metadataFooter(for: content.item)
                }
            case .loading:
                ZStack {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if viewModel.previewSpinnerVisible {
                        ProgressView()
                    }
                }
            case .failed:
                Self.error(String(localized: "Unable to load preview"))
            case .none:
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

    private func previewDecoration(for content: SelectedItemState) -> PreviewDecoration? {
        switch content.previewState {
        case .plain, .loadingDecoration(previous: nil):
            return nil
        case let .loadingDecoration(previous: .some(decoration)), let .highlighted(decoration):
            return decoration
        }
    }

    @ViewBuilder
    private func previewContent(for content: SelectedItemState) -> some View {
        let item = content.item
        switch item.content {
        case .text, .color:
            let previewText: String = {
                if case let .dirty(dirtyId, draft) = viewModel.editSession, dirtyId == item.itemMetadata.itemId {
                    return draft
                }
                return item.content.textContent
            }()
            let decoration = previewDecoration(for: content)
            let _ = { TextPreviewView.textCache[item.itemMetadata.itemId] = previewText }()
            TextPreviewView(
                itemId: item.itemMetadata.itemId,
                fontName: FontManager.mono,
                fontSize: AppSettings.shared.scaled(15),
                highlights: decoration?.highlights ?? [],
                initialScrollHighlightIndex: decoration?.initialScrollHighlightIndex,
                scrollBehavior: {
                    switch content.previewState {
                    case .plain:
                        return .autoScroll
                    case let .loadingDecoration(previous):
                        return previous == nil ? .autoScroll : .manual
                    case .highlighted:
                        return content.origin.isUserInitiated ? .trackHighlight : .autoScroll
                    }
                }(),
                onTextChange: { newText in
                    viewModel.onTextEdit(newText, for: item.itemMetadata.itemId, originalText: item.content.textContent)
                },
                onEditingStateChange: { editing in
                    viewModel.onEditingStateChange(editing, for: item.itemMetadata.itemId)
                },
                onCmdReturn: {
                    viewModel.confirmSelection()
                },
                onCmdK: {
                    guard case .inactive = viewModel.editSession else { return }
                    viewModel.openActionsOverlay(highlight: .index(0))
                },
                onSave: {
                    viewModel.commitCurrentEdit()
                    focusSearchField()
                },
                onEscape: {
                    if case let .dirty(dirtyId, _) = viewModel.editSession, dirtyId == item.itemMetadata.itemId {
                        viewModel.discardCurrentEdit()
                    }
                    focusSearchField()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if isUITestPreviewDebugEnabled {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(previewHighlightDebugLabel(
                            text: previewText,
                            itemId: item.itemMetadata.itemId,
                            previewState: content.previewState
                        ))
                        .accessibilityIdentifier("PreviewHighlightDebug")
                }
            }
        case let .image(data, description, _):
            let highlights = previewDecoration(for: content)?.highlights ?? []
            ImagePreviewView(
                itemId: item.itemMetadata.itemId,
                data: data,
                description: description,
                highlights: highlights
            )
        case let .link(url, metadataState):
            let highlights = previewDecoration(for: content)?.highlights ?? []
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    #if ENABLE_LINK_PREVIEWS
                        LinkPreviewView(url: url, metadataState: metadataState)
                            .frame(maxWidth: .infinity)
                    #endif

                    if highlights.isEmpty {
                        Text(url)
                            .font(.custom(FontManager.mono, size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(HighlightStyler.attributedText(url, highlights: highlights))
                            .font(.custom(FontManager.mono, size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Spacer()
                }
                .padding(16)
            }
        case let .file(_, files):
            FilePreviewView(files: files, searchQuery: viewModel.searchText)
        }
    }

    private func previewIdentity(itemId: String) -> String {
        // Only tie the view identity to the item itself. If we include matchData properties,
        // SwiftUI will completely destroy and recreate the heavy NSTextView and TextKit 2
        // hierarchy on every keystroke. This bypasses the optimized highlight diffing logic
        // in `updateNSView` and causes 100% CPU hangs during rapid typing.
        return itemId
    }

    private func previewHighlightDebugLabel(
        text: String,
        itemId: String,
        previewState: SelectedPreviewState
    ) -> String {
        let state: String
        let fragments: [String]

        switch previewState {
        case .plain:
            state = "plain"
            fragments = []
        case .loadingDecoration(previous: nil):
            state = "loading-decoration"
            fragments = []
        case let .loadingDecoration(previous: .some(decoration)):
            state = "loading-decoration-stale"
            fragments = HighlightStyler.fragments(in: text, highlights: decoration.highlights)
        case let .highlighted(decoration):
            state = "highlighted"
            fragments = HighlightStyler.fragments(in: text, highlights: decoration.highlights)
        }

        let joinedFragments = fragments.isEmpty ? "none" : fragments.joined(separator: "|")
        return "item=\(itemId);state=\(state);highlights=\(joinedFragments)"
    }

    private func metadataFooter(for item: ClipboardItem) -> some View {
        return HStack(spacing: 12) {
            switch viewModel.editSession {
            case .dirty:
                // Edit mode: show Discard, Save, and confirm buttons
                Button {
                    viewModel.discardCurrentEdit()
                    focusSearchField()
                } label: {
                    Text("Esc Discard")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .subtleHover()
                }
                .buttonStyle(.plain)
                .fixedSize()

                Button {
                    viewModel.commitCurrentEdit()
                    focusSearchField()
                } label: {
                    Text("⌘S Save")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(0.4), lineWidth: 1)
                        )
                        .subtleHover()
                }
                .buttonStyle(.plain)
                .fixedSize()

                Spacer(minLength: 0)

                Button {
                    viewModel.confirmSelection()
                } label: {
                    Text("⌘↩ \(AppSettings.shared.pasteMode.editConfirmLabel)")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .subtleHover()
                }
                .buttonStyle(.plain)
                .fixedSize()

            case .focused:
                // Preview focused but not yet edited — Cmd+K is not active here
                Spacer(minLength: 0)

                Button {
                    viewModel.confirmSelection()
                } label: {
                    Text("⌘↩ \(AppSettings.shared.pasteMode.buttonLabel)")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .subtleHover()
                }
                .buttonStyle(.plain)
                .fixedSize()

            case .inactive:
                // Normal mode: show metadata and paste button
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
                           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                        {
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
           viewModel.selectedTagFilter == nil
        {
            return String(localized: "No clipboard history")
        }
        return String(localized: "No results")
    }
}

/// Decodes image bytes off the main thread and caches the result by item id so
/// typing-triggered re-renders don't block the main thread on `NSImage(data:)`.
private struct ImagePreviewView: View {
    let itemId: String
    let data: Data
    let description: String
    let highlights: [Utf16HighlightRange]

    @State private var image: NSImage?

    var body: some View {
        // Cap the image to the pane's height so it never overflows on its
        // own, but place the image+description stack inside a ScrollView so
        // long descriptions remain fully readable by scrolling the whole
        // preview.
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 8) {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: max(geo.size.height - 32, 120))
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                    if !description.isEmpty {
                        Group {
                            if highlights.isEmpty {
                                Text(description)
                            } else {
                                Text(HighlightStyler.attributedText(description, highlights: highlights))
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                }
                .padding(16)
                .frame(minHeight: geo.size.height - 32, alignment: .top)
            }
        }
        .task(id: itemId) {
            if let cached = ImagePreviewCache.shared.image(forKey: itemId) {
                image = cached
                return
            }
            image = nil
            let decoded = await Task.detached(priority: .userInitiated) { [data] in
                NSImage(data: data)
            }.value
            guard !Task.isCancelled, let decoded else { return }
            ImagePreviewCache.shared.setImage(decoded, forKey: itemId)
            image = decoded
        }
    }
}

private final class ImagePreviewCache {
    static let shared = ImagePreviewCache()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 32
        return cache
    }()

    func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: NSImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}
