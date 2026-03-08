import AppKit
import SwiftUI
import ClipKittyRust

/// Shared highlighting logic for both preview pane (NSTextView) and item rows (SwiftUI Text).
/// All index calculations use Unicode scalars to match Rust's `.chars()` counting.
enum HighlightStyler {

    // MARK: - Colors (shared between NSTextView and SwiftUI)

    static func nsColor(for kind: HighlightKind) -> NSColor {
        switch kind {
        case .exact, .prefix:
            return NSColor.yellow.withAlphaComponent(0.4)
        case .fuzzy:
            return NSColor.orange.withAlphaComponent(0.3)
        case .subsequence:
            return NSColor.orange.withAlphaComponent(0.2)
        }
    }

    static func color(for kind: HighlightKind) -> Color {
        switch kind {
        case .exact, .prefix:
            return Color.yellow.opacity(0.4)
        case .fuzzy:
            return Color.orange.opacity(0.3)
        case .subsequence:
            return Color.orange.opacity(0.2)
        }
    }

    static func usesUnderline(_ kind: HighlightKind) -> Bool {
        kind == .subsequence
    }

    // MARK: - NSAttributedString Attributes

    static func attributes(for kind: HighlightKind) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .backgroundColor: nsColor(for: kind)
        ]
        if usesUnderline(kind) {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    // MARK: - NSAttributedString Application (for TextPreviewView)

    /// Apply highlights to an NSMutableAttributedString.
    /// Uses `nsRange(in:)` for correct Unicode scalar → UTF-16 conversion.
    static func applyHighlights(
        _ highlights: [HighlightRange],
        to attributed: NSMutableAttributedString,
        text: String
    ) {
        for range in highlights {
            let nsRange = range.nsRange(in: text)
            if nsRange.location != NSNotFound && nsRange.location + nsRange.length <= attributed.length {
                let attrs = attributes(for: range.kind)
                for (key, value) in attrs {
                    attributed.addAttribute(key, value: value, range: nsRange)
                }
            }
        }
    }

    // MARK: - SwiftUI Text Support

    /// Split text into prefix/match/suffix for the three-part HStack layout.
    /// Uses Unicode scalars for correct indexing (matches Rust's char indices).
    static func splitText(
        _ text: String,
        highlight: HighlightRange
    ) -> (prefix: String, match: String, suffix: String) {
        let scalars = text.unicodeScalars
        let startIdx = Int(highlight.start)
        let endIdx = Int(highlight.end)

        // Bounds check against scalar count (NOT text.count which uses grapheme clusters)
        let safeStart = min(max(0, startIdx), scalars.count)
        let safeEnd = min(max(safeStart, endIdx), scalars.count)

        // Convert scalar indices to String.Index via unicodeScalars
        let scalarStart = scalars.index(scalars.startIndex, offsetBy: safeStart)
        let scalarEnd = scalars.index(scalars.startIndex, offsetBy: safeEnd)

        let prefix = String(scalars[scalars.startIndex..<scalarStart])
        let match = String(scalars[scalarStart..<scalarEnd])
        let suffix = String(scalars[scalarEnd..<scalars.endIndex])

        return (prefix, match, suffix)
    }

    /// Check if a highlight falls within the suffix region.
    /// Uses Unicode scalars for correct bounds checking.
    static func highlightInSuffix(
        _ highlight: HighlightRange,
        suffixStartScalarIndex: Int,
        suffixScalarCount: Int
    ) -> Bool {
        let start = Int(highlight.start)
        return start >= suffixStartScalarIndex && start < suffixStartScalarIndex + suffixScalarCount
    }

    /// Apply multiple highlights to suffix text as AttributedString.
    /// Uses Unicode scalars for correct indexing (matches Rust's char indices).
    static func attributedSuffix(
        _ suffix: String,
        suffixStartScalarIndex: Int,
        highlights: [HighlightRange]
    ) -> AttributedString {
        var attributed = AttributedString(suffix)
        let suffixScalars = suffix.unicodeScalars

        for highlight in highlights {
            let relativeStart = Int(highlight.start) - suffixStartScalarIndex
            let relativeEnd = Int(highlight.end) - suffixStartScalarIndex

            // Bounds check against scalar count (NOT suffix.count)
            let safeStart = max(0, relativeStart)
            let safeEnd = min(suffixScalars.count, relativeEnd)
            guard safeStart < safeEnd else { continue }

            // Convert scalar indices to AttributedString indices via unicodeScalars
            let scalarStart = suffixScalars.index(suffixScalars.startIndex, offsetBy: safeStart)
            let scalarEnd = suffixScalars.index(suffixScalars.startIndex, offsetBy: safeEnd)

            guard let attrStart = AttributedString.Index(scalarStart, within: attributed),
                  let attrEnd = AttributedString.Index(scalarEnd, within: attributed) else {
                continue
            }

            attributed[attrStart..<attrEnd].backgroundColor = color(for: highlight.kind)
            if usesUnderline(highlight.kind) {
                attributed[attrStart..<attrEnd].underlineStyle = .single
            }
        }

        return attributed
    }
}
