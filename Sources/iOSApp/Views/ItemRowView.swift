import ClipKittyRust
import SwiftUI

struct ItemRowView: View {
    let metadata: ItemMetadata
    let decoration: RowDecoration?
    let searchQuery: String

    var body: some View {
        HStack(spacing: 12) {
            iconView
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                displayText
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if metadata.tags.contains(.bookmark) {
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    Text(timeAgo(from: metadata.timestampUnix))
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    if let bundleId = metadata.sourceAppBundleId,
                       !bundleId.isEmpty
                    {
                        Text(appName(from: bundleId))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Icon

    @ViewBuilder
    private var iconView: some View {
        switch metadata.icon {
        case let .thumbnail(bytes):
            if let uiImage = UIImage(data: Data(bytes)) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                fallbackIcon
            }

        case let .colorSwatch(rgba):
            let color = colorFromRGBA(rgba)
            RoundedRectangle(cornerRadius: 6)
                .fill(color)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                )

        case let .symbol(iconType):
            Image(systemName: sfSymbolName(for: iconType))
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var fallbackIcon: some View {
        Image(systemName: "doc")
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 36)
            .background(Color(.tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Display Text

    @ViewBuilder
    private var displayText: some View {
        if let decoration {
            highlightedText(decoration)
        } else {
            Text(metadata.snippet)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func highlightedText(_ decoration: RowDecoration) -> some View {
        let text = decoration.text
        let highlights = decoration.highlights

        if highlights.isEmpty {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
        } else {
            // Build an attributed string with highlights
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

            result[attrRange].foregroundColor = .accentColor
            result[attrRange].font = .subheadline.bold()
        }

        return result
    }

    // MARK: - Helpers

    private func sfSymbolName(for iconType: IconType) -> String {
        switch iconType {
        case .text: return "doc.text"
        case .link: return "link"
        case .image: return "photo"
        case .color: return "paintpalette"
        case .file: return "folder"
        }
    }

    private func colorFromRGBA(_ rgba: UInt32) -> Color {
        let r = Double((rgba >> 24) & 0xFF) / 255.0
        let g = Double((rgba >> 16) & 0xFF) / 255.0
        let b = Double((rgba >> 8) & 0xFF) / 255.0
        let a = Double(rgba & 0xFF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    private func timeAgo(from timestampUnix: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestampUnix))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func appName(from bundleId: String) -> String {
        let components = bundleId.split(separator: ".")
        if let last = components.last {
            return String(last)
        }
        return bundleId
    }
}
