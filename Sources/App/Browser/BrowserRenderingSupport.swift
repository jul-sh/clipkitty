import AppKit
import ClipKittyRust
import ObjectiveC.runtime
import STTextKitPlus
import SwiftUI
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
        if case let .debouncing(task) = self {
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
            background(.regularMaterial)
        }
    }
}

// MARK: - Subtle Hover Effect

/// A view modifier that adds a subtle animated hover background effect.
/// Use on button labels to provide visual feedback on hover.
struct SubtleHoverEffect: ViewModifier {
    let cornerRadius: CGFloat
    let useCapsule: Bool
    @State private var isHovered = false

    init(cornerRadius: CGFloat = 9, useCapsule: Bool = false) {
        self.cornerRadius = cornerRadius
        self.useCapsule = useCapsule
    }

    func body(content: Content) -> some View {
        content
            .background {
                if useCapsule {
                    Capsule().fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
                }
            }
            .contentShape(useCapsule ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius)))
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// A view modifier for capsule buttons with border that changes on hover.
struct SubtleHoverCapsuleWithBorder: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(isHovered ? Color.primary.opacity(0.04) : Color.clear))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(isHovered ? 0.25 : 0.15)))
            .contentShape(Capsule())
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

extension View {
    /// Adds a subtle hover background effect with rounded corners.
    func subtleHover(cornerRadius: CGFloat = 9) -> some View {
        modifier(SubtleHoverEffect(cornerRadius: cornerRadius))
    }

    /// Adds a subtle hover background effect with capsule shape.
    func subtleHoverCapsule() -> some View {
        modifier(SubtleHoverEffect(useCapsule: true))
    }

    /// Adds a subtle hover effect with capsule shape and border.
    func subtleHoverCapsuleWithBorder() -> some View {
        modifier(SubtleHoverCapsuleWithBorder())
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

/// NSTextView subclass with custom key handling for the preview pane
private final class PreviewTextView: NSTextView {
    // NSTextView keeps itself as the viewport layout delegate. We expose the same optional
    // selector on our subclass and forward to NSTextView's original implementation so we can
    // observe post-layout state without replacing AppKit's delegate plumbing.
    private static let didLayoutSelector = NSSelectorFromString("textViewportLayoutControllerDidLayout:")
    private static let superDidLayoutImplementation: IMP? = {
        guard let method = class_getInstanceMethod(NSTextView.self, didLayoutSelector) else { return nil }
        return method_getImplementation(method)
    }()

    var onCmdReturn: (() -> Void)?
    var onSave: (() -> Void)?
    var onEscape: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onViewportLayoutDidLayout: ((PreviewTextView, NSTextViewportLayoutController) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 36: // Cmd+Return
                onCmdReturn?()
                return
            case 1: // Cmd+S
                onSave?()
                return
            default:
                break
            }
        }
        if event.keyCode == 53 { // Escape
            window?.makeFirstResponder(nil)
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChange?(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocusChange?(false) }
        return result
    }

    @objc(textViewportLayoutControllerDidLayout:)
    func clipKitty_textViewportLayoutControllerDidLayout(
        _ textViewportLayoutController: NSTextViewportLayoutController
    ) {
        if let implementation = Self.superDidLayoutImplementation {
            typealias DidLayoutFunction =
                @convention(c) (AnyObject, Selector, NSTextViewportLayoutController) -> Void
            unsafeBitCast(implementation, to: DidLayoutFunction.self)(
                self,
                Self.didLayoutSelector,
                textViewportLayoutController
            )
        }
        onViewportLayoutDidLayout?(self, textViewportLayoutController)
    }
}

struct TextPreviewView: NSViewRepresentable {
    let text: String
    let fontName: String
    let fontSize: CGFloat
    var highlights: [HighlightRange] = []
    var densestHighlightStart: UInt64 = 0
    var shouldAutoScroll = true

    // Edit callbacks
    var itemId: Int64 = 0
    var originalText: String = ""
    var onTextChange: ((String) -> Void)?
    var onEditingStateChange: ((Bool) -> Void)?
    var onCmdReturn: (() -> Void)?
    var onSave: (() -> Void)?
    var onEscape: (() -> Void)?

