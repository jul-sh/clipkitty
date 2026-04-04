import ClipKittyRust
import ClipKittyShared
import SwiftUI
import UIKit

struct CardView: View {
    let row: DisplayRow
    @Binding var previewItemId: String?
    @Binding var editItemId: String?

    @Environment(AppContainer.self) private var container
    @Environment(BrowserViewModel.self) private var viewModel
    @Environment(AppState.self) private var appState
    @Environment(HapticsClient.self) private var haptics

    @State private var isShareLoading = false

    private var metadata: ItemMetadata {
        row.metadata
    }

    /// Display text matching Mac semantics: prefer listDecoration text, fall back to snippet
    private var displayText: String {
        if let rowText = row.listDecoration?.text, !rowText.isEmpty {
            return rowText
        }
        return metadata.snippet
    }

    private var isBookmarked: Bool {
        metadata.tags.contains(.bookmark)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            metadataLine
            contentPreview
        }
        .cardSurface()
        .padding(.horizontal, 16)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityCardLabel)
        .accessibilityHint(String(localized: "Double tap to copy"))
        .accessibilityAddTraits(.isButton)
        .onTapGesture {
            viewModel.copyOnlyItem(itemId: metadata.itemId)
            haptics.fire(.copy)
            appState.showToast(.copied)
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
            Text(displayText)
                .font(.custom(FontManager.mono, size: 15))
                .lineLimit(8)
                .foregroundStyle(.primary)

        case .link:
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(displayText)
                    .font(.custom(FontManager.sansSerif, size: 15))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }

        case .image:
            HStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(displayText)
                    .font(.custom(FontManager.sansSerif, size: 15))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }

        case .file:
            // File items are filtered out of the iOS feed
            EmptyView()

        case .color:
            // Fallback for symbol-based color (shouldn't normally hit this path)
            Text(displayText)
                .font(.custom(FontManager.mono, size: 15))
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
                .font(.custom(FontManager.mono, size: 15))
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func thumbnailPreview(bytes: Data) -> some View {
        HStack(spacing: 8) {
            if let uiImage = UIImage(data: bytes) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
            }
            Text(displayText)
                .font(.custom(FontManager.sansSerif, size: 15))
                .lineLimit(2)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenuActions: some View {
        Button {
            viewModel.copyOnlyItem(itemId: metadata.itemId)
            haptics.fire(.copy)
            appState.showToast(.copied)
        } label: {
            Label(String(localized: "Copy"), systemImage: "doc.on.doc")
        }

        Button {
            previewItemId = metadata.itemId
        } label: {
            Label(String(localized: "Preview"), systemImage: "eye")
        }

        if case .symbol(.text) = metadata.icon {
            Button {
                editItemId = metadata.itemId
            } label: {
                Label(String(localized: "Edit"), systemImage: "pencil")
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
            haptics.fire(.selection)
        } label: {
            Label(
                isBookmarked ? String(localized: "Remove Bookmark") : String(localized: "Bookmark"),
                systemImage: isBookmarked ? "bookmark.slash" : "bookmark"
            )
        }

        Button {
            shareItem()
        } label: {
            Label(isShareLoading ? String(localized: "Loading…") : String(localized: "Share"), systemImage: "square.and.arrow.up")
        }
        .disabled(isShareLoading)

        Button(role: .destructive) {
            viewModel.deleteItem(itemId: metadata.itemId)
            haptics.fire(.destructive)
        } label: {
            Label(String(localized: "Delete"), systemImage: "trash")
        }
    }

    // MARK: - Share

    private func shareItem() {
        isShareLoading = true
        Task {
            defer { isShareLoading = false }
            guard let item = await container.storeClient.fetchItem(id: metadata.itemId) else {
                appState.showToast(.addFailed(String(localized: "Could not load item")))
                return
            }
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
            case .text: return String(localized: "Text")
            case .link: return String(localized: "Link")
            case .image: return String(localized: "Image")
            case .color: return String(localized: "Color")
            case .file: return String(localized: "File")
            }
        case .colorSwatch:
            return String(localized: "Color")
        case .thumbnail:
            return String(localized: "Image")
        }
    }

    private var relativeTime: String {
        let date = Date(timeIntervalSince1970: TimeInterval(metadata.timestampUnix))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
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
