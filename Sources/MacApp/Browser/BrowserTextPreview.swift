import AppKit
import ClipKittyRust
import ObjectiveC.runtime
import STTextKitPlus
import SwiftUI

// MARK: - Text Preview (AppKit)

/// NSTextView subclass with custom key handling for the preview pane
private final class PreviewTextView: NSTextView {
    private enum FocusClickScrollState {
        case idle
        case suppressing(originalOrigin: NSPoint)
    }

    // NSTextView keeps itself as the viewport layout delegate. We expose the same optional
    // selector on our subclass and forward to NSTextView's original implementation so we can
    // observe post-layout state without replacing AppKit's delegate plumbing.
    private static let didLayoutSelector = NSSelectorFromString("textViewportLayoutControllerDidLayout:")
    private static let superDidLayoutImplementation: IMP? = {
        guard let method = class_getInstanceMethod(NSTextView.self, didLayoutSelector) else { return nil }
        return method_getImplementation(method)
    }()

    private var focusClickScrollState: FocusClickScrollState = .idle

    var onCmdReturn: (() -> Void)?
    var onCmdK: (() -> Void)?
    var onSave: (() -> Void)?
    var onEscape: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onViewportLayoutDidLayout: ((PreviewTextView, NSTextViewportLayoutController) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self,
           let originalOrigin = enclosingScrollView?.contentView.bounds.origin
        {
            focusClickScrollState = .suppressing(originalOrigin: originalOrigin)
        } else {
            focusClickScrollState = .idle
        }

        super.mouseDown(with: event)

        restoreFocusClickScrollIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.restoreFocusClickScrollIfNeeded(finalize: true)
        }
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        guard case .idle = focusClickScrollState else { return }
        super.scrollRangeToVisible(range)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 36: // Cmd+Return
                onCmdReturn?()
                return
            case 40: // Cmd+K
                onCmdK?()
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

    private func restoreFocusClickScrollIfNeeded(finalize: Bool = false) {
        guard case let .suppressing(originalOrigin) = focusClickScrollState else { return }
        restoreScrollOriginIfNeeded(originalOrigin)
        if finalize {
            focusClickScrollState = .idle
        }
    }

    private func restoreScrollOriginIfNeeded(_ originalOrigin: NSPoint) {
        guard let scrollView = enclosingScrollView else { return }
        let currentOrigin = scrollView.contentView.bounds.origin
        guard abs(currentOrigin.y - originalOrigin.y) >= 1 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollView.contentView.scroll(to: originalOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        CATransaction.commit()
    }

    #if compiler(>=6.4)
        // The macOS 27 SDK exposes NSTextView's
        // `textViewportLayoutControllerDidLayout(_:)` publicly (with
        // NS_REQUIRES_SUPER), so the @objc shim in the other branch would
        // collide with the superclass selector. Override it directly, calling
        // super on 27+ runtimes and keeping the IMP forward for older
        // runtimes where the superclass implementation is still private.
        override func textViewportLayoutControllerDidLayout(
            _ textViewportLayoutController: NSTextViewportLayoutController
        ) {
            if #available(macOS 27.0, *) {
                super.textViewportLayoutControllerDidLayout(textViewportLayoutController)
            } else {
                forwardDidLayoutToSuperImplementation(textViewportLayoutController)
            }
            onViewportLayoutDidLayout?(self, textViewportLayoutController)
        }
    #else
        @objc(textViewportLayoutControllerDidLayout:)
        func clipKitty_textViewportLayoutControllerDidLayout(
            _ textViewportLayoutController: NSTextViewportLayoutController
        ) {
            forwardDidLayoutToSuperImplementation(textViewportLayoutController)
            onViewportLayoutDidLayout?(self, textViewportLayoutController)
        }
    #endif

    private func forwardDidLayoutToSuperImplementation(
        _ textViewportLayoutController: NSTextViewportLayoutController
    ) {
        guard let implementation = Self.superDidLayoutImplementation else { return }
        typealias DidLayoutFunction =
            @convention(c) (AnyObject, Selector, NSTextViewportLayoutController) -> Void
        unsafeBitCast(implementation, to: DidLayoutFunction.self)(
            self,
            Self.didLayoutSelector,
            textViewportLayoutController
        )
    }
}

/// How the preview pane should scroll when its content changes.
enum PreviewScrollBehavior {
    /// No auto-scrolling — content stays at current position.
    /// Used when match data hasn't loaded yet during an active search.
    case manual

    /// Scroll to content (top or first highlight) once, without KVO recentering.
    /// Used for search-driven changes where results are churning.
    case autoScroll

