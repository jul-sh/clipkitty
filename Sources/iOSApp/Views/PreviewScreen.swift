import ClipKittyAppleServices
import ClipKittyRust
import ClipKittyShared
import SwiftUI
import UIKit

struct PreviewScreen: View {
    let itemId: String

    @Environment(AppContainer.self) private var container
    @Environment(BrowserViewModel.self) private var viewModel
    @Environment(AppState.self) private var appState
    @Environment(HapticsClient.self) private var haptics
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirmation = false

    private let isUITestPreviewDebugEnabled = CommandLine.arguments.contains("--use-simulated-db")

    var body: some View {
        Group {
            if let selectedItemState = viewModel.selectedItemState {
                contentView(for: selectedItemState)
            } else {
                ProgressView(String(localized: "Loading..."))
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .bottomBar)
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
        .alert(String(localized: "Delete Item"), isPresented: $showDeleteConfirmation) {
            Button(String(localized: "Delete"), role: .destructive) {
                viewModel.deleteItem(itemId: itemId)
                haptics.fire(.destructive)
                appState.showToast(.deleted)
                dismiss()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this item? This cannot be undone.", comment: "Delete confirmation message")
        }
        .onAppear {
            viewModel.select(itemId: itemId, origin: .user)
        }
    }

    // MARK: - Navigation Title

    private var navigationTitle: String {
        guard let item = viewModel.selectedItemState?.item else { return String(localized: "Detail") }
        switch item.content {
        case .text: return String(localized: "Text")
        case .link: return String(localized: "Link")
        case .image: return String(localized: "Image")
        case .color: return String(localized: "Color")
        case .file: return String(localized: "File")
        }
    }

    // MARK: - Preview Decoration

    private func previewDecoration(for content: SelectedItemState) -> PreviewDecoration? {
        switch content.previewState {
        case .plain, .loadingDecoration(previous: nil):
            return nil
        case let .loadingDecoration(previous: .some(decoration)), let .highlighted(decoration):
            return decoration
        }
    }

    private var isDirty: Bool {
        if case let .dirty(dirtyId, _) = viewModel.editSession, dirtyId == itemId {
            return true
        }
        return false
    }

    // MARK: - Content

    private func contentView(for selectedItemState: SelectedItemState) -> some View {
        ZStack {
            contentSection(for: selectedItemState)
            if case .loadingDecoration = selectedItemState.previewState,
               viewModel.previewSpinnerVisible
            {
                ProgressView()
            }
        }
        .overlay(alignment: .topLeading) {
            if isUITestPreviewDebugEnabled {
                Color.clear
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(previewHighlightDebugLabel(
                        for: selectedItemState
                    ))
                    .accessibilityIdentifier("PreviewHighlightDebug")
            }
        }
    }

    private func previewHighlightDebugLabel(for content: SelectedItemState) -> String {
        let text = content.item.content.textContent
        let itemId = content.item.itemMetadata.itemId
        let state: String
        let fragments: [String]

        switch content.previewState {
        case .plain:
            state = "plain"
            fragments = []
        case .loadingDecoration(previous: nil):
            state = "loading-decoration"
            fragments = []
        case let .loadingDecoration(previous: .some(decoration)):
            state = "loading-decoration-stale"
            fragments = HighlightAttributedStringBuilder.fragments(in: text, highlights: decoration.highlights)
        case let .highlighted(decoration):
            state = "highlighted"
            fragments = HighlightAttributedStringBuilder.fragments(in: text, highlights: decoration.highlights)
        }

        let joinedFragments = fragments.isEmpty ? "none" : fragments.joined(separator: "|")
        return "item=\(itemId);state=\(state);highlights=\(joinedFragments)"
    }

    @ViewBuilder
    private func contentSection(for selectedItemState: SelectedItemState) -> some View {
        let item = selectedItemState.item
        switch item.content {
        case let .text(value):
            let previewText: String = {
                if case let .dirty(dirtyId, draft) = viewModel.editSession, dirtyId == item.itemMetadata.itemId {
                    return draft
                }
                return value
            }()
            let decoration = isDirty ? nil : previewDecoration(for: selectedItemState)
            TextPreviewView(
                itemId: item.itemMetadata.itemId,
                text: previewText,
                highlights: decoration?.highlights ?? [],
                initialScrollHighlightIndex: decoration?.initialScrollHighlightIndex,
                isEditable: true,
                onTextChange: { newText in
                    viewModel.onTextEdit(newText, for: item.itemMetadata.itemId, originalText: value)
                },
                onEditingStateChange: { editing in
                    viewModel.onEditingStateChange(editing, for: item.itemMetadata.itemId)
                }
            )
        case let .color(value):
            let decoration = isDirty ? nil : previewDecoration(for: selectedItemState)
            VStack(spacing: 0) {
                // Color swatch at top
                RoundedRectangle(cornerRadius: 16)
                    .fill(color(from: value))
                    .frame(height: 120)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                // Color value text in TextKit 2 renderer (supports highlights + editing)
                TextPreviewView(
                    itemId: item.itemMetadata.itemId,
                    text: value,
                    highlights: decoration?.highlights ?? [],
                    initialScrollHighlightIndex: decoration?.initialScrollHighlightIndex,
                    isEditable: false
                )
            }
        case let .link(url, metadataState):
            let decoration = previewDecoration(for: selectedItemState)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    linkContent(url: url, metadataState: metadataState, highlights: decoration?.highlights ?? [])
                    Divider()
                    metadataSection(for: item)
                }
                .cardSurface()
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        case let .image(data, description, _):
            let decoration = previewDecoration(for: selectedItemState)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    imageContent(data: data, description: description, highlights: decoration?.highlights ?? [])
                    Divider()
                    metadataSection(for: item)
                }
                .cardSurface()
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("File items are not supported on iPhone.", comment: "Unsupported content type message")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Divider()
                    metadataSection(for: item)
                }
                .cardSurface()
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
    }

