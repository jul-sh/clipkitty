import SwiftUI
import AppKit
import ClipKittyRust
import STTextKitPlus
import os.log
import UniformTypeIdentifiers

/// Max time to show stale content before clearing to spinner during slow loads.
/// Used for both preview item loading and search result loading.
private let staleContentTimeout: Duration = .milliseconds(150)

private enum SpinnerState: Equatable {
    case idle
    case debouncing(task: Task<Void, Never>)
    case visible

    static func == (lhs: SpinnerState, rhs: SpinnerState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.visible, .visible), (.debouncing, .debouncing):
            return true
        default:
            return false
        }
    }

    mutating func cancel() {
        if case .debouncing(let task) = self {
            task.cancel()
        }
        self = .idle
    }
}

private enum FilterPopoverState: Equatable {
    case hidden
    case visible(highlightedIndex: Int)
}

private enum ActionsPopoverState: Equatable {
    case hidden
    case showingActions(highlightedIndex: Int)
    case showingDeleteConfirm(highlightedIndex: Int)
}

private extension View {
    @ViewBuilder
    func clipKittyGlassBackground() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .rect)
        } else {
            self.background(.regularMaterial)
        }
    }
}

// MARK: - File Preview

struct FilePreviewView: View {
    let files: [FileEntry]
    var searchQuery: String = ""

