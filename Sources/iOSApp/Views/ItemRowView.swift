import ClipKittyRust
import SwiftUI

struct ItemRowView: View {
    let metadata: ItemMetadata
    let decoration: RowDecoration?
    let searchQuery: String

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail / icon (only for images and colors)
            thumbnailView

            VStack(alignment: .leading, spacing: 4) {
                // Top line: content type + time ago
                HStack(spacing: 0) {
                    Text(contentTypeLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)

                    Text("  ")

                    Text(timeAgo(from: metadata.timestampUnix))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 4)

                    // Source app badge
                    if metadata.tags.contains(.bookmark) {
                        Image(systemName: "bookmark.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if let bundleId = metadata.sourceAppBundleId,
                       !bundleId.isEmpty
                    {
                        sourceAppBadge(bundleId: bundleId)
                    }
                }

                // Content preview
                displayText
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Content Type

    private var contentTypeLabel: String {
        switch metadata.icon {
        case .thumbnail: return "Image"
        case .colorSwatch: return "Color"
        case let .symbol(iconType):
            switch iconType {
            case .text: return "Text"
            case .link: return "Link"
            case .image: return "Image"
            case .color: return "Color"
            case .file: return "File"
            }
        }
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnailView: some View {
        switch metadata.icon {
        case let .thumbnail(bytes):
            if let uiImage = UIImage(data: Data(bytes)) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

        case let .colorSwatch(rgba):
            RoundedRectangle(cornerRadius: 6)
                .fill(colorFromRGBA(rgba))
                .frame(width: 40, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                )

        case .symbol:
            EmptyView()
        }
    }

    // MARK: - Source App Badge

    @ViewBuilder
    private func sourceAppBadge(bundleId: String) -> some View {
        let icon = sourceAppIcon(bundleId: bundleId)
        if let icon {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func sourceAppIcon(bundleId: String) -> String? {
        FormattingHelpers.sourceAppIcon(bundleId: bundleId)
    }

    // MARK: - Display Text

    @ViewBuilder
    private var displayText: some View {
        if let decoration {
            highlightedText(decoration)
        } else {
            Text(metadata.snippet)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func highlightedText(_ decoration: RowDecoration) -> some View {
        let text = decoration.text
        let highlights = decoration.highlights

        if highlights.isEmpty {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            let attributed = buildHighlightedString(
                text: text,
                highlights: highlights
            )
            Text(attributed)
                .font(.subheadline)
        }
    }

    private func buildHighlightedString(
        text: String,
        highlights: [Utf16HighlightRange]
    ) -> AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = .secondary

        for highlight in highlights {
            let start = Int(highlight.utf16Start)
            let end = Int(highlight.utf16End)

            guard start < end,
                  let startIndex = text.utf16.index(
                    text.utf16.startIndex,
                    offsetBy: start,
                    limitedBy: text.utf16.endIndex
                  ),
                  let endIndex = text.utf16.index(
                    text.utf16.startIndex,
                    offsetBy: end,
                    limitedBy: text.utf16.endIndex
                  ),
                  let rangeStart = String.Index(startIndex, within: text),
                  let rangeEnd = String.Index(endIndex, within: text)
            else {
                continue
            }

            let range = rangeStart ..< rangeEnd
            guard let attrRange = Range(range, in: result) else { continue }

            result[attrRange].foregroundColor = .primary
            result[attrRange].font = .subheadline.bold()
        }

        return result
    }

    // MARK: - Helpers

    private func colorFromRGBA(_ rgba: UInt32) -> Color {
        let c = FormattingHelpers.colorFromRGBA(rgba)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    private func timeAgo(from timestampUnix: Int64) -> String {
        FormattingHelpers.timeAgo(from: timestampUnix)
    }
}