    private func color(from hex: String) -> Color {
        let sanitized = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let int = UInt64(sanitized, radix: 16) else { return .gray }

        let r: Double
        let g: Double
        let b: Double
        let a: Double

        switch sanitized.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
            a = 1.0
        case 8:
            r = Double((int >> 24) & 0xFF) / 255.0
            g = Double((int >> 16) & 0xFF) / 255.0
            b = Double((int >> 8) & 0xFF) / 255.0
            a = Double(int & 0xFF) / 255.0
        default:
            return .gray
        }

        return Color(red: r, green: g, blue: b, opacity: a)
    }

    // MARK: - Link Content

    private func linkContent(url: String, metadataState: LinkMetadataState, highlights: [Utf16HighlightRange]) -> some View {
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
                Text(HighlightAttributedStringBuilder.attributedText(url, highlights: highlights))
                    .font(.custom(FontManager.mono, size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Image Content

    private func imageContent(data: Data, description: String, highlights: [Utf16HighlightRange]) -> some View {
        VStack(spacing: 8) {
            if let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }
            if !description.isEmpty {
                if highlights.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(HighlightAttributedStringBuilder.attributedText(description, highlights: highlights))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Metadata Section

    private func metadataSection(for item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details", comment: "Section header for item metadata")
                .font(.headline)

            LabeledContent(String(localized: "Type"), value: navigationTitle)

            if let sourceApp = item.itemMetadata.sourceApp {
                LabeledContent(String(localized: "Source"), value: sourceApp)
            }

            LabeledContent(String(localized: "Time")) {
                Text(formattedDate(from: item.itemMetadata.timestampUnix))
            }

            LabeledContent(String(localized: "Bookmarked")) {
                Text(isBookmarked(item) ? String(localized: "Yes") : String(localized: "No"))
            }
        }
        .font(.subheadline)
    }

    private func formattedDate(from unix: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    // MARK: - Action Bar

    @ViewBuilder
    private var actionBar: some View {
        if let item = viewModel.selectedItemState?.item {
            if isDirty {
                // Dirty state: show Save and Cancel only
                GlassEffectContainer(spacing: 20) {
                    HStack(spacing: 20) {
                        Button {
                            viewModel.discardCurrentEdit()
                        } label: {
                            Text(String(localized: "Cancel"))
                                .font(.body.weight(.medium))
                                .frame(height: 52)
                                .padding(.horizontal, 20)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)

                        Button {
                            viewModel.commitCurrentEdit()
                            appState.showToast(.saved)
                        } label: {
                            Text(String(localized: "Save"))
                                .font(.body.weight(.semibold))
                                .frame(height: 52)
                                .padding(.horizontal, 20)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            } else {
                // Normal state: standard action bar
                GlassEffectContainer(spacing: 20) {
                    HStack(spacing: 20) {
                        // Left circle: Share
                        Button {
                            SharePresenter.present(item: item)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.body.weight(.medium))
                                .frame(width: 52, height: 52)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)

                        // Center capsule: Bookmark, Copy
                        HStack(spacing: 0) {
                            Button {
                                toggleBookmark(for: item)
                            } label: {
                                Image(systemName: isBookmarked(item) ? "bookmark.slash" : "bookmark")
                                    .font(.body.weight(.medium))
                                    .frame(width: 52, height: 52)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                container.clipboardService.copy(content: item.content)
                                haptics.fire(.copy)
                                appState.showToast(.copied)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.body.weight(.medium))
                                    .frame(width: 52, height: 52)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .glassEffect(.regular.interactive(), in: .capsule)

                        // Right circle: Delete
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.body.weight(.medium))
                                .frame(width: 52, height: 52)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Helpers

    private func isBookmarked(_ item: ClipboardItem) -> Bool {
        item.itemMetadata.tags.contains(.bookmark)
    }

    private func toggleBookmark(for item: ClipboardItem) {
        if isBookmarked(item) {
            viewModel.removeTag(.bookmark, fromItem: item.itemMetadata.itemId)
            haptics.fire(.selection)
            appState.showToast(.unbookmarked)
        } else {
            viewModel.addTag(.bookmark, toItem: item.itemMetadata.itemId)
            haptics.fire(.selection)
            appState.showToast(.bookmarked)
        }
    }
}