    /// Scroll to highlight with KVO-based recentering for robust positioning.
    /// Used for user-initiated navigation (arrow keys, clicking in the list).
    case trackHighlight
}

class TextPreviewContent: Equatable {
    let text: String
    init(text: String) {
        self.text = text
    }

    static func == (lhs: TextPreviewContent, rhs: TextPreviewContent) -> Bool {
        return lhs === rhs
    }
}

struct TextPreviewEditingActions {
    let onTextChange: (String) -> Void
    let onEditingStateChange: (Bool) -> Void
    let onCmdReturn: () -> Void
    let onCmdK: () -> Void
    let onSave: () -> Void
    let onEscape: () -> Void
}

enum TextPreviewInteraction {
    case readOnly
    case editable(actions: TextPreviewEditingActions)
}

struct TextPreviewView: NSViewRepresentable {
    private static let maxAutoScaleCharacters = 4096
    private static let maxAutoScaleLines = 14

    static var textCache: [String: String] = [:]
    let itemId: String
    let fontName: String
    let fontSize: CGFloat
    var highlights: [Utf16HighlightRange] = []
    var initialScrollHighlightIndex: UInt64?
    /// Controls how the preview pane scrolls when content changes.
    ///
    /// The three states represent the valid scroll behaviors:
    /// - `.manual`: No auto-scrolling (e.g., match data not yet loaded during search)
    /// - `.autoScroll`: Scroll to content once, no KVO recentering (search-driven changes)
    /// - `.trackHighlight`: Scroll to highlight with KVO recentering (user navigation)
    var scrollBehavior: PreviewScrollBehavior = .autoScroll
    var interaction: TextPreviewInteraction = .readOnly

    fileprivate enum ScrollTarget {
        case top
        case highlight(utf16Start: UInt64, utf16End: UInt64)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        // Use PreviewTextView for custom key handling (Cmd+Return, Cmd+S, Escape)
        // NSTextView() defaults to TextKit 2 on macOS 12+.
        // IMPORTANT: never access .layoutManager — that silently downgrades to TextKit 1.
        let textView = PreviewTextView()
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
        applyInteraction(to: textView, coordinator: context.coordinator)

        scrollView.documentView = textView
        return scrollView
    }

    /// Last known container width, persisted across view recreations so the
    /// first render already uses a good value instead of falling back to base font.
    private static var lastKnownContainerWidth: CGFloat = 0

    private func scaledFontSize(containerWidth: CGFloat) -> CGFloat {
        let text = TextPreviewView.textCache[itemId] ?? ""
        return Self.scaledFontSize(
            text: text,
            fontName: fontName,
            fontSize: fontSize,
            containerWidth: containerWidth
        )
    }

    static func scaledFontSize(
        text: String,
        fontName: String,
        fontSize: CGFloat,
        containerWidth: CGFloat
    ) -> CGFloat {
        let nsText = text as NSString
        guard nsText.length <= maxAutoScaleCharacters else { return fontSize }

        let baseFont = NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let inset: CGFloat = 32 + 10 // textContainerInset.width * 2 + lineFragmentPadding * 2
        let availableWidth = containerWidth - inset
        if availableWidth <= 0 { return fontSize }

        let attributes: [NSAttributedString.Key: Any] = [.font: baseFont]
        let fullRange = NSRange(location: 0, length: nsText.length)
        var lineCount = 0
        var maxLineWidth: CGFloat = 0

        nsText.enumerateSubstrings(
            in: fullRange,
            options: [.byLines]
        ) { substring, _, _, stop in
            lineCount += 1
            guard lineCount <= maxAutoScaleLines else {
                stop.pointee = true
                return
            }

            let lineWidth = (substring as NSString? ?? "").size(withAttributes: attributes).width
            maxLineWidth = max(maxLineWidth, lineWidth)

            // For items with many lines, stop early if a line already fills the width
            if lineWidth >= availableWidth, lineCount > 2 || nsText.length > 200 {
                stop.pointee = true
                return
            }
        }

        if lineCount == 0 || lineCount > maxAutoScaleLines { return fontSize }
        if maxLineWidth <= 0 { return fontSize }

        // Never shrink below the base font size: a single very long line would
        // otherwise drive rawScale toward zero and make the preview unreadable.
        // Text that overflows the container simply wraps at the base size.
        let rawScale = availableWidth / maxLineWidth
        let scale = min(1.5, max(rawScale, 1.0)) * 0.95
        return fontSize * scale
    }