    fileprivate enum ScrollTarget {
        case top
        case highlight(scalarStart: UInt64, scalarEnd: UInt64)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        // Use PreviewTextView for custom key handling (Cmd+Return, Cmd+S, Escape)
        // NSTextView() defaults to TextKit 2 on macOS 12+.
        // IMPORTANT: never access .layoutManager — that silently downgrades to TextKit 1.
        let textView = PreviewTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false // Plain text for editing
        textView.allowsUndo = true
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

        // Setup delegate for text changes
        textView.delegate = context.coordinator
        textView.onCmdReturn = onCmdReturn
        textView.onSave = onSave
        textView.onEscape = onEscape
        textView.onFocusChange = onEditingStateChange
        context.coordinator.onTextChange = onTextChange

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
        guard let textView = nsView.documentView as? PreviewTextView else { return }

        // Update callbacks
        let coordinator = context.coordinator
        coordinator.observeUsageBounds(of: textView)
        coordinator.onTextChange = onTextChange
        textView.onCmdReturn = onCmdReturn
        textView.onSave = onSave
        textView.onEscape = onEscape
        textView.onFocusChange = onEditingStateChange
        textView.onViewportLayoutDidLayout = { [weak coordinator] observedTextView, textViewportLayoutController in
            guard let coordinator,
                  shouldAutoScroll,
                  let target = coordinator.activeUsageBoundsTarget() else { return }

            let generation = coordinator.scrollGeneration
            // TextKit 2 can report a transiently invalid viewport immediately after a layout pass.
            // Retry layoutViewport once on the next run loop instead of centering against empty
            // bounds or a nil viewport range, then do one post-layout scroll attempt once the
            // viewport state is coherent.
            if textViewportLayoutController.viewportBounds.isEmpty ||
                textViewportLayoutController.viewportRange == nil
            {
                guard coordinator.scheduleViewportRetry(for: generation) else { return }
                DispatchQueue.main.async { [weak coordinator, weak observedTextView] in
                    guard let coordinator,
                          let observedTextView,
                          coordinator.scrollGeneration == generation else { return }
                    observedTextView.textLayoutManager?.textViewportLayoutController.layoutViewport()
                }
                return
            }

            coordinator.clearViewportRetry()
            coordinator.needsGeometrySync = true
            DispatchQueue.main.async { [weak coordinator, weak observedTextView] in
                guard let coordinator,
                      let observedTextView,
                      coordinator.scrollGeneration == generation else { return }
                if let scrollView = observedTextView.enclosingScrollView {
                    self.flushPendingDisplay(textView: observedTextView, scrollView: scrollView)
                }
                self.performScrollAttempt(
                    textView: observedTextView,
                    target: target,
                    generation: generation,
                    coordinator: coordinator,
                    attempt: 0
                )
            }
        }
        coordinator.onUsageBoundsChange = { [weak coordinator] observedTextView in
            guard let coordinator,
                  shouldAutoScroll,
                  let target = coordinator.activeUsageBoundsTarget() else { return }
            coordinator.needsGeometrySync = true
            self.performScrollAttempt(
                textView: observedTextView,
                target: target,
                generation: coordinator.scrollGeneration,
                coordinator: coordinator,
                attempt: 0
            )
        }

        // Check if item changed
        let itemChanged = coordinator.currentItemId != itemId
        if itemChanged {
            coordinator.currentItemId = itemId
            coordinator.isEditing = false
        }

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

        // Set typing attributes for consistent font during editing
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle,
        ]

        let textChanged = textView.string != text
        let highlightsChanged = coordinator.lastHighlights != highlights
        let contentWidthChanged = abs(coordinator.lastContentWidth - containerWidth) > 0.5
        let gainedHighlights = !highlights.isEmpty && coordinator.lastHighlights.isEmpty
        coordinator.lastContentWidth = containerWidth

        guard itemChanged || textChanged || highlightsChanged || contentWidthChanged else { return }
        if itemChanged || textChanged || contentWidthChanged || gainedHighlights {
            coordinator.needsGeometrySync = true
        }

        // Only update text if item changed or we're not editing
        let shouldUpdateText = itemChanged || (!coordinator.isEditing && textChanged)
        if shouldUpdateText {
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
                .paragraphStyle: paragraphStyle,
            ])

