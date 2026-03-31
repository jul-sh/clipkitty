import ClipKittyRust
import ClipKittyShared
import SwiftUI
import UIKit

struct CardView: View {
    let row: DisplayRow
    @Binding var previewItemId: String?
    @Binding var editItemId: String?

    @Environment(BrowserViewModel.self) private var viewModel
    @Environment(AppState.self) private var appState

    @State private var isShareLoading = false

    private var metadata: ItemMetadata { row.metadata }
    private var isBookmarked: Bool { metadata.tags.contains(.bookmark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            metadataLine
            contentPreview
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityCardLabel)
        .accessibilityHint("Double tap to copy")
        .accessibilityAddTraits(.isButton)
        .onTapGesture {
            viewModel.copyOnlyItem(itemId: metadata.itemId)
            HapticFeedback.copy()
        }
        .contextMenu { contextMenuActions }
    }

    // MARK: - Metadata line

    private var metadataLine: some View {
        HStack(spacing: 6) {
            Image(systemName: iconSymbolName)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(typeLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Text(relativeTime)
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            if isBookmarked {
                Image(systemName: "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Content preview

    @ViewBuilder
    private var contentPreview: some View {
        switch metadata.icon {
        case let .symbol(iconType):
            symbolContentPreview(iconType: iconType)

        case let .colorSwatch(rgba):
            colorSwatchPreview(rgba: rgba)

        case let .thumbnail(bytes):
            thumbnailPreview(bytes: bytes)
        }
    }

    @ViewBuilder
    private func symbolContentPreview(iconType: IconType) -> some View {
        switch iconType {
        case .text:
            Text(metadata.snippet)
                .font(.subheadline.monospaced())
                .lineLimit(8)
                .foregroundStyle(.primary)

        case .link:
            VStack(alignment: .leading, spacing: 4) {
                if let domain = parseDomain(from: metadata.snippet) {
                    Text(domain)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
                }
                Text(metadata.snippet)
                    .font(.subheadline)
                    .lineLimit(3)
                    .foregroundStyle(.primary)
            }

        case .image:
            HStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(metadata.snippet)
                    .font(.subheadline)
                    .lineLimit(3)
                    .foregroundStyle(.primary)
            }

        case .file:
            // File items are filtered out of the iOS feed
            EmptyView()

        case .color:
            // Fallback for symbol-based color (shouldn't normally hit this path)
            Text(metadata.snippet)
                .font(.subheadline.monospaced())
                .foregroundStyle(.primary)
        }
    }

    private func colorSwatchPreview(rgba: UInt32) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorFromRGBA(rgba))
                .frame(width: 40, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                )

            Text(hexStringFromRGBA(rgba))
                .font(.subheadline.monospaced())
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func thumbnailPreview(bytes: Data) -> some View {
        if let uiImage = UIImage(data: bytes) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            HStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(metadata.snippet)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenuActions: some View {
        Button {
            viewModel.copyOnlyItem(itemId: metadata.itemId)
            HapticFeedback.copy()
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        Button {
            previewItemId = metadata.itemId
        } label: {
            Label("Preview", systemImage: "eye")
        }

        if case .symbol(.text) = metadata.icon {
            Button {
                editItemId = metadata.itemId
            } label: {
                Label("Edit", systemImage: "pencil")
            }
        }

        Button {
            if isBookmarked {
                viewModel.removeTag(.bookmark, fromItem: metadata.itemId)
                appState.showToast(.unbookmarked)
            } else {
                viewModel.addTag(.bookmark, toItem: metadata.itemId)
                appState.showToast(.bookmarked)
            }
            HapticFeedback.selection()
        } label: {
            Label(
                isBookmarked ? "Remove Bookmark" : "Bookmark",
                systemImage: isBookmarked ? "bookmark.slash" : "bookmark"
            )
        }

        Button {
            shareItem()
        } label: {
            Label(isShareLoading ? "Loading…" : "Share", systemImage: "square.and.arrow.up")
        }
        .disabled(isShareLoading)

        Button(role: .destructive) {
            viewModel.deleteItem(itemId: metadata.itemId)
            HapticFeedback.destructive()
            appState.showToast(.deleted)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Share

    private func shareItem() {
        isShareLoading = true
        Task {
            defer { isShareLoading = false }
            guard let item = await appState.storeClient.fetchItem(id: metadata.itemId) else { return }
            SharePresenter.present(item: item)
        }
    }

    // MARK: - Helpers

    private var accessibilityCardLabel: String {
        var parts = [typeLabel]
        if isBookmarked { parts.append("bookmarked") }
        let preview = metadata.snippet.prefix(100)
        if !preview.isEmpty { parts.append(String(preview)) }
        parts.append(relativeTime)
        return parts.joined(separator: ", ")
    }

    private var iconSymbolName: String {
        switch metadata.icon {
        case let .symbol(iconType):
            return iconType.sfSymbolName
        case .colorSwatch:
            return "paintpalette"
        case .thumbnail:
            return "photo"
        }
    }

    private var typeLabel: String {
        switch metadata.icon {
        case let .symbol(iconType):
            switch iconType {
            case .text: return "Text"
            case .link: return "Link"
            case .image: return "Image"
            case .color: return "Color"
            case .file: return "File" // Filtered out of iOS feed
            }
        case .colorSwatch:
            return "Color"
        case .thumbnail:
            return "Image"
        }
    }

    private var relativeTime: String {
        let date = Date(timeIntervalSince1970: TimeInterval(metadata.timestampUnix))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func parseDomain(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host
        else { return nil }
        return host
    }

    private func colorFromRGBA(_ rgba: UInt32) -> Color {
        let r = Double((rgba >> 24) & 0xFF) / 255.0
        let g = Double((rgba >> 16) & 0xFF) / 255.0
        let b = Double((rgba >> 8) & 0xFF) / 255.0
        let a = Double(rgba & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b, opacity: a)
    }

    private func hexStringFromRGBA(_ rgba: UInt32) -> String {
        let r = (rgba >> 24) & 0xFF
        let g = (rgba >> 16) & 0xFF
        let b = (rgba >> 8) & 0xFF
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
