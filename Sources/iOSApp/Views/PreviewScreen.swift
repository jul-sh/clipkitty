import ClipKittyRust
import ClipKittyShared
import SwiftUI
import UIKit

struct PreviewScreen: View {
    let itemId: String

    @Environment(BrowserViewModel.self) private var viewModel
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirmation = false
    @State private var showEditSheet = false

    var body: some View {
        Group {
            if let selectedItemState = viewModel.selectedItemState {
                contentView(for: selectedItemState.item)
            } else {
                ProgressView("Loading...")
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .alert("Delete Item", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                viewModel.deleteItem(itemId: itemId)
                HapticFeedback.destructive()
                appState.showToast(.deleted)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this item? This cannot be undone.")
        }
        .sheet(isPresented: $showEditSheet) {
            if let item = viewModel.selectedItemState?.item,
               case let .text(value) = item.content {
                EditView(itemId: itemId)
            }
        }
        .onAppear {
            viewModel.select(itemId: itemId, origin: .user)
        }
    }

    // MARK: - Navigation Title

    private var navigationTitle: String {
        guard let item = viewModel.selectedItemState?.item else { return "Detail" }
        switch item.content {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .color: return "Color"
        case .file: return "File"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func contentView(for item: ClipboardItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                contentSection(for: item)
                Divider()
                metadataSection(for: item)
            }
            .padding()
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
        case .file:
            Text("File items are not supported on iPhone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Text Content

    @ViewBuilder
    private func textContent(_ value: String) -> some View {
        Text(value)
            .font(.custom(FontManager.mono, size: 16))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Link Content

    @ViewBuilder
    private func linkContent(url: String, metadataState: LinkMetadataState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if case let .loaded(payload) = metadataState {
                linkMetadata(payload: payload)
            }

            if let linkURL = URL(string: url) {
                Link(destination: linkURL) {
                    HStack {
                        Image(systemName: "safari")
                        Text(url)
                            .lineLimit(2)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                }
            } else {
                Text(url)
                    .font(.subheadline)
                    .textSelection(.enabled)
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

    @ViewBuilder
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

    @ViewBuilder
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

    @ViewBuilder
    private func metadataSection(for item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details")
                .font(.headline)

            LabeledContent("Type", value: navigationTitle)

            if let sourceApp = item.itemMetadata.sourceApp {
                LabeledContent("Source", value: sourceApp)
            }

            LabeledContent("Time") {
                Text(formattedDate(from: item.itemMetadata.timestampUnix))
            }

            LabeledContent("Bookmarked") {
                Text(isBookmarked(item) ? "Yes" : "No")
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                guard let item = viewModel.selectedItemState?.item else { return }
                appState.clipboardService.copy(content: item.content)
                HapticFeedback.copy()
                appState.showToast(.copied)
            } label: {
                Image(systemName: "doc.on.doc")
            }

            if let item = viewModel.selectedItemState?.item, case .text = item.content {
                Button {
                    showEditSheet = true
                } label: {
                    Image(systemName: "pencil")
                }
            }
        }

        ToolbarItemGroup(placement: .secondaryAction) {
            if let item = viewModel.selectedItemState?.item {
                Button {
                    toggleBookmark(for: item)
                } label: {
                    Label(
                        isBookmarked(item) ? "Remove Bookmark" : "Bookmark",
                        systemImage: isBookmarked(item) ? "bookmark.slash" : "bookmark"
                    )
                }

                Button {
                    SharePresenter.present(item: item)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
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
            HapticFeedback.selection()
            appState.showToast(.unbookmarked)
        } else {
            viewModel.addTag(.bookmark, toItem: item.itemMetadata.itemId)
            HapticFeedback.selection()
            appState.showToast(.bookmarked)
        }
    }

}