            textView.textStorage?.setAttributedString(attributed)
        }

        let tlm = textView.textLayoutManager
        if itemChanged || textChanged || highlightsChanged {
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
            scrollTarget = .highlight(
                scalarStart: targetHighlight.start,
                scalarEnd: targetHighlight.end
            )
        }

        if shouldAutoScroll {
            scroll(
                textView: textView,
                target: scrollTarget,
                coordinator: coordinator
            )
        } else if coordinator.needsGeometrySync {
            coordinator.clearUsageBoundsRecentering()
            _ = syncTextViewGeometry(textView: textView, containerWidth: containerWidth)
            coordinator.needsGeometrySync = false
            coordinator.scrollGeneration += 1
        }
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
        coordinator.clearViewportRetry()
        switch target {
        case .top:
            coordinator.clearUsageBoundsRecentering()
        case .highlight:
            coordinator.armUsageBoundsRecentering(target: target, duration: 0.75)
        }

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
                let geometryReady = self.syncTextViewGeometry(
                    textView: textView,
                    containerWidth: scrollView.contentSize.width
                )
                if !geometryReady {
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
                self.flushPendingDisplay(textView: textView, scrollView: scrollView)
                return
            case .highlight:
                break
            }

            guard let tlm = textView.textLayoutManager else { return }
            guard case let .highlight(scalarStart, scalarEnd) = target else { return }
            guard let targetMatchRange = coordinator.currentMatchRanges.first(where: {
                $0.scalarStart == scalarStart && $0.scalarEnd == scalarEnd
            }) else {
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
            let targetTextRange = targetMatchRange.range

            // Ensure layout for just this range.
            tlm.ensureLayout(for: targetTextRange)

            // Get the frame of the highlight using STTextKitPlus.
            // With document geometry stabilized first, this gives a reliable target rect.
            guard let rect = tlm.textSegmentFrame(in: targetTextRange, type: .highlight) else {
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

            let highlightRect = rect
            let visibleHeight = scrollView.documentVisibleRect.height
            let currentOrigin = scrollView.contentView.bounds.origin
            let currentVisibleMinY = currentOrigin.y
            let currentVisibleMaxY = currentOrigin.y + visibleHeight
            let desiredAnchorY = currentOrigin.y + (visibleHeight / 3)
            let currentAnchorDelta = highlightRect.midY - desiredAnchorY
            let isCurrentlyVisible =
                highlightRect.minY >= currentVisibleMinY &&
                highlightRect.maxY <= currentVisibleMaxY

            if isCurrentlyVisible, abs(currentAnchorDelta) <= 48 {
                coordinator.clearUsageBoundsRecentering()
                return
            }

            let targetOffsetY = highlightRect.midY - (visibleHeight / 3)
            let contentHeight = max(textView.bounds.height, scrollView.contentSize.height)
            let maxScrollY = max(0, contentHeight - visibleHeight)
            let clampedY = min(max(0, targetOffsetY), maxScrollY)

            let newOrigin = NSPoint(x: currentOrigin.x, y: clampedY)
            guard abs(currentOrigin.y - newOrigin.y) >= 1 else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scrollView.contentView.scroll(to: newOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            CATransaction.commit()
            self.flushPendingDisplay(textView: textView, scrollView: scrollView)
        }

        if delayMs == 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
        }
    }

    private func syncTextViewGeometry(textView: NSTextView, containerWidth: CGFloat) -> Bool {
        textView.textContainer?.containerSize = NSSize(
            width: containerWidth,
            height: .greatestFiniteMagnitude
        )
        textView.frame = NSRect(x: 0, y: 0, width: containerWidth, height: textView.frame.height)
        textView.layoutSubtreeIfNeeded()

        guard let scrollView = textView.enclosingScrollView,
              let tlm = textView.textLayoutManager
        else {
            return false
        }

        scrollView.layoutSubtreeIfNeeded()
        tlm.textViewportLayoutController.layoutViewport()
        textView.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()

        let autoSizedHeight = textView.frame.height
        if !textView.string.isEmpty && autoSizedHeight <= 0 {
            return false
        }

        let targetHeight = max(scrollView.contentSize.height, autoSizedHeight)
        if abs(textView.frame.height - targetHeight) > 0.5 {
            textView.frame = NSRect(x: 0, y: 0, width: containerWidth, height: targetHeight)
        }
        flushPendingDisplay(textView: textView, scrollView: scrollView)
        return true
    }

    private func flushPendingDisplay(textView: NSTextView, scrollView: NSScrollView) {
        scrollView.contentView.layoutSubtreeIfNeeded()
        textView.layoutSubtreeIfNeeded()
        textView.setNeedsDisplay(textView.visibleRect)
        scrollView.contentView.setNeedsDisplay(scrollView.contentView.bounds)
        scrollView.displayIfNeeded()
        textView.displayIfNeeded()
    }

    private func documentHeight(for textView: NSTextView) -> CGFloat {
        guard let tlm = textView.textLayoutManager else { return 0 }

        var documentHeight: CGFloat = 0
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard !fragment.isExtraLineFragment else { return true }
            documentHeight = max(documentHeight, fragment.layoutFragmentFrame.maxY)
            return true
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
            scalarStart = match.scalarStart
            scalarEnd = match.scalarEnd
            kind = match.kind
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var lastHighlights: [HighlightRange] = []
        /// Current match ranges for diffing on next update.
        var currentMatchRanges: [MatchRange] = []
        var scrollGeneration: Int = 0
        var lastContentWidth: CGFloat = 0
        var lastUsageBounds: CGRect = .zero
        var needsGeometrySync: Bool = false
        private var pendingScrollTarget: ScrollTarget?
        private var pendingAutoScrollExpiration: Date = .distantPast
        private var pendingViewportRetryGeneration: Int?
        fileprivate var onUsageBoundsChange: ((PreviewTextView) -> Void)?
        private var usageBoundsObservation: NSKeyValueObservation?
        fileprivate weak var observedTextView: PreviewTextView?

        // Edit tracking
        var currentItemId: Int64 = 0
        var isEditing = false
        var onTextChange: ((String) -> Void)?

        deinit {
            usageBoundsObservation?.invalidate()
        }

        fileprivate func observeUsageBounds(of textView: PreviewTextView) {
            guard observedTextView !== textView || usageBoundsObservation == nil else { return }

            usageBoundsObservation?.invalidate()
            observedTextView = textView
            lastUsageBounds = textView.textLayoutManager?.usageBoundsForTextContainer ?? .zero

            guard let textLayoutManager = textView.textLayoutManager else { return }
            usageBoundsObservation = textLayoutManager.observe(
                \.usageBoundsForTextContainer,
                options: [.new]
            ) { [weak self, weak textView] textLayoutManager, _ in
                guard let self, let textView else { return }
                let usageBounds = textLayoutManager.usageBoundsForTextContainer
                let changed =
                    abs(usageBounds.origin.y - self.lastUsageBounds.origin.y) > 0.5 ||
                    abs(usageBounds.size.height - self.lastUsageBounds.size.height) > 0.5
                guard changed else { return }
                self.lastUsageBounds = usageBounds

                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.onUsageBoundsChange?(textView)
                }
            }
        }

        fileprivate func armUsageBoundsRecentering(
            target: ScrollTarget?,
            duration: TimeInterval
        ) {
            pendingScrollTarget = target
            pendingAutoScrollExpiration = target == nil ? .distantPast : Date().addingTimeInterval(duration)
            pendingViewportRetryGeneration = nil
        }

        fileprivate func activeUsageBoundsTarget() -> ScrollTarget? {
            guard Date() < pendingAutoScrollExpiration else {
                pendingScrollTarget = nil
                pendingAutoScrollExpiration = .distantPast
                return nil
            }
            return pendingScrollTarget
        }

        fileprivate func clearUsageBoundsRecentering() {
            pendingScrollTarget = nil
            pendingAutoScrollExpiration = .distantPast
            pendingViewportRetryGeneration = nil
        }

        fileprivate func scheduleViewportRetry(for generation: Int) -> Bool {
            guard pendingViewportRetryGeneration != generation else { return false }
            pendingViewportRetryGeneration = generation
            return true
        }

        fileprivate func clearViewportRetry() {
            pendingViewportRetryGeneration = nil
        }

        func textDidBeginEditing(_: Notification) {
            isEditing = true
        }

        func textDidEndEditing(_: Notification) {
            isEditing = false
        }

        func textDidChange(_ notification: Notification) {
            guard let onTextChange, let textView = notification.object as? NSTextView else { return }
            onTextChange(textView.string)
        }
    }
}

