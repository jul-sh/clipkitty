import AppKit
import ClipKittyRust
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Item Row

@MainActor
private enum RowIconCache {
    private static let workspace = NSWorkspace.shared
    private static let browserIcon: NSImage = {
        if let browserURL = URL(string: "https://").flatMap({ workspace.urlForApplication(toOpen: $0) }) {
            return workspace.icon(forFile: browserURL.path)
        }
        return workspace.icon(for: IconType.link.utType)
    }()

    private static let finderIcon: NSImage = {
        if let finderURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            return workspace.icon(forFile: finderURL.path)
        }
        return workspace.icon(for: IconType.file.utType)
    }()

    private static var symbolIcons: [IconType: NSImage] = [:]
    private static var sourceAppIcons: [String: NSImage] = [:]
    private static var missingSourceAppBundleIDs: Set<String> = []

    static func symbolImage(for iconType: IconType) -> NSImage {
        if let cachedImage = symbolIcons[iconType] {
            return cachedImage
        }

        let image: NSImage
        switch iconType {
        case .link:
            image = browserIcon
        case .file:
            image = finderIcon
        case .text, .image, .color:
            image = workspace.icon(for: iconType.utType)
        }

        symbolIcons[iconType] = image
        return image
    }

    static func sourceAppImage(bundleID: String) -> NSImage? {
        if let cachedImage = sourceAppIcons[bundleID] {
            return cachedImage
        }
        if missingSourceAppBundleIDs.contains(bundleID) {
            return nil
        }
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
            missingSourceAppBundleIDs.insert(bundleID)
            return nil
        }

        let image = workspace.icon(forFile: appURL.path)
        sourceAppIcons[bundleID] = image
        return image
    }
}

private enum RowThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    static func key(itemId: String, data: Data) -> String {
        var hasher = Hasher()
        hasher.combine(itemId)
        hasher.combine(data.count)
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for byte in bytes.prefix(16) {
                hasher.combine(byte)
            }
            if bytes.count > 16 {
                for byte in bytes.suffix(16) {
                    hasher.combine(byte)
                }
            }
        }
        return "\(itemId)-\(data.count)-\(hasher.finalize())"
    }

    static func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    static func setImage(_ image: NSImage, forKey key: String, cost: Int) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

private struct RowThumbnailView: View {
    let itemId: String
    let data: Data

    @State private var decodedImage: NSImage?

    private var cacheKey: String {
        RowThumbnailCache.key(itemId: itemId, data: data)
    }

    var body: some View {
        Group {
            if let image = decodedImage ?? RowThumbnailCache.image(forKey: cacheKey) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .resizable()
            }
        }
        .task(id: cacheKey) {
            await decodeImage(cacheKey: cacheKey, data: data)
        }
    }

    @MainActor
    private func decodeImage(cacheKey: String, data: Data) async {
        if let cachedImage = RowThumbnailCache.image(forKey: cacheKey) {
            decodedImage = cachedImage
            return
        }

        decodedImage = nil
        let image = await Task.detached(priority: .utility) { [data] in
            NSImage(data: data)
        }.value
        guard !Task.isCancelled, let image else { return }
        RowThumbnailCache.setImage(image, forKey: cacheKey, cost: data.count)
        decodedImage = image
    }
}

struct ItemRow: View {
    let metadata: ItemMetadata
    let presentation: RowPresentation
    let isSelected: Bool
    let isContextMenuTargeted: Bool
    let hasUserNavigated: Bool
    let hasPendingEdit: Bool
    let onTap: () -> Void
    let contextMenuActions: [BrowserActionItem]
    let onContextMenuAction: (BrowserActionItem) -> Void
    let onContextMenuDelete: () -> Void
    let onContextMenuShow: () -> Void
    let onContextMenuHide: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var runtimeState = AppRuntimeState.shared

    private var accentSelected: Bool {
        isSelected && hasUserNavigated && !hasPendingEdit
    }

    /// Height for exactly 1 line of text, scaled with text size setting
    private var rowHeight: CGFloat {
        runtimeState.scaled(32)
    }

    // MARK: - Display Text (Simplified - SwiftUI handles truncation)

    private var displayExcerpt: (text: String, highlights: [Utf16HighlightRange], lineNumber: UInt64?) {
        switch presentation {
        case let .baseline(excerpt):
            return (excerpt.text, [], nil)
        case let .matched(excerpt):
            return (excerpt.text, excerpt.highlights, excerpt.lineNumber)
        case let .deferred(_, placeholder):
            switch placeholder {
            case let .baseline(excerpt), let .provisional(excerpt):
                return (excerpt.text, [], nil)
            case let .compatibleCached(_, excerpt):
                return (excerpt.text, excerpt.highlights, excerpt.lineNumber)
            }
        case let .unavailable(fallback, _):
            return (fallback.text, [], nil)
        }
    }

