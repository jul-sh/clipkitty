import AppKit
import SwiftUI
import ClipKittyRust

/// Shared highlighting logic for both preview pane (NSTextView) and item rows (SwiftUI Text).
/// All index calculations use Unicode scalars to match Rust's `.chars()` counting.
enum HighlightStyler {

    struct Appearance {
        let nsBackgroundColor: NSColor
        let swiftBackgroundColor: Color
        let underlineStyle: NSUnderlineStyle?
    }

    // MARK: - Colors (shared between NSTextView and SwiftUI)

    static func appearance(for kind: HighlightKind) -> Appearance {
        switch kind {
        case .exact, .prefix:
            Appearance(
                nsBackgroundColor: NSColor.yellow.withAlphaComponent(0.4),
                swiftBackgroundColor: Color.yellow.opacity(0.4),
                underlineStyle: nil
            )
        case .fuzzy:
            Appearance(
                nsBackgroundColor: NSColor.orange.withAlphaComponent(0.3),
                swiftBackgroundColor: Color.orange.opacity(0.3),
                underlineStyle: nil
            )
        case .subsequence:
            Appearance(
                nsBackgroundColor: NSColor.orange.withAlphaComponent(0.2),
                swiftBackgroundColor: Color.orange.opacity(0.2),
                underlineStyle: .single
            )
        }
    }

    static func nsColor(for kind: HighlightKind) -> NSColor {
        appearance(for: kind).nsBackgroundColor
    }

    static func color(for kind: HighlightKind) -> Color {
        appearance(for: kind).swiftBackgroundColor
    }

    static func usesUnderline(_ kind: HighlightKind) -> Bool {
        appearance(for: kind).underlineStyle != nil
    }

    // MARK: - NSAttributedString Attributes

    static func attributes(for kind: HighlightKind) -> [NSAttributedString.Key: Any] {
        let appearance = appearance(for: kind)
        var attrs: [NSAttributedString.Key: Any] = [
            .backgroundColor: appearance.nsBackgroundColor
        ]
        if let underlineStyle = appearance.underlineStyle {
            attrs[.underlineStyle] = underlineStyle.rawValue
        }
        return attrs
    }

    // MARK: - Rendering Attributes (for TextKit 2 TextPreviewView)

    /// Rendering attributes for a highlight kind.
    /// Applied via `NSTextLayoutManager.setRenderingAttributes(_:for:)` to style
    /// highlights without mutating NSTextContentStorage.
    static func renderingAttributes(for kind: HighlightKind) -> [NSAttributedString.Key: Any] {
        attributes(for: kind)
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
        apply(highlights: highlights, to: &attributed, scalarOffset: suffixStartScalarIndex)
        return attributed
    }

    static func attributedText(
        _ text: String,
        highlights: [HighlightRange]
    ) -> AttributedString {
        var attributed = AttributedString(text)
        apply(highlights: highlights, to: &attributed, scalarOffset: 0)
        return attributed
    }

    static func exactHighlights(
        in text: String,
        queryWords: [String]
    ) -> [HighlightRange] {
        let normalizedWords = queryWords.filter { !$0.isEmpty }
        guard !normalizedWords.isEmpty else { return [] }

        let nsText = text as NSString
        var highlights: [HighlightRange] = []

        for word in normalizedWords {
            var searchRange = NSRange(location: 0, length: nsText.length)
            while searchRange.length > 0 {
                let matchRange = nsText.range(
                    of: word,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange
                )
                guard matchRange.location != NSNotFound else { break }
                if let highlight = highlightRange(from: matchRange, in: text, kind: .exact) {
                    highlights.append(highlight)
                }

                let nextLocation = matchRange.location + max(matchRange.length, 1)
                guard nextLocation <= nsText.length else { break }
                searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
            }
        }

        return mergeOverlapping(highlights)
    }

    private static func apply(
        highlights: [HighlightRange],
        to attributed: inout AttributedString,
        scalarOffset: Int
    ) {
        // Convert AttributedString to String to access unicodeScalars
        let text = String(attributed.characters)
        let scalars = text.unicodeScalars

        for highlight in highlights {
            let relativeStart = Int(highlight.start) - scalarOffset
            let relativeEnd = Int(highlight.end) - scalarOffset

            // Bounds check against scalar count (NOT text.count)
            let safeStart = max(0, relativeStart)
            let safeEnd = min(scalars.count, relativeEnd)
            guard safeStart < safeEnd else { continue }

            let scalarStart = scalars.index(scalars.startIndex, offsetBy: safeStart)
            let scalarEnd = scalars.index(scalars.startIndex, offsetBy: safeEnd)

            guard let attrStart = AttributedString.Index(scalarStart, within: attributed),
                  let attrEnd = AttributedString.Index(scalarEnd, within: attributed) else {
                continue
            }

            let appearance = appearance(for: highlight.kind)
            attributed[attrStart..<attrEnd].backgroundColor = appearance.swiftBackgroundColor
            if appearance.underlineStyle != nil {
                attributed[attrStart..<attrEnd].underlineStyle = .single
            }
        }
    }

    private static func highlightRange(
        from nsRange: NSRange,
        in text: String,
        kind: HighlightKind
    ) -> HighlightRange? {
        guard let stringRange = Range(nsRange, in: text),
              let scalarStart = stringRange.lowerBound.samePosition(in: text.unicodeScalars),
              let scalarEnd = stringRange.upperBound.samePosition(in: text.unicodeScalars) else {
            return nil
        }

        let start = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: scalarStart)
        let end = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: scalarEnd)
        return HighlightRange(start: UInt64(start), end: UInt64(end), kind: kind)
    }

    private static func mergeOverlapping(_ highlights: [HighlightRange]) -> [HighlightRange] {
        let sortedHighlights = highlights.sorted {
            if $0.start == $1.start {
                return $0.end < $1.end
            }
            return $0.start < $1.start
        }

        var merged: [HighlightRange] = []
        for highlight in sortedHighlights {
            guard let last = merged.last else {
                merged.append(highlight)
                continue
            }

            if highlight.start <= last.end {
                merged[merged.count - 1] = HighlightRange(
                    start: last.start,
                    end: max(last.end, highlight.end),
                    kind: last.kind
                )
            } else {
                merged.append(highlight)
            }
        }

        return merged
    }
}
