import ClipKittyRust
import ClipKittyShared
import SwiftUI
import UIKit

struct CardView: View {
    let row: DisplayRow
    @Binding var previewItemId: String?

    @Environment(AppContainer.self) private var container
    @Environment(BrowserViewModel.self) private var viewModel
    @Environment(AppState.self) private var appState
    @Environment(HapticsClient.self) private var haptics

    @State private var isShareLoading = false

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var metadata: ItemMetadata {
        row.metadata
    }

    private var displayExcerpt: (text: String, highlights: [Utf16HighlightRange]) {
        switch row.presentation {
        case let .baseline(excerpt):
            return (excerpt.text, [])
        case let .matched(excerpt):
            return (excerpt.text, excerpt.highlights)
        case let .deferred(_, placeholder):
            switch placeholder {
            case let .baseline(excerpt), let .provisional(excerpt):
                return (excerpt.text, [])
            case let .compatibleCached(_, excerpt):
                return (excerpt.text, excerpt.highlights)
            }
        case let .unavailable(fallback, _):
            return (fallback.text, [])
        }
    }

    private var isBookmarked: Bool {
        metadata.tags.contains(.bookmark)
    }

    var body: some View {
        Button {
            viewModel.copyOnlyItem(itemId: metadata.itemId)
            haptics.fire(.copy)
            appState.showToast(.copied)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                metadataLine
                contentPreview
            }
            .cardSurface()
            .padding(.horizontal, 16)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(CardPressButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityCardLabel)
        .accessibilityHint(String(localized: "Double tap to copy"))
        .contextMenu(menuItems: { contextMenuActions }, preview: { cardPeek })
        .onDrag {
            let storeClient = container.storeClient
            return DragItemProvider.make(itemId: metadata.itemId) { id in
                await storeClient.fetchItem(id: id)
            }
        }
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
    private func highlightedText(_ text: String, highlights: [Utf16HighlightRange], font: Font) -> some View {
        if highlights.isEmpty {
            Text(text)
                .font(font)
                .foregroundStyle(.primary)
        } else {
            Text(HighlightAttributedStringBuilder.attributedText(text, highlights: highlights))
                .font(font)
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func symbolContentPreview(iconType: IconType) -> some View {
        switch iconType {
        case .text:
            highlightedText(displayExcerpt.text, highlights: displayExcerpt.highlights, font: .custom(FontManager.mono, size: 15))
                .lineLimit(8)

        case .link:
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                highlightedText(displayExcerpt.text, highlights: displayExcerpt.highlights, font: .custom(FontManager.sansSerif, size: 15))
                    .lineLimit(2)
            }

        case .image:
            HStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                highlightedText(displayExcerpt.text, highlights: displayExcerpt.highlights, font: .custom(FontManager.sansSerif, size: 15))
                    .lineLimit(2)
            }

        case .file:
            // File items are filtered out of the iOS feed
            EmptyView()

        case .color:
            // Fallback for symbol-based color (shouldn't normally hit this path)
            highlightedText(displayExcerpt.text, highlights: displayExcerpt.highlights, font: .custom(FontManager.mono, size: 15))
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

            highlightedText(
                displayExcerpt.highlights.isEmpty ? hexStringFromRGBA(rgba) : displayExcerpt.text,
                highlights: displayExcerpt.highlights,
                font: .custom(FontManager.mono, size: 15)
            )
        }
    }

    @ViewBuilder
    private func thumbnailPreview(bytes: Data) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CardImagePreview(itemId: metadata.itemId, thumbnailBytes: bytes)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if !displayExcerpt.text.isEmpty {
                highlightedText(displayExcerpt.text, highlights: displayExcerpt.highlights, font: .custom(FontManager.sansSerif, size: 15))
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Long-press peek

    /// Expanded preview shown above the context menu; sized close to the card
    /// width so the lift animation doesn't visibly morph.
    @ViewBuilder
    private var cardPeek: some View {
        Group {
            switch metadata.icon {
            case let .symbol(iconType):
                highlightedText(
                    displayExcerpt.text,
                    highlights: displayExcerpt.highlights,
                    font: peekFont(for: iconType)
                )
                .lineLimit(30)
                .padding(16)

            case let .colorSwatch(rgba):
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(colorFromRGBA(rgba))
                        .frame(height: 140)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                        )

                    Text(hexStringFromRGBA(rgba))
                        .font(.custom(FontManager.mono, size: 17))
                }
                .padding(16)

            case let .thumbnail(bytes):
                CardImagePreview(itemId: metadata.itemId, thumbnailBytes: bytes)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(16)
            }
        }
        .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in
            max(length - 32, 0)
        }
    }

    private func peekFont(for iconType: IconType) -> Font {
        switch iconType {
        case .text, .color:
            return .custom(FontManager.mono, size: 15)
        case .link, .image, .file:
            return .custom(FontManager.sansSerif, size: 15)
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
        let preview = displayExcerpt.text.prefix(100)
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
        return Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
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

/// Renders the full-resolution image for a card preview.
///
/// The feed's `ItemMetadata.icon.thumbnail` payload is a ~64px JPEG built for
/// list-row icons; on iPad cards stretch wide enough that scaling that
/// thumbnail produces visibly pixelated marketing screenshots. We instead
/// fetch the original image bytes (via `BrowserStoreClient.fetchItem`) and
/// render those, falling back to the small thumbnail until the load
/// resolves so the card never flashes empty.
private struct CardImagePreview: View {
    let itemId: String
    let thumbnailBytes: Data

    @Environment(AppContainer.self) private var container

    @State private var fullImageBytes: Data?

    var body: some View {
        DecodedImageView(
            namespace: fullImageBytes == nil ? "card-thumbnail" : "card-full",
            itemId: itemId,
            data: fullImageBytes ?? thumbnailBytes
        ) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.secondary.opacity(0.1))
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(
                    Image(systemName: "photo")
                        .font(.title)
                        .foregroundStyle(.secondary)
                )
        }
        .task(id: itemId) {
            guard fullImageBytes == nil else { return }
            let storeClient = container.storeClient
            guard let item = await storeClient.fetchItem(id: itemId) else { return }
            guard !Task.isCancelled else { return }
            if case let .image(data, _, _) = item.content {
                fullImageBytes = data
            }
        }
    }
}
