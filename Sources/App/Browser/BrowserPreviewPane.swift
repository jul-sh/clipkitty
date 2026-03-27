import AppKit
import ClipKittyRust
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
            let previewText = viewModel.pendingEdits[item.itemMetadata.itemId] ?? item.content.textContent
            let decoration = previewDecoration(for: content)
            let _ = { TextPreviewView.textCache[item.itemMetadata.itemId] = previewText }()
            TextPreviewView(
                itemId: item.itemMetadata.itemId,
                fontName: FontManager.mono,
                fontSize: 15,
                highlights: decoration?.highlights ?? [],
                initialScrollHighlightIndex: decoration?.initialScrollHighlightIndex,
                scrollBehavior: {
                    switch content.previewState {
                    case .plain:
                        return .autoScroll
                    case let .loadingDecoration(previous):
                        return previous == nil ? .autoScroll : .manual
                    case .highlighted:
                        return content.origin == .user ? .trackHighlight : .autoScroll
                    }
                }(),
                originalText: item.content.textContent,
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
                    guard viewModel.previewInteractionMode == .browsing else { return }
                    viewModel.openActionsOverlay(highlight: .index(0))
                },
                onSave: {
                    viewModel.commitCurrentEdit()
                    focusSearchField()
                },
                onEscape: {
                    if viewModel.hasPendingEdit(for: item.itemMetadata.itemId) {
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
            ScrollView(.vertical, showsIndicators: true) {
                if let image = NSImage(data: data) {
                    VStack(spacing: 8) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                        if !description.isEmpty {
                            if highlights.isEmpty {
                                Text(description)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text(HighlightStyler.attributedText(description, highlights: highlights))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        case let .link(url, metadataState):
            let highlights = previewDecoration(for: content)?.highlights ?? []
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    LinkPreviewView(url: url, metadataState: metadataState)
                        .frame(maxWidth: .infinity)

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

    private func previewIdentity(itemId: Int64) -> String {
        // Only tie the view identity to the item itself. If we include matchData properties,
        // SwiftUI will completely destroy and recreate the heavy NSTextView and TextKit 2
        // hierarchy on every keystroke. This bypasses the optimized highlight diffing logic
        // in `updateNSView` and causes 100% CPU hangs during rapid typing.
        return String(itemId)
    }

    private func previewHighlightDebugLabel(
        text: String,
        itemId: Int64,
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
        let mode = viewModel.previewInteractionMode

        return HStack(spacing: 12) {
            switch mode {
            case .editing:
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

            case .previewing:
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

            case .browsing:
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
                        if let bundleID = item.itemMetadata.sourceAppBundleId {
                            let icon = viewModel.appIcon(for: bundleID)
                            if let icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "app")
                            }
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
