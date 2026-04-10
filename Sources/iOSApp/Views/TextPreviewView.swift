import ClipKittyRust
import ClipKittyShared
import SwiftUI
import UIKit

/// iOS TextKit 2 preview renderer for text/color items.
/// Renders Rust-provided highlights via `NSTextLayoutManager.setRenderingAttributes`
/// without mutating text storage. Supports inline editing with text change callbacks.
struct TextPreviewView: UIViewRepresentable {
    let itemId: String
    let text: String
    var highlights: [Utf16HighlightRange] = []
    var initialScrollHighlightIndex: UInt64?
    var isEditable: Bool = true

    var onTextChange: ((String) -> Void)?
    var onEditingStateChange: ((Bool) -> Void)?

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.font = UIFont(name: FontManager.mono, size: 16)
            ?? UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.textColor = .label
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.accessibilityIdentifier = "PreviewTextView"

        textView.delegate = context.coordinator
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onEditingStateChange = onEditingStateChange

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator
        let itemChanged = coordinator.currentItemId != itemId

        if itemChanged {
            coordinator.currentItemId = itemId
            coordinator.isEditing = false
            coordinator.lastHighlights = []
            coordinator.currentMatchRanges = []
        }

        coordinator.onTextChange = onTextChange
        coordinator.onEditingStateChange = onEditingStateChange
        textView.isEditable = isEditable

        let textChanged = itemChanged || (!coordinator.isEditing && textView.text != text)
        let highlightsChanged = coordinator.lastHighlights != highlights

        guard itemChanged || textChanged || highlightsChanged else { return }

        // Clear previous highlights
        if let tlm = textView.textLayoutManager, !coordinator.currentMatchRanges.isEmpty {
            clearHighlightRenderingAttributes(matchRanges: coordinator.currentMatchRanges, from: tlm)
        }

        if textChanged {
            let font = UIFont(name: FontManager.mono, size: 16)
                ?? UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraphStyle,
            ])
            textView.attributedText = attributed

            if itemChanged {
                textView.setContentOffset(.zero, animated: false)
                textView.selectedRange = NSRange(location: 0, length: 0)
            }
        }

        // Resolve and apply new highlights
        let newMatchRanges = resolveTextRanges(highlights: highlights, layoutManager: textView.textLayoutManager)
        coordinator.currentMatchRanges = newMatchRanges
        coordinator.lastHighlights = highlights
        applyHighlightAttributes(matchRanges: newMatchRanges, to: textView)

        // Scroll to initial highlight
        if (itemChanged || highlightsChanged), !highlights.isEmpty {
            let targetHighlight: Utf16HighlightRange
            if let initialScrollHighlightIndex {
                let index = Int(initialScrollHighlightIndex)
                targetHighlight = highlights.indices.contains(index) ? highlights[index] : highlights[0]
            } else {
                targetHighlight = highlights[0]
            }
            scrollToHighlight(targetHighlight, in: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Highlight Resolution

    struct MatchRange {
        let range: NSTextRange
        let utf16Start: UInt64
        let utf16End: UInt64
        let kind: HighlightKind
    }

    private func resolveTextRanges(
        highlights: [Utf16HighlightRange],
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

    private func clearHighlightRenderingAttributes(
        matchRanges: [MatchRange],
        from textLayoutManager: NSTextLayoutManager
    ) {
        for matchRange in matchRanges {
            textLayoutManager.removeRenderingAttribute(.backgroundColor, for: matchRange.range)
            textLayoutManager.removeRenderingAttribute(.underlineStyle, for: matchRange.range)
        }
    }

    private func applyHighlightAttributes(
        matchRanges: [MatchRange],
        to textView: UITextView
    ) {
        guard let textLayoutManager = textView.textLayoutManager else { return }

        for matchRange in matchRanges {
            let style = HighlightAppearance.style(for: matchRange.kind)
            var attrs: [NSAttributedString.Key: Any] = [
                .backgroundColor: UIColor(style.backgroundColor),
            ]
            if style.underlineStyle {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            textLayoutManager.setRenderingAttributes(attrs, for: matchRange.range)
        }
    }

    // MARK: - Scroll

    private func scrollToHighlight(_ highlight: Utf16HighlightRange, in textView: UITextView) {
        let nsRange = highlight.nsRange
        guard nsRange.location + nsRange.length <= (textView.text as NSString).length else { return }

        // Use UITextView's built-in scroll with a slight delay to ensure layout is ready
        DispatchQueue.main.async {
            guard let start = textView.position(from: textView.beginningOfDocument, offset: nsRange.location),
                  let end = textView.position(from: start, offset: nsRange.length),
                  let textRange = textView.textRange(from: start, to: end)
            else { return }

            let rect = textView.firstRect(for: textRange)
            guard !rect.isNull, !rect.isInfinite else { return }

            // Place the highlight roughly 1/3 from the top
            let visibleHeight = textView.bounds.height - textView.contentInset.top - textView.contentInset.bottom
            let targetY = rect.midY - (visibleHeight / 3)
            let maxY = max(0, textView.contentSize.height - textView.bounds.height)
            let clampedY = min(max(0, targetY), maxY)
            textView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: false)
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UITextViewDelegate {
        var lastHighlights: [Utf16HighlightRange] = []
        var currentMatchRanges: [MatchRange] = []
        var currentItemId: String = ""
        var isEditing = false
        var onTextChange: ((String) -> Void)?
        var onEditingStateChange: ((Bool) -> Void)?

        func textViewDidBeginEditing(_ textView: UITextView) {
            isEditing = true
            onEditingStateChange?(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isEditing = false
            onEditingStateChange?(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            onTextChange?(textView.text)
        }
    }
}