    private var showsSourceAppBadge: Bool {
        switch metadata.icon {
        case let .symbol(iconType):
            return iconType != .link && iconType != .file
        case .thumbnail, .colorSwatch:
            return true
        }
    }

    private var lineNumberFont: Font {
        switch settings.fontPreference {
        case .iosevkaCharon:
            return settings.previewFont(size: 13)
        case .system:
            return settings.appFont(size: 13)
        }
    }

    var body: some View {
        // 1. Wrap the content inside a Button
        Button(action: onTap) {
            HStack(spacing: 6) {
                // Content type icon with badge overlay (or pencil when editing)
                Group {
                    if hasPendingEdit {
                        // Show pencil emoji when item has pending edit
                        Text("✏️")
                            .font(.system(size: runtimeState.scaled(24)))
                            .frame(width: runtimeState.scaled(32), height: runtimeState.scaled(32))
                    } else {
                        ZStack(alignment: .bottomTrailing) {
                            // Main icon: image thumbnail, browser icon for links, color swatch, or SF symbol
                            Group {
                                switch metadata.icon {
                                case let .thumbnail(bytes):
                                    RowThumbnailView(itemId: metadata.itemId, data: bytes)
                                case let .colorSwatch(rgba):
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color(nsColor: NSColor(
                                            red: CGFloat((rgba >> 24) & 0xFF) / 255.0,
                                            green: CGFloat((rgba >> 16) & 0xFF) / 255.0,
                                            blue: CGFloat((rgba >> 8) & 0xFF) / 255.0,
                                            alpha: CGFloat(rgba & 0xFF) / 255.0
                                        )))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                                        )
                                case let .symbol(iconType):
                                    Image(nsImage: RowIconCache.symbolImage(for: iconType))
                                        .resizable()
                                }
                            }
                            .frame(width: runtimeState.scaled(32), height: runtimeState.scaled(32))
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                            // Badge: Bookmark icon for bookmarked items, otherwise source app icon
                            if metadata.tags.contains(.bookmark) {
                                Image("BookmarkIcon")
                                    .resizable()
                                    .frame(width: 18, height: 18)
                                    .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                                    .offset(x: 4, y: 4)
                                    .transition(.scale.combined(with: .opacity))
                            } else if let bundleID = metadata.sourceAppBundleId,
                                      let sourceAppImage = RowIconCache.sourceAppImage(bundleID: bundleID)
                            {
                                if showsSourceAppBadge {
                                    Image(nsImage: sourceAppImage)
                                        .resizable()
                                        .frame(width: 22, height: 22)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                        .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                                        .offset(x: 4, y: 4)
                                }
                            }
                        }
                    }
                }
                .frame(width: runtimeState.scaled(38), height: runtimeState.scaled(38))
                .allowsHitTesting(false)

                // Line number (shown in search mode when line > 1)
                if let lineNumber = displayExcerpt.lineNumber, lineNumber > 1 {
                    Text("L\(lineNumber):")
                        .font(lineNumberFont)
                        .foregroundColor(accentSelected ? .white.opacity(0.7) : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .allowsHitTesting(false)
                }

                // Text content - SwiftUI Three-Part HStack with layout priorities
                HStack(spacing: 6) {
                    HighlightedTextView(
                        text: displayExcerpt.text,
                        highlights: displayExcerpt.highlights,
                        accentSelected: accentSelected,
                        textScale: runtimeState.textScale,
                        fontPreference: settings.fontPreference
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
                    .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background {
                if isSelected && hasUserNavigated && hasPendingEdit {
                    // Editing state: darker grey background
                    Color.primary.opacity(0.35)
                } else if accentSelected {
                    Color.selectionBackground
                } else if isContextMenuTargeted && !isSelected {
                    Color.primary.opacity(0.11)
                } else if isSelected {
                    Color.primary.opacity(0.225)
                } else {
                    Color.clear
                }
            }
            .overlay {
                if isContextMenuTargeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
                }
            }
            // Each keyed to its own state so selection changes stay instant:
            // the pencil/background crossfade on entering edit mode, the
            // context-target ring/fill fade, and the bookmark badge pop.
            .animation(.easeInOut(duration: 0.15), value: hasPendingEdit)
            .animation(.easeOut(duration: 0.12), value: isContextMenuTargeted)
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: metadata.tags.contains(.bookmark))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        // 2. Apply the plain style so it behaves like a standard row instead of a system button
        .buttonStyle(.plain)
        .overlay {
            RightClickPopoverOverlay(
                actions: contextMenuActions,
                onShow: onContextMenuShow,
                onHide: onContextMenuHide,
                onAction: onContextMenuAction,
                onConfirmDelete: onContextMenuDelete
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayExcerpt.text)
        .accessibilityHint(AppRuntimeState.shared.pasteMode == .autoPaste ? String(localized: "Double tap to paste") : String(localized: "Double tap to copy"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
