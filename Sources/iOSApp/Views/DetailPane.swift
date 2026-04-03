import ClipKittyRust
import ClipKittyShared
import QuickLook
import SwiftUI
import UIKit

/// Reusable detail view for displaying a clipboard item. Used as the persistent
/// detail column in RegularShell and as the content of PreviewScreen in CompactShell.
struct DetailPane: View {
    let itemId: String

    @Environment(AppContainer.self) private var container
    @Environment(BrowserViewModel.self) private var viewModel
    @Environment(SceneState.self) private var sceneState
    @Environment(HapticsClient.self) private var haptics
    @Environment(\.windowScene) private var windowScene

    @State private var showDeleteConfirmation = false
    @State private var quickLookURL: URL?
    @State private var shareAnchorView: UIView?

    /// Optional dismiss action — present only when used in a pushed navigation context.
    var onDelete: (() -> Void)?

    var body: some View {
        Group {
            if let selectedItemState = viewModel.selectedItemState,
               selectedItemState.item.itemMetadata.itemId == itemId
            {
                contentView(for: selectedItemState.item)
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
                sceneState.showToast(.deleted)
                onDelete?()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this item? This cannot be undone.", comment: "Delete confirmation message")
        }
        .onAppear {
            viewModel.select(itemId: itemId, origin: .user)
        }
        .onChange(of: itemId) { _, newId in
            viewModel.select(itemId: newId, origin: .user)
        }
        .background {
            if let item = viewModel.selectedItemState?.item,
               item.itemMetadata.itemId == itemId
            {
                VStack {
                    Button("") {
                        container.clipboardService.copy(content: item.content)
                        haptics.fire(.copy)
                        sceneState.showToast(.copied)
                    }
                    .keyboardShortcut("c", modifiers: .command)
                    .hidden()

                    Button("") {
                        toggleBookmark(for: item)
                    }
                    .keyboardShortcut("b", modifiers: .command)
                    .hidden()

                    Button("") {
                        showDeleteConfirmation = true
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .hidden()
                }
                .frame(width: 0, height: 0)
            }
        }
    }

    // MARK: - Navigation Title

    private var navigationTitle: String {
        guard let item = viewModel.selectedItemState?.item,
              item.itemMetadata.itemId == itemId
        else { return String(localized: "Detail") }
        switch item.content {
        case .text: return String(localized: "Text")
        case .link: return String(localized: "Link")
        case .image: return String(localized: "Image")
        case .color: return String(localized: "Color")
        case .file: return String(localized: "File")
        }
    }

    // MARK: - Content

    private func contentView(for item: ClipboardItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                contentSection(for: item)
                Divider()
                metadataSection(for: item)
            }
            .cardSurface()
            .contentShape(.interaction, Rectangle())
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func contentSection(for item: ClipboardItem) -> some View {
        switch item.content {
        case let .text(value):
            textContent(value)
        case let .link(url, metadataState):
            linkContent(url: url, metadataState: metadataState)
        case let .image(data, description, _):
            imageContent(data: data, description: description)
        case let .color(value):
            colorContent(value: value)
        case let .file(_, files):
            fileContent(files: files)
        }
    }

    // MARK: - Text Content

    private func textContent(_ value: String) -> some View {
        Text(value)
            .font(.custom(FontManager.mono, size: 16))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Link Content

    private func linkContent(url: String, metadataState: LinkMetadataState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if case let .loaded(payload) = metadataState {
                linkMetadata(payload: payload)
            }

            Text(url)
                .font(.subheadline)
                .foregroundStyle(.blue)
                .textSelection(.enabled)
                .onTapGesture {
                    if let linkURL = URL(string: url) {
                        UIApplication.shared.open(linkURL)
                    }
                }
        }
    }

    @ViewBuilder
    private func linkMetadata(payload: LinkMetadataPayload) -> some View {
        switch payload {
        case let .titleOnly(title, description):
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                if let description { Text(description).font(.subheadline).foregroundStyle(.secondary) }
            }
        case let .imageOnly(imageData, description):
            VStack(alignment: .leading, spacing: 6) {
                linkImage(data: imageData)
                if let description { Text(description).font(.subheadline).foregroundStyle(.secondary) }
            }
        case let .titleAndImage(title, imageData, description):
            VStack(alignment: .leading, spacing: 6) {
                linkImage(data: imageData)
                Text(title).font(.headline)
                if let description { Text(description).font(.subheadline).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private func linkImage(data: Data) -> some View {
        if let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Image Content

    private func imageContent(data: Data, description: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Color Content

    private func colorContent(value: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 16)
                .fill(color(from: value))
                .frame(height: 200)

            Text(value)
                .font(.custom(FontManager.mono, size: 22))
                .textSelection(.enabled)
        }
    }

    // MARK: - File Content

    private func fileContent(files: [FileEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(files, id: \.filename) { file in
                FileRowView(
                    file: file,
                    windowScene: windowScene,
                    onQuickLook: { quickLookURL = $0 }
                )
            }
        }
        .quickLookPreview($quickLookURL)
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
        if let item = viewModel.selectedItemState?.item,
           item.itemMetadata.itemId == itemId
        {
            GlassEffectContainer(spacing: 20) {
                HStack(spacing: 20) {
                    // Left circle: Share
                    Button {
                        if SharePresenter.canShare(item: item) {
                            SharePresenter.present(
                                item: item,
                                in: windowScene,
                                sourceView: shareAnchorView
                            )
                        } else {
                            sceneState.showToast(.addFailed(String(localized: "Files not available")))
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.medium))
                            .frame(width: 52, height: 52)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .background { ShareAnchorView { shareAnchorView = $0 } }

                    // Center capsule: Bookmark, Edit, Copy
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

                        if case .text = item.content {
                            Button {
                                sceneState.modalRoute = .edit(itemId: itemId)
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.body.weight(.medium))
                                    .frame(width: 52, height: 52)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            container.clipboardService.copy(content: item.content)
                            haptics.fire(.copy)
                            sceneState.showToast(.copied)
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

    // MARK: - Helpers

    private func isBookmarked(_ item: ClipboardItem) -> Bool {
        item.itemMetadata.tags.contains(.bookmark)
    }

    private func toggleBookmark(for item: ClipboardItem) {
        if isBookmarked(item) {
            viewModel.removeTag(.bookmark, fromItem: item.itemMetadata.itemId)
            haptics.fire(.selection)
            sceneState.showToast(.unbookmarked)
        } else {
            viewModel.addTag(.bookmark, toItem: item.itemMetadata.itemId)
            haptics.fire(.selection)
            sceneState.showToast(.bookmarked)
        }
    }
}

// MARK: - File Row (anchored share)

/// A single file entry row that captures its own UIView for share popover anchoring.
private struct FileRowView: View {
    let file: FileEntry
    let windowScene: UIWindowScene?
    let onQuickLook: (URL) -> Void

    @State private var anchorView: UIView?

    private var fileURL: URL { URL(fileURLWithPath: file.path) }
    private var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.filename)
                        .font(.subheadline.weight(.medium))
                    Image(systemName: exists ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(exists ? .green : .red)
                }
                Text(Utilities.formatBytes(Int64(clamping: file.fileSize)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if exists {
                Button {
                    onQuickLook(fileURL)
                } label: {
                    Image(systemName: "eye")
                        .font(.body)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)

                Button {
                    SharePresenter.presentFile(url: fileURL, in: windowScene, sourceView: anchorView)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .background { ShareAnchorView { anchorView = $0 } }
            }
        }
    }
}
