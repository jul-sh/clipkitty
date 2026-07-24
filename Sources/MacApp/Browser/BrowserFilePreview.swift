import AppKit
import ClipKittyCore
import ClipKittyRust
import SwiftUI

// MARK: - Subtle Hover Effect

/// A view modifier that adds a subtle animated hover background effect.
/// Use on button labels to provide visual feedback on hover.
struct SubtleHoverEffect: ViewModifier {
    let cornerRadius: CGFloat
    @State private var isHovered = false

    init(cornerRadius: CGFloat = 9) {
        self.cornerRadius = cornerRadius
    }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

extension View {
    /// Adds a subtle hover background effect with rounded corners.
    func subtleHover(cornerRadius: CGFloat = 9) -> some View {
        modifier(SubtleHoverEffect(cornerRadius: cornerRadius))
    }
}

// MARK: - File Preview

@MainActor
private enum FilePreviewIconCache {
    private static let icons: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    static func icon(forFile path: String) -> NSImage {
        if let icon = icons.object(forKey: path as NSString) {
            return icon
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons.setObject(icon, forKey: path as NSString)
        return icon
    }
}

@MainActor
private enum FileTextPreviewHighlightCache {
    private static var highlightsByKey: [String: [Utf16HighlightRange]] = [:]

    static func highlights(
        forPreviewId previewId: String,
        sample: String,
        queryWords: [String]
    ) -> [Utf16HighlightRange] {
        guard !queryWords.isEmpty else { return [] }

        let key = "\(previewId)|\(sample.utf16.count)|\(queryWords.joined(separator: "\u{1F}"))"
        if let cached = highlightsByKey[key] {
            return cached
        }

        let highlights = HighlightStyler.exactHighlights(in: sample, queryWords: queryWords)
        highlightsByKey[key] = highlights
        return highlights
    }
}

private final class FilePreviewImageCache {
    static let shared = FilePreviewImageCache()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 32
        return cache
    }()

    func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: NSImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

private struct FilePreviewImageView<Fallback: View>: View {
    private enum DecodeState {
        case loading
        case decoded(NSImage)
        case failed
    }

    let cacheKey: String
    let previewData: Data
    let fallback: () -> Fallback

    @State private var decodeState: DecodeState = .loading

    var body: some View {
        Group {
            switch decodeState {
            case .loading:
                ProgressView()
            case let .decoded(image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
            case .failed:
                fallback()
            }
        }
        .task(id: cacheKey) {
            if let cached = FilePreviewImageCache.shared.image(forKey: cacheKey) {
                decodeState = .decoded(cached)
                return
            }

            decodeState = .loading
            let decoded = await Task.detached(priority: .userInitiated) { [previewData] in
                NSImage(data: previewData)
            }.value
            guard !Task.isCancelled else { return }
            guard let decoded else {
                decodeState = .failed
                return
            }
            FilePreviewImageCache.shared.setImage(decoded, forKey: cacheKey)
            decodeState = .decoded(decoded)
        }
    }
}

struct FilePreviewView: View {
    let itemId: String
    let files: [FileEntry]
    var searchQuery: String = ""

    @ObservedObject private var settings = AppSettings.shared

    /// Query words for highlighting (lowercased, non-empty)
    private var queryWords: [String] {
        searchQuery.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    var body: some View {
        if let previewFile {
            switch previewFile.preview {
            case let .text(text):
                fileTextPreview(file: previewFile, text: text)
            case let .image(previewData):
                fileImagePreview(file: previewFile, previewData: previewData)
            case .unavailable:
                fileList
            }
        } else {
            fileList
        }
    }

    private var previewFile: FileEntry? {
        for file in files {
            switch file.preview {
            case .text, .image:
                return file
            case .unavailable:
                continue
            }
        }
        return nil
    }

    private var fileList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                ForEach(Array(files.enumerated()), id: \.offset) { offset, file in
                    fileRow(file)
                    if offset != files.indices.last {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewHeader(file: FileEntry) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: FilePreviewIconCache.icon(forFile: file.path))
                .resizable()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                highlightedFileText(file.filename, font: .system(size: 13, weight: .medium), color: .primary)
                    .lineLimit(1)
                highlightedFileText(file.path, font: .system(size: 11), color: .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.035))
    }

    private func fileTextPreview(file: FileEntry, text: FileTextPreviewSnapshot) -> some View {
        let sample: String
        switch text {
        case let .complete(value):
            sample = value
        case let .truncated(value):
            sample = value
        }

        let previewId = "\(itemId):\(file.path)"
        let highlights = FileTextPreviewHighlightCache.highlights(
            forPreviewId: previewId,
            sample: sample,
            queryWords: queryWords
        )
        let _ = { TextPreviewView.textCache[previewId] = sample }()

        return VStack(spacing: 0) {
            previewHeader(file: file)
            Divider()
            TextPreviewView(
                itemId: previewId,
                fontName: settings.previewFontName,
                fontSize: settings.previewFontSize(12),
                highlights: highlights,
                scrollBehavior: .autoScroll,
                interaction: .readOnly
            )
            switch text {
            case .complete:
                EmptyView()
            case .truncated:
                Divider()
                Text("Preview truncated")
                    .font(settings.appFont(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.035))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileImagePreview(file: FileEntry, previewData: Data) -> some View {
        VStack(spacing: 0) {
            previewHeader(file: file)
            Divider()
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.04)
                FilePreviewImageView(
                    cacheKey: "\(itemId):\(file.path):\(previewData.count)",
                    previewData: previewData
                ) {
                    fileList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileRow(_ file: FileEntry) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: FilePreviewIconCache.icon(forFile: file.path))
                .resizable()
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                highlightedFileText(file.filename, font: .system(size: 14, weight: .medium), color: .primary)
                    .lineLimit(1)

                highlightedFileText(file.path, font: .system(size: 11), color: .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if file.fileSize > 0 {
                    Text(Utilities.formatBytes(Int64(file.fileSize)))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Highlight query word matches in file text
    private func highlightedFileText(_ text: String, font: Font, color: Color) -> Text {
        let highlights = HighlightStyler.exactHighlights(in: text, queryWords: queryWords)
        guard !highlights.isEmpty else {
            return Text(text).font(font).foregroundColor(color)
        }

        return Text(HighlightStyler.attributedText(text, highlights: highlights))
            .font(font)
            .foregroundColor(color)
    }
}