    private func installFocusHandler(
        on textView: PreviewTextView,
        coordinator: Coordinator,
        onEditingStateChange: ((Bool) -> Void)?
    ) {
        textView.onFocusChange = { [weak coordinator] isFocused in
            onEditingStateChange?(isFocused)

            guard isFocused, let coordinator else { return }

            // Hand scroll control to the user once they click into the preview.
            // Otherwise a still-armed highlight recenter can fire during the
            // focus/layout transition and jump back to the active match.
            coordinator.clearUsageBoundsRecentering()
            coordinator.clearViewportRetry()
            coordinator.resetKvoReScrollCount()
            coordinator.scrollGeneration += 1
        }
    }

    private func applyInteraction(
        to textView: PreviewTextView,
        coordinator: Coordinator
    ) {
        textView.isSelectable = true

        switch interaction {
        case .readOnly:
            textView.isEditable = false
            textView.onCmdReturn = nil
            textView.onCmdK = nil
            textView.onSave = nil
            textView.onEscape = nil
            coordinator.onTextChange = nil
            installFocusHandler(on: textView, coordinator: coordinator, onEditingStateChange: nil)
        case let .editable(actions):
            textView.isEditable = true
            textView.onCmdReturn = actions.onCmdReturn
            textView.onCmdK = actions.onCmdK
            textView.onSave = actions.onSave
            textView.onEscape = actions.onEscape
            coordinator.onTextChange = actions.onTextChange
            installFocusHandler(
                on: textView,
                coordinator: coordinator,
                onEditingStateChange: actions.onEditingStateChange
            )
        }
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? PreviewTextView else { return }

        let coordinator = context.coordinator
        coordinator.observeUsageBounds(of: textView)

        let itemChanged = coordinator.currentItemId != itemId
        if itemChanged {
            coordinator.prepareForDisplayedItemChange(to: itemId, in: textView)
        }

        applyInteraction(to: textView, coordinator: coordinator)
        textView.onViewportLayoutDidLayout = { [weak coordinator] observedTextView, textViewportLayoutController in
            guard let coordinator,
                  scrollBehavior != .manual,
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
            // PERF FIX: Do NOT set needsGeometrySync here. The layout pass that triggered
            // this callback already stabilized geometry. Re-syncing would create a feedback
            // loop: layout → viewport callback → geometry sync → layout → callback → ...
            DispatchQueue.main.async { [weak coordinator, weak observedTextView] in
                guard let coordinator,
                      let observedTextView,
                      coordinator.scrollGeneration == generation else { return }
                // Skip flushPendingDisplay — the viewport controller just completed layout.
                // Flushing here triggers additional layout passes that feed back into KVO.
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
                  scrollBehavior != .manual,
                  let target = coordinator.activeUsageBoundsTarget() else { return }
            // PERF FIX: Do NOT set needsGeometrySync here. The layout pass that changed
            // usageBounds already handled geometry. Re-syncing creates a feedback loop:
            // geometry sync → layoutViewport → usageBounds KVO → geometry sync → ...
            // Also limit KVO-driven re-scroll attempts to prevent runaway iteration.
            guard coordinator.consumeKvoReScrollAttempt() else { return }
            self.performScrollAttempt(
                textView: observedTextView,
                target: target,
                generation: coordinator.scrollGeneration,
                coordinator: coordinator,
                attempt: 0
            )
        }

        // Use live container width if available, otherwise fall back to persisted value
        let containerWidth = nsView.contentSize.width > 0
            ? nsView.contentSize.width
            : Self.lastKnownContainerWidth
        if nsView.contentSize.width > 0 {
            Self.lastKnownContainerWidth = nsView.contentSize.width
        }

        let textChanged = itemChanged ? true : textView.string != (TextPreviewView.textCache[itemId] ?? "")
        let highlightsChanged = coordinator.lastHighlights != highlights
        let contentWidthChanged = abs(coordinator.lastContentWidth - containerWidth) > 0.5
        let fontChanged = coordinator.lastFontName != fontName
        let fontSizeChanged = abs(coordinator.lastFontSize - fontSize) > 0.01
        let gainedHighlights = !highlights.isEmpty && coordinator.lastHighlights.isEmpty

        guard itemChanged || textChanged || highlightsChanged || contentWidthChanged || fontChanged || fontSizeChanged else {
            return
        }
        coordinator.lastContentWidth = containerWidth
        coordinator.lastFontName = fontName
        coordinator.lastFontSize = fontSize
        if itemChanged || textChanged || contentWidthChanged || fontChanged || fontSizeChanged || gainedHighlights {
            coordinator.needsGeometrySync = true
        }

        let scaledSize: CGFloat
        if itemChanged || textChanged || contentWidthChanged || fontChanged || fontSizeChanged {
            scaledSize = scaledFontSize(containerWidth: containerWidth)
            coordinator.lastScaledFontSize = scaledSize
        } else {
            scaledSize = coordinator.lastScaledFontSize ?? fontSize
        }
        let font = NSFont(name: fontName, size: scaledSize)
            ?? NSFont.monospacedSystemFont(ofSize: scaledSize, weight: .regular)

        // Only mutate TextKit geometry when preview content or container width changed.
        // Focus-only SwiftUI updates should not touch the text view at all because even
        // redundant geometry writes can trigger AppKit to keep the insertion point visible.
        textView.textContainer?.containerSize = NSSize(
            width: containerWidth,
            height: .greatestFiniteMagnitude
        )
        textView.frame = NSRect(x: 0, y: 0, width: containerWidth, height: textView.frame.height)

        // Set typing attributes for consistent font during editing.
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle,
        ]

        let text = TextPreviewView.textCache[itemId] ?? ""

        let previousMatchRanges = coordinator.currentMatchRanges
        let tlm = textView.textLayoutManager
        if let tlm,
           itemChanged || textChanged || highlightsChanged || fontChanged || fontSizeChanged,
           !previousMatchRanges.isEmpty
        {
            clearHighlightRenderingAttributes(matchRanges: previousMatchRanges, from: tlm)
        }

        // Reset the text view's attributed content when the highlight set changes for the
        // same item. This reuses the same preview view but gives TextKit a clean baseline
        // for the new overlay, which is much lighter than a full item reset.
        let shouldUpdateText = itemChanged ||
            (!coordinator.isEditing && (textChanged || highlightsChanged || fontChanged || fontSizeChanged))
        if shouldUpdateText {
            let text = TextPreviewView.textCache[itemId] ?? ""
            // Text content changed — replace storage attributes (font, color, paragraph style only).
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
            coordinator.lastRenderedText = text // Update cache!
            if itemChanged {
                coordinator.resetTextInteractionState(in: textView)
            }
        }

        if itemChanged || textChanged || highlightsChanged || fontChanged || fontSizeChanged {
            // Convert highlights to NSTextRanges for the layout manager
            let newMatchRanges = resolveTextRanges(highlights: highlights, text: text, layoutManager: tlm)

            coordinator.currentMatchRanges = newMatchRanges
            coordinator.lastHighlights = highlights

            applyHighlightAttributes(matchRanges: newMatchRanges, to: textView)
            refreshHighlightDisplay(textView: textView)
        }

        let scrollTarget: ScrollTarget
        if highlights.isEmpty {
            scrollTarget = .top
        } else {
            let targetHighlight: Utf16HighlightRange
            if let initialScrollHighlightIndex {
                let index = Int(initialScrollHighlightIndex)
                if highlights.indices.contains(index) {
                    targetHighlight = highlights[index]
                } else {
                    targetHighlight = highlights[0]
                }
            } else {
                targetHighlight = highlights[0]
            }
            scrollTarget = .highlight(
                utf16Start: targetHighlight.utf16Start,
                utf16End: targetHighlight.utf16End
            )
        }

        if scrollBehavior != .manual {
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

    /// Convert UTF-16 highlight ranges to TextKit 2 ranges using the text layout manager.
    private func resolveTextRanges(
        highlights: [Utf16HighlightRange],
        text _: String,
        layoutManager: NSTextLayoutManager?
    ) -> [MatchRange] {
        guard let tlm = layoutManager,
              let tcm = tlm.textContentManager else { return [] }

        return highlights.compactMap { highlight in
            let nsRange = highlight.nsRange

            guard let start = tcm.location(tcm.documentRange.location, offsetBy: nsRange.location),
                  let end = tcm.location(start, offsetBy: nsRange.length) else { return nil }

            guard let textRange = NSTextRange(location: start, end: end) else { return nil }
            return MatchRange(
                range: textRange,
                utf16Start: highlight.utf16Start,
                utf16End: highlight.utf16End,
                kind: highlight.kind
            )
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
        coordinator.resetKvoReScrollCount()
        switch target {
        case .top:
            coordinator.clearUsageBoundsRecentering()
        case .highlight:
            // Only arm KVO-based recentering for user navigation (arrow keys, clicks).
            // During search-driven changes, results churn rapidly and the recentering
            // window (previously 750ms) never expires, creating a layout feedback loop.
            if scrollBehavior == .trackHighlight {
                coordinator.armUsageBoundsRecentering(target: target, duration: 0.25)
            } else {
                coordinator.clearUsageBoundsRecentering()
            }
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
            guard case let .highlight(utf16Start, utf16End) = target else { return }
            guard let targetMatchRange = coordinator.currentMatchRanges.first(where: {
                $0.utf16Start == utf16Start && $0.utf16End == utf16End
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
    }

    private func refreshHighlightDisplay(textView: NSTextView) {
        textView.layoutSubtreeIfNeeded()
        textView.setNeedsDisplay(textView.visibleRect)

        if let scrollView = textView.enclosingScrollView {
            scrollView.contentView.setNeedsDisplay(scrollView.contentView.bounds)
        }
    }

    private func clearHighlightRenderingAttributes(
        matchRanges: [MatchRange],
        from textLayoutManager: NSTextLayoutManager
    ) {
        for matchRange in matchRanges {
            textLayoutManager.removeRenderingAttribute(.backgroundColor, for: matchRange.range)
            textLayoutManager.removeRenderingAttribute(.underlineStyle, for: matchRange.range)
            textLayoutManager.invalidateRenderingAttributes(for: matchRange.range)
        }
    }

    private func applyHighlightAttributes(
        matchRanges: [MatchRange],
        to textView: NSTextView
    ) {
        guard let textLayoutManager = textView.textLayoutManager else { return }

        for matchRange in matchRanges {
            textLayoutManager.setRenderingAttributes(
                HighlightStyler.attributes(for: matchRange.kind),
                for: matchRange.range
            )
        }
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

    /// A resolved match: the original UTF-16 indices (for identity) plus the TextKit 2 range (for operations).
    struct MatchRange {
        let range: NSTextRange
        let utf16Start: UInt64
        let utf16End: UInt64
        let kind: HighlightKind
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var lastHighlights: [Utf16HighlightRange] = []
        /// Current match ranges for diffing on next update.
        var currentMatchRanges: [MatchRange] = []
        var scrollGeneration: Int = 0
        var lastContentWidth: CGFloat = 0
        var lastFontName: String?
        var lastFontSize: CGFloat = 0
        var lastScaledFontSize: CGFloat?
        var lastUsageBounds: CGRect = .zero
        var needsGeometrySync: Bool = false
        private var pendingScrollTarget: ScrollTarget?
        private var pendingAutoScrollExpiration: Date = .distantPast
        private var pendingViewportRetryGeneration: Int?
        fileprivate var onUsageBoundsChange: ((PreviewTextView) -> Void)?
        private var usageBoundsObservation: NSKeyValueObservation?
        fileprivate weak var observedTextView: PreviewTextView?

        /// Limits how many KVO-driven re-scroll attempts can fire per scroll() call.
        /// Prevents the layout feedback loop where KVO → scroll → layout → KVO → ...
        private var kvoReScrollCount = 0
        private static let maxKvoReScrollAttempts = 2

        // Edit tracking
        var currentItemId: String = ""
        var lastRenderedText: String?
        var isEditing = false
        var onTextChange: ((String) -> Void)?

        deinit {
            usageBoundsObservation?.invalidate()
        }

        fileprivate func prepareForDisplayedItemChange(to itemId: String, in textView: PreviewTextView) {
            scrollGeneration += 1
            clearUsageBoundsRecentering()
            clearViewportRetry()
            resetKvoReScrollCount()

            if textView.window?.firstResponder === textView {
                textView.window?.makeFirstResponder(nil)
            }

            currentItemId = itemId
            isEditing = false
            currentMatchRanges = []
            lastHighlights = []
            lastUsageBounds = textView.textLayoutManager?.usageBoundsForTextContainer ?? .zero
            needsGeometrySync = true
        }

        fileprivate func resetTextInteractionState(in textView: PreviewTextView) {
            if textView.hasMarkedText() {
                textView.unmarkText()
            }
            textView.undoManager?.removeAllActions()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
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

        fileprivate func resetKvoReScrollCount() {
            kvoReScrollCount = 0
        }

        /// Returns true if a KVO re-scroll attempt is allowed, false if the limit is reached.
        fileprivate func consumeKvoReScrollAttempt() -> Bool {
            guard kvoReScrollCount < Self.maxKvoReScrollAttempts else { return false }
            kvoReScrollCount += 1
            return true
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
            let text = textView.string
            lastRenderedText = text
            onTextChange(text)
        }
    }
}
