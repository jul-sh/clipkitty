import AppKit
import ClipKittyRust
import SwiftUI

struct BrowserPreviewPane: View {
    @Bindable var viewModel: BrowserViewModel
    let focusSearchField: () -> Void
    let focusTarget: FocusState<BrowserView.FocusTarget?>.Binding

    var body: some View {
        Group {
            switch viewModel.selection {
            case let .selected(content):
                VStack(spacing: 0) {
                    previewContent(for: content)
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

    @ViewBuilder
    private func previewContent(for content: SelectedItemState) -> some View {
        let item = content.item
        switch item.content {
        case .text, .color:
            let previewDecoration: PreviewDecoration? = {
                if case let .highlighted(decoration) = content.previewState {
                    return decoration
                }
                return nil
            }()
            TextPreviewView(
                text: viewModel.pendingEdits[item.itemMetadata.itemId] ?? item.content.textContent,
                fontName: FontManager.mono,
                fontSize: 15,
                highlights: previewDecoration?.highlights ?? [],
                initialScrollHighlightIndex: previewDecoration?.initialScrollHighlightIndex,
                scrollBehavior: {
                    switch content.previewState {
                    case .none:
                        return .autoScroll
                    case .highlighted:
                        return content.origin == .user ? .trackHighlight : .autoScroll
                    }
                }(),
                itemId: item.itemMetadata.itemId,
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
            .id(previewIdentity(itemId: item.itemMetadata.itemId))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .image(data, description, _):
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
        case let .link(url, metadataState):
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

    private func metadataFooter(for item: ClipboardItem) -> some View {
        let itemId = item.itemMetadata.itemId
        let hasPendingEdit = viewModel.hasPendingEdit(for: itemId)
        let isFocused = viewModel.editFocus == .focused(itemId: itemId)

        return HStack(spacing: 12) {
            if hasPendingEdit {
                // Edit mode: show Discard and Save buttons
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
                    Text("\(isFocused ? "⌘" : "")↩ \(AppSettings.shared.pasteMode.editConfirmLabel)")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .subtleHover()
                }
                .buttonStyle(.plain)
                .fixedSize()
            } else {
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