    /// Query words for highlighting (lowercased, non-empty)
    private var queryWords: [String] {
        searchQuery.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                    fileRow(file)
                    if file.fileItemId != files.last?.fileItemId {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileRow(_ file: FileEntry) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
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

// MARK: - Text Preview (AppKit)

struct TextPreviewView: NSViewRepresentable {
    let text: String
    let fontName: String
    let fontSize: CGFloat
    var highlights: [HighlightRange] = []
    var densestHighlightStart: UInt64 = 0

    private enum ScrollTarget {
        case top
        case highlight(NSRange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        // NSTextView() defaults to TextKit 2 on macOS 12+.
        // IMPORTANT: never access .layoutManager — that silently downgrades to TextKit 1.
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: 0)
        textView.setAccessibilityIdentifier("PreviewTextView")

        scrollView.documentView = textView
        return scrollView
    }

    /// Last known container width, persisted across view recreations so the
    /// first render already uses a good value instead of falling back to base font.
    private static var lastKnownContainerWidth: CGFloat = 0

    private func scaledFontSize(containerWidth: CGFloat) -> CGFloat {
        let lines = text.components(separatedBy: "\n")
        if lines.count >= 10 { return fontSize }

        let baseFont = NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let inset: CGFloat = 32 + 10 // textContainerInset.width * 2 + lineFragmentPadding * 2
        let availableWidth = containerWidth - inset
        if availableWidth <= 0 { return fontSize }

        let attributes: [NSAttributedString.Key: Any] = [.font: baseFont]
        var maxLineWidth: CGFloat = 0
        for line in lines {
            let lineWidth = (line as NSString).size(withAttributes: attributes).width
            if lineWidth >= availableWidth { return fontSize }
            maxLineWidth = max(maxLineWidth, lineWidth)
        }
        if maxLineWidth <= 0 { return fontSize }

        let scale = min(1.5, availableWidth / maxLineWidth) * 0.95
        return fontSize * scale
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        // Use live container width if available, otherwise fall back to persisted value
        let containerWidth = nsView.contentSize.width > 0
            ? nsView.contentSize.width
            : Self.lastKnownContainerWidth
        if nsView.contentSize.width > 0 {
            Self.lastKnownContainerWidth = nsView.contentSize.width
        }

        let scaledSize = scaledFontSize(containerWidth: containerWidth)
        let font = NSFont(name: fontName, size: scaledSize)
            ?? NSFont.monospacedSystemFont(ofSize: scaledSize, weight: .regular)

        // Settle container dimensions FIRST so that any deferred scroll
        // computes geometry against the correct width.
        textView.textContainer?.containerSize = NSSize(
            width: containerWidth,
            height: .greatestFiniteMagnitude
        )
        textView.frame = NSRect(x: 0, y: 0, width: containerWidth, height: textView.frame.height)

        let coordinator = context.coordinator
        let textChanged = textView.string != text
        let highlightsChanged = coordinator.lastHighlights != highlights
        let contentWidthChanged = abs(coordinator.lastContentWidth - containerWidth) > 0.5
        coordinator.lastContentWidth = containerWidth

        guard textChanged || highlightsChanged || contentWidthChanged else { return }
        if textChanged || contentWidthChanged {
            coordinator.needsGeometrySync = true
        }

        if textChanged {
            // Text content changed — replace storage attributes (font, color, paragraph style only).
            // Highlights are applied as rendering attributes, not storage attributes.
            //
            // Memory consideration: For very large text (>100KB), NSAttributedString allocation
            // can be expensive. TextKit 2 handles large documents efficiently via lazy layout,
            // but the initial attributed string creation is still proportional to text size.
            // Consider implementing a size limit or truncation if clipboard items exceed ~1MB.
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping

            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ])

            textView.textStorage?.setAttributedString(attributed)
        }

        let tlm = textView.textLayoutManager
        if textChanged || highlightsChanged {
            // Convert highlights to NSTextRanges for the layout manager
            let newMatchRanges = resolveTextRanges(highlights: highlights, text: text, layoutManager: tlm)
            let oldMatchRanges = coordinator.currentMatchRanges

            coordinator.currentMatchRanges = newMatchRanges
            coordinator.lastHighlights = highlights

            if let tlm {
                if textChanged {
                    // Full text replacement — apply all new highlights from scratch
                    for match in newMatchRanges {
                        tlm.setRenderingAttributes(
                            HighlightStyler.renderingAttributes(for: match.kind),
                            for: match.range
                        )
                    }
                } else {
                    // Only highlights changed — diff and invalidate minimally.
                    // Remove old rendering attributes for ranges no longer highlighted
                    let newSet = Set(newMatchRanges.map { MatchRangeKey($0) })
                    for old in oldMatchRanges where !newSet.contains(MatchRangeKey(old)) {
                        tlm.invalidateRenderingAttributes(for: old.range)
                    }

                    // Apply new rendering attributes
                    let oldSet = Set(oldMatchRanges.map { MatchRangeKey($0) })
                    for new in newMatchRanges where !oldSet.contains(MatchRangeKey(new)) {
                        tlm.setRenderingAttributes(
                            HighlightStyler.renderingAttributes(for: new.kind),
                            for: new.range
                        )
                    }
                }
            }
        }

        let scrollTarget: ScrollTarget
        if highlights.isEmpty {
            scrollTarget = .top
        } else {
            let targetHighlight = highlights.first { $0.start == densestHighlightStart } ?? highlights[0]
            scrollTarget = .highlight(targetHighlight.nsRange(in: text))
        }

        scroll(
            textView: textView,
            target: scrollTarget,
            coordinator: coordinator
        )
    }

    // MARK: - Highlight Resolution

    /// Convert [HighlightRange] to [(NSTextRange, HighlightKind)] using the text layout manager.
    private func resolveTextRanges(
        highlights: [HighlightRange],
        text: String,
        layoutManager: NSTextLayoutManager?
    ) -> [MatchRange] {
        guard let tlm = layoutManager,
              let tcm = tlm.textContentManager else { return [] }

        return highlights.compactMap { highlight in
            let nsRange = highlight.nsRange(in: text)
            guard nsRange.location != NSNotFound else { return nil }

            guard let start = tcm.location(tcm.documentRange.location, offsetBy: nsRange.location),
                  let end = tcm.location(start, offsetBy: nsRange.length) else { return nil }

            guard let textRange = NSTextRange(location: start, end: end) else { return nil }
            return MatchRange(range: textRange, kind: highlight.kind,
                              scalarStart: highlight.start, scalarEnd: highlight.end)
        }
    }

    // MARK: - Scroll

    private func scroll(
        textView: NSTextView,
        target: ScrollTarget,
        coordinator: Coordinator
    ) {
        coordinator.scrollGeneration += 1
        let generation = coordinator.scrollGeneration

        performScrollAttempt(
            textView: textView,
            target: target,
            generation: generation,
            coordinator: coordinator,
            attempt: 0
        )
    }

    /// Attempt to scroll to the target position, retrying if layout is not ready.
    /// TextKit 2's lazy layout may not have computed text segment frames immediately,
    /// so we retry with increasing delays up to a maximum number of attempts.
    private func performScrollAttempt(
        textView: NSTextView,
        target: ScrollTarget,
        generation: Int,
        coordinator: Coordinator,
        attempt: Int
    ) {
        // Retry delays: 0ms, 16ms, 32ms, 64ms (total max ~112ms, about 7 frames at 60fps)
        let maxAttempts = 4
        let delayMs = attempt == 0 ? 0 : (16 * (1 << (attempt - 1)))

        let work = { [weak textView] in
            guard let textView else { return }
            guard coordinator.scrollGeneration == generation else { return }
            guard let scrollView = textView.enclosingScrollView else {
                // View hierarchy not ready yet - retry
                if attempt < maxAttempts - 1 {
                    self.performScrollAttempt(
                        textView: textView,
                        target: target,
                        generation: generation,
                        coordinator: coordinator,
                        attempt: attempt + 1
                    )
                }
                return
            }
            guard scrollView.contentSize.width > 0 else {
                if attempt < maxAttempts - 1 {
                    self.performScrollAttempt(
                        textView: textView,
                        target: target,
                        generation: generation,
                        coordinator: coordinator,
                        attempt: attempt + 1
                    )
                }
                return
            }

            if coordinator.needsGeometrySync {
                self.syncTextViewGeometry(textView: textView, containerWidth: scrollView.contentSize.width)
                coordinator.needsGeometrySync = false
            }

            switch target {
            case .top:
                let currentOrigin = scrollView.contentView.bounds.origin
                let newOrigin = NSPoint(x: currentOrigin.x, y: 0)
                guard abs(currentOrigin.y - newOrigin.y) >= 1 else { return }

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                scrollView.contentView.scroll(to: newOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                CATransaction.commit()
                return
            case .highlight:
                break
            }

            guard let tlm = textView.textLayoutManager,
                  let tcm = tlm.textContentManager else { return }
            guard case .highlight(let targetNSRange) = target else { return }

            // Convert NSRange to NSTextRange
            guard let start = tcm.location(tcm.documentRange.location, offsetBy: targetNSRange.location),
                  let end = tcm.location(start, offsetBy: targetNSRange.length),
                  let targetTextRange = NSTextRange(location: start, end: end) else { return }

            // Ensure layout for just this range
            tlm.ensureLayout(for: targetTextRange)

            // Get the frame of the highlight using STTextKitPlus
            // TextKit 2 may return nil if layout isn't fully computed yet
            guard let rect = tlm.textSegmentFrame(in: targetTextRange, type: .highlight) else {
                // Layout not ready - retry with exponential backoff
                if attempt < maxAttempts - 1 {
                    self.performScrollAttempt(
                        textView: textView,
                        target: target,
                        generation: generation,
                        coordinator: coordinator,
                        attempt: attempt + 1
                    )
                }
                return
            }

            // Convert rect to scroll view coordinates.
            let highlightRect = rect.offsetBy(dx: textView.textContainerInset.width, dy: textView.textContainerInset.height)
            var documentHeight: CGFloat = 0
            tlm.enumerateTextLayoutFragments(from: tlm.documentRange.endLocation,
                                              options: [.reverse, .ensuresLayout]) { fragment in
                documentHeight = fragment.layoutFragmentFrame.maxY
                return false  // stop after first (last) fragment
            }

            let visibleHeight = scrollView.documentVisibleRect.height
            let targetOffsetY = highlightRect.midY - (visibleHeight / 3)
            let contentHeight = max(
                textView.bounds.height,
                documentHeight + textView.textContainerInset.height * 2
            )
            let maxScrollY = max(0, contentHeight - visibleHeight)
            let clampedY = min(max(0, targetOffsetY), maxScrollY)

            let currentOrigin = scrollView.contentView.bounds.origin
            let newOrigin = NSPoint(x: currentOrigin.x, y: clampedY)
            guard abs(currentOrigin.y - newOrigin.y) >= 1 else { return }

            // Perform scroll with animations explicitly disabled
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scrollView.contentView.scroll(to: newOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            CATransaction.commit()
        }

        if delayMs == 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
        }
    }

    private func syncTextViewGeometry(textView: NSTextView, containerWidth: CGFloat) {
        textView.textContainer?.containerSize = NSSize(
            width: containerWidth,
            height: .greatestFiniteMagnitude
        )
        textView.frame = NSRect(x: 0, y: 0, width: containerWidth, height: textView.frame.height)

        guard let scrollView = textView.enclosingScrollView else {
            return
        }

        let targetHeight = max(
            scrollView.contentSize.height,
            documentHeight(for: textView) + textView.textContainerInset.height * 2
        )
        textView.frame = NSRect(x: 0, y: 0, width: containerWidth, height: targetHeight)
    }

    private func documentHeight(for textView: NSTextView) -> CGFloat {
        guard let tlm = textView.textLayoutManager else { return 0 }

        var documentHeight: CGFloat = 0
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.endLocation,
            options: [.reverse, .ensuresLayout]
        ) { fragment in
            documentHeight = fragment.layoutFragmentFrame.maxY
            return false
        }
        return documentHeight
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Supporting Types

    /// A resolved match: the original scalar indices (for identity) plus the TextKit 2 range (for operations).
    struct MatchRange {
        let range: NSTextRange
        let kind: HighlightKind
        let scalarStart: UInt64
        let scalarEnd: UInt64
    }

    /// Hashable key for efficient Set-based diffing of match ranges.
    private struct MatchRangeKey: Hashable {
        let scalarStart: UInt64
        let scalarEnd: UInt64
        let kind: HighlightKind

        init(_ match: MatchRange) {
            self.scalarStart = match.scalarStart
            self.scalarEnd = match.scalarEnd
            self.kind = match.kind
        }
    }

    class Coordinator {
        var lastHighlights: [HighlightRange] = []
        /// Current match ranges for diffing on next update.
        var currentMatchRanges: [MatchRange] = []
        var scrollGeneration: Int = 0
        var lastContentWidth: CGFloat = 0
        var needsGeometrySync: Bool = false
    }
}

// MARK: - Link Preview (LPLinkView)

import LinkPresentation

/// Native link preview using LPLinkView
struct LinkPreviewView: NSViewRepresentable {
    let url: String
    let metadataState: LinkMetadataState

    func makeNSView(context: Context) -> LPLinkView {
        let linkView = LPLinkView()
        if let metadata = buildMetadata() {
            linkView.metadata = metadata
        }
        return linkView
    }

    func updateNSView(_ linkView: LPLinkView, context: Context) {
        guard context.coordinator.lastURL != url ||
              context.coordinator.lastMetadataState != metadataState else {
            return
        }
        context.coordinator.lastURL = url
        context.coordinator.lastMetadataState = metadataState

        if let metadata = buildMetadata() {
            linkView.metadata = metadata
        }
    }

    private func buildMetadata() -> LPLinkMetadata? {
        guard let urlObj = URL(string: url) else { return nil }
        let metadata = LPLinkMetadata()
        metadata.originalURL = urlObj
        metadata.url = urlObj

        if case .loaded(let payload) = metadataState {
            switch payload {
            case .titleOnly(let title, _):
                metadata.title = title
            case .imageOnly(let imageData, _):
                if let nsImage = NSImage(data: imageData) {
                    metadata.imageProvider = NSItemProvider(object: nsImage)
                }
            case .titleAndImage(let title, let imageData, _):
                metadata.title = title
                if let nsImage = NSImage(data: imageData) {
                    metadata.imageProvider = NSItemProvider(object: nsImage)
                }
            }
        }
        return metadata
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var lastURL: String?
        var lastMetadataState: LinkMetadataState?
    }
}

// MARK: - Item Row

struct ItemRow: View, Equatable {
    let metadata: ItemMetadata
    let matchData: MatchData?
    let isSelected: Bool
    let hasUserNavigated: Bool
    let onTap: () -> Void

    private var accentSelected: Bool { isSelected && hasUserNavigated }

    // Fixed height for exactly 1 line of text at font size 15
    private let rowHeight: CGFloat = 32

    // MARK: - Display Text (Simplified - SwiftUI handles truncation)

    /// Text to display - uses matchData.text if in search mode, otherwise metadata.snippet
    /// SwiftUI's Three-Part HStack handles truncation with proper ellipsis via layout priorities
    private var displayText: String {
        if let matchText = matchData?.text, !matchText.isEmpty {
            return matchText
        }
        return metadata.snippet
    }

    /// Highlights for display - passed directly from Rust (already adjusted for normalization)
    private var displayHighlights: [HighlightRange] {
        matchData?.highlights ?? []
    }


    // Define exactly what constitutes a "change" for SwiftUI diffing
    // Note: onTap closure is intentionally excluded from equality comparison
    nonisolated static func == (lhs: ItemRow, rhs: ItemRow) -> Bool {
        return lhs.isSelected == rhs.isSelected &&
               lhs.hasUserNavigated == rhs.hasUserNavigated &&
               lhs.metadata == rhs.metadata &&
               lhs.matchData == rhs.matchData
    }

    var body: some View {
        // 1. Wrap the content inside a Button
        Button(action: onTap) {
            HStack(spacing: 6) {
            // Content type icon with source app badge overlay
            ZStack(alignment: .bottomTrailing) {
                // Main icon: image thumbnail, browser icon for links, color swatch, or SF symbol
                Group {
                    switch metadata.icon {
                    case .thumbnail(let bytes):
                        if let nsImage = NSImage(data: Data(bytes)) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "photo")
                                .resizable()
                        }
                    case .colorSwatch(let rgba):
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
                    case .symbol(let iconType):
                        if case .link = iconType,
                           let browserURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://")!) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: browserURL.path))
                                .resizable()
                        } else if case .file = iconType,
                                  let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: finderURL.path))
                                .resizable()
                        } else {
                            Image(nsImage: NSWorkspace.shared.icon(for: iconType.utType))
                                .resizable()
                        }
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                // Badge: Source app icon
                // Show for symbols (except pure link icons) and thumbnails (images, links with images)
                if let bundleID = metadata.sourceAppBundleId,
                   let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    // Skip badge for symbol links/files (app icon is already shown)
                    let showBadge: Bool = {
                        switch metadata.icon {
                        case .symbol(let iconType):
                            return iconType != .link && iconType != .file
                        case .thumbnail, .colorSwatch:
                            return true
                        }
                    }()

                    if showBadge {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                            .resizable()
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                            .offset(x: 4, y: 4)
                    }
                }
            }
            .frame(width: 38, height: 38)
            .allowsHitTesting(false)