// MARK: - Link Preview (LPLinkView)

import LinkPresentation

/// Native link preview using LPLinkView
struct LinkPreviewView: NSViewRepresentable {
    let url: String
    let metadataState: LinkMetadataState

    func makeNSView(context _: Context) -> LPLinkView {
        let linkView = LPLinkView()
        if let metadata = buildMetadata() {
            linkView.metadata = metadata
        }
        return linkView
    }

    func updateNSView(_ linkView: LPLinkView, context: Context) {
        guard context.coordinator.lastURL != url ||
            context.coordinator.lastMetadataState != metadataState
        else {
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

        if case let .loaded(payload) = metadataState {
            switch payload {
            case let .titleOnly(title, _):
                metadata.title = title
            case let .imageOnly(imageData, _):
                if let nsImage = NSImage(data: imageData) {
                    metadata.imageProvider = NSItemProvider(object: nsImage)
                }
            case let .titleAndImage(title, imageData, _):
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
    let isContextMenuTargeted: Bool
    let hasUserNavigated: Bool
    let hasPendingEdit: Bool
    let onTap: () -> Void
    let contextMenuActions: [BrowserActionItem]
    let onContextMenuAction: (BrowserActionItem) -> Void
    let onContextMenuDelete: () -> Void
    let onContextMenuShow: () -> Void
    let onContextMenuHide: () -> Void

    private var accentSelected: Bool { isSelected && hasUserNavigated && !hasPendingEdit }

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
            lhs.isContextMenuTargeted == rhs.isContextMenuTargeted &&
            lhs.hasUserNavigated == rhs.hasUserNavigated &&
            lhs.hasPendingEdit == rhs.hasPendingEdit &&
            lhs.metadata == rhs.metadata &&
            lhs.matchData == rhs.matchData
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
                            .font(.system(size: 24))
                            .frame(width: 32, height: 32)
                    } else {
                        ZStack(alignment: .bottomTrailing) {
                            // Main icon: image thumbnail, browser icon for links, color swatch, or SF symbol
                            Group {
                                switch metadata.icon {
                                case let .thumbnail(bytes):
                                    if let nsImage = NSImage(data: Data(bytes)) {
                                        Image(nsImage: nsImage)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    } else {
                                        Image(systemName: "photo")
                                            .resizable()
                                    }
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
                                    if case .link = iconType,
                                       let browserURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://")!)
                                    {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: browserURL.path))
                                            .resizable()
                                    } else if case .file = iconType,
                                              let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")
                                    {
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

                            // Badge: Bookmark icon for bookmarked items, otherwise source app icon
                            if metadata.tags.contains(.bookmark) {
                                Image("BookmarkIcon")
                                    .resizable()
                                    .frame(width: 18, height: 18)
                                    .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                                    .offset(x: 4, y: 4)
                            } else if let bundleID = metadata.sourceAppBundleId,
                                      let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                            {
                                // Skip badge for symbol links/files (app icon is already shown)
                                let showBadge: Bool = {
                                    switch metadata.icon {
                                    case let .symbol(iconType):
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
                HStack(spacing: 6) {
                    HighlightedTextView(
                        text: displayText,
                        highlights: displayHighlights,
                        accentSelected: accentSelected
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
        .accessibilityLabel(displayText)
        .accessibilityHint(AppSettings.shared.pasteMode == .autoPaste ? String(localized: "Double tap to paste") : String(localized: "Double tap to copy"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Right-Click Popover

struct RightClickPopoverOverlay: NSViewRepresentable {
    let actions: [BrowserActionItem]
    let onShow: () -> Void
    let onHide: () -> Void
    let onAction: (BrowserActionItem) -> Void
    let onConfirmDelete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.coordinator = context.coordinator
        context.coordinator.actions = actions
        context.coordinator.onShow = onShow
        context.coordinator.onHide = onHide
        context.coordinator.onAction = onAction
        context.coordinator.onConfirmDelete = onConfirmDelete
        return view
    }

    func updateNSView(_: RightClickView, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.onShow = onShow
        context.coordinator.onHide = onHide
        context.coordinator.onAction = onAction
        context.coordinator.onConfirmDelete = onConfirmDelete
    }

    @MainActor
    final class Coordinator {
        var actions: [BrowserActionItem] = []
        var onShow: (() -> Void)?
        var onHide: (() -> Void)?
        var onAction: ((BrowserActionItem) -> Void)?
        var onConfirmDelete: (() -> Void)?
        private var activeMenuHandler: MenuActionHandler?

        deinit {
            activeMenuHandler = nil
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false

            let handler = MenuActionHandler(
                onAction: { [weak self] action in
                    self?.onAction?(action)
                },
                onConfirmDelete: { [weak self] in
                    self?.onConfirmDelete?()
                }
            )
            activeMenuHandler = handler

            for (index, action) in actions.enumerated() {
                if BrowserActionItem.showsDivider(before: index, in: actions) {
                    menu.addItem(.separator())
                }

                let item = NSMenuItem(
                    title: action.label,
                    action: #selector(MenuActionHandler.handleMenuItem(_:)),
                    keyEquivalent: ""
                )
                item.target = handler
                item.representedObject = action
                item.image = NSImage(
                    systemSymbolName: action.systemImageName,
                    accessibilityDescription: action.label
                )
                menu.addItem(item)
            }

            return menu
        }
    }

    final class RightClickView: NSView {
        weak var coordinator: Coordinator?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard shouldHandleCurrentEvent else { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) {
                rightMouseDown(with: event)
                return
            }
            super.mouseDown(with: event)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let coordinator, !coordinator.actions.isEmpty else { return }

            coordinator.onShow?()
            let menu = coordinator.makeMenu()
            let clickPoint = convert(event.locationInWindow, from: nil)
            menu.popUp(positioning: nil, at: clickPoint, in: self)
            coordinator.onHide?()
        }

        override func menu(for _: NSEvent) -> NSMenu? {
            nil
        }

        private var shouldHandleCurrentEvent: Bool {
            guard let event = NSApp.currentEvent else { return false }
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                return true
            case .leftMouseDown, .leftMouseUp:
                return event.modifierFlags.contains(.control)
            default:
                return false
            }
        }
    }

    @MainActor
    private final class MenuActionHandler: NSObject {
        let onAction: (BrowserActionItem) -> Void
        let onConfirmDelete: () -> Void

        init(onAction: @escaping (BrowserActionItem) -> Void, onConfirmDelete: @escaping () -> Void) {
            self.onAction = onAction
            self.onConfirmDelete = onConfirmDelete
        }

        @objc
        func handleMenuItem(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? BrowserActionItem else { return }
            if action.isDestructive {
                onConfirmDelete()
            } else {
                onAction(action)
            }
        }
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
                        Color.selectionBackground
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

struct ActionOptionRow: View {
    let label: String
    let actionID: String
    let systemImageName: String
    var isHighlighted: Bool = false
    var isDestructive: Bool = false
    var onHover: ((Bool) -> Void)?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImageName)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 14, alignment: .center)

                Text(label)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(backgroundColor)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { onHover?($0) }
        .accessibilityIdentifier("Action_\(actionID)")
    }

    private var foregroundColor: Color {
        if isHighlighted { return .white }
        if isDestructive { return .red }
        return .secondary
    }

    private var backgroundColor: Color {
        if isHighlighted {
            return isDestructive ? Color.red.opacity(0.8) : .selectionBackground
        }
        return Color.clear
    }
}

// MARK: - Selection Background

extension Color {
    /// Selection background matching system tint, slightly desaturated for a subtler look.
    static var selectionBackground: Color {
        Color(nsColor: .selectedContentBackgroundColor.desaturated(by: 0.10))
    }
}

private extension NSColor {
    /// Returns a new color with saturation reduced by the given fraction (0.0–1.0).
    func desaturated(by amount: CGFloat) -> NSColor {
        guard let hsb = usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        hsb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let newSaturation = max(0, s - amount)
        return NSColor(hue: h, saturation: newSaturation, brightness: b, alpha: a)
    }
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