            // Line number (shown in search mode when line > 1)
            if let lineNumber = matchData?.lineNumber, lineNumber > 1 {
                Text("L\(lineNumber):")
                    .font(.custom(FontManager.mono, size: 13))
                    .foregroundColor(accentSelected ? .white.opacity(0.7) : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .allowsHitTesting(false)
            }

            // Text content - SwiftUI Three-Part HStack with layout priorities
            HighlightedTextView(
                text: displayText,
                highlights: displayHighlights,
                accentSelected: accentSelected
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            .layoutPriority(1)


        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background {
            if accentSelected {
                selectionBackground()
            } else if isSelected {
                Color.primary.opacity(0.225)
            } else {
                Color.clear
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        }
        // 2. Apply the plain style so it behaves like a standard row instead of a system button
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayText)
        .accessibilityHint(AppSettings.shared.pasteMode == .autoPaste ? String(localized: "Double tap to paste") : String(localized: "Double tap to copy"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

}

// MARK: - Three-Part HStack Highlighted Text

/// SwiftUI-native text view using Three-Part HStack strategy for search highlighting.
/// Uses layout priorities to guarantee the first highlight is always visible while maximizing context.
/// - Prefix: Truncates from head (`.head`) showing "...text"
/// - Highlight: Has `.layoutPriority(1)` to claim space first, never pushed off-screen
/// - Suffix: Truncates from tail (`.tail`) showing "text..."
///
/// Uses HighlightStyler for all index calculations with proper Unicode scalar handling.
struct HighlightedTextView: View, Equatable {
    let text: String
    let highlights: [HighlightRange]
    let accentSelected: Bool

    // Define equality for SwiftUI diffing
    nonisolated static func == (lhs: HighlightedTextView, rhs: HighlightedTextView) -> Bool {
        lhs.text == rhs.text && lhs.highlights == rhs.highlights && lhs.accentSelected == rhs.accentSelected
    }

    private var textColor: Color {
        accentSelected ? .white : .primary
    }

    private var font: Font {
        .custom(FontManager.sansSerif, size: 15)
    }

    var body: some View {
        // Use firstTextBaseline so text aligns perfectly even with different weights
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let firstHighlight = highlights.first {
                // Use HighlightStyler for correct Unicode scalar handling
                let (prefix, match, suffix) = HighlightStyler.splitText(text, highlight: firstHighlight)
                let suffixStartScalarIndex = Int(firstHighlight.end)

                // 1. PREFIX: Truncates on the left ("...text")
                if !prefix.isEmpty {
                    Text(prefix)
                        .font(font)
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                // 2. HIGHLIGHT: High priority ensures it claims space first
                highlightedMatchView(match: match, kind: firstHighlight.kind)

                // 3. SUFFIX: Truncates on the right ("text...")
                // Apply any additional highlights that fall within suffix
                if !suffix.isEmpty {
                    suffixView(suffix: suffix, suffixStartScalarIndex: suffixStartScalarIndex)
                        .font(font)
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

            } else {
                // No highlights - simple text with tail truncation
                Text(text)
                    .font(font)
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        // Ensure text aligns to the left if shorter than container
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Build the highlighted match view with optional underline
    @ViewBuilder
    private func highlightedMatchView(match: String, kind: HighlightKind) -> some View {
        let baseView = Text(match)
            .font(font)
            .foregroundColor(textColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
            .background(HighlightStyler.color(for: kind))

        if HighlightStyler.usesUnderline(kind) {
            baseView.underline()
        } else {
            baseView
        }
    }

    /// Build suffix view with any additional highlights
    @ViewBuilder
    private func suffixView(suffix: String, suffixStartScalarIndex: Int) -> some View {
        // Check for additional highlights in the suffix (beyond the first one)
        // Use Unicode scalar count for correct bounds checking
        let suffixScalarCount = suffix.unicodeScalars.count
        let additionalHighlights = highlights.dropFirst().filter { h in
            HighlightStyler.highlightInSuffix(h, suffixStartScalarIndex: suffixStartScalarIndex, suffixScalarCount: suffixScalarCount)
        }

        if additionalHighlights.isEmpty {
            Text(suffix)
        } else {
            // Use HighlightStyler for correct Unicode scalar handling
            Text(HighlightStyler.attributedSuffix(suffix, suffixStartScalarIndex: suffixStartScalarIndex, highlights: Array(additionalHighlights)))
        }
    }
}

// MARK: - Filter Option Row

private struct FilterOptionRow: View {
    let label: String
    let isSelected: Bool
    var isHighlighted: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(isHighlighted ? .white : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    if isHighlighted {
                        selectionBackground()
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    } else {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(isSelected ? Color.primary.opacity(0.1) : isHovered ? Color.primary.opacity(0.05) : Color.clear)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Action Option Row

private struct ActionOptionRow: View {
    let label: String
    let actionID: String
    var isHighlighted: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    if isHighlighted {
                        if isDestructive {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Color.red.opacity(0.8))
                        } else {
                            selectionBackground()
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("Action_\(actionID)")
    }

    private var foregroundColor: Color {
        if isHighlighted { return .white }
        if isDestructive { return .red }
        return .secondary
    }
}

// MARK: - Selection Background

/// Shared selection highlight matching Spotlight's style (H220 S68 B71)
@ViewBuilder
private func selectionBackground() -> some View {
    Color.accentColor
        .opacity(0.9)
        .saturation(0.78)
        .brightness(-0.06)
}

// MARK: - Highlight Kind Color Mapping

// MARK: - Hide Scroll Indicators When System Uses Overlay Style

/// Hides scroll indicators when the system preference is "Show scroll bars: When scrolling" (overlay style).
/// Detects scrolling via ScrollView geometry and shows indicators only while actively scrolling.
/// This prevents the brief scrollbar flash when the panel appears.
struct HideScrollIndicatorsWhenOverlay: ViewModifier {
    let displayVersion: Int
    @State private var hasScrolled = false

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *), NSScroller.preferredScrollerStyle == .overlay {
            content
                .scrollIndicators(hasScrolled ? .automatic : .never)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, _ in
                    if !hasScrolled {
                        hasScrolled = true
                    }
                }
                .onChange(of: displayVersion) { _, _ in
                    hasScrolled = false
                }
        } else {
            content
        }
    }
}
