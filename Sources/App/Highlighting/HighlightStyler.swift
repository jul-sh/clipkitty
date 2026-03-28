import AppKit
import ClipKittyRust
import SwiftUI

/// Shared highlighting logic for list rows and file previews using UI-native UTF-16 ranges.
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
        case .prefixTail:
            Appearance(
                nsBackgroundColor: NSColor.yellow.withAlphaComponent(0.16),
                swiftBackgroundColor: Color.yellow.opacity(0.16),
                underlineStyle: nil
            )
        case .subwordPrefix:
            Appearance(
                nsBackgroundColor: NSColor.yellow.withAlphaComponent(0.28),
                swiftBackgroundColor: Color.yellow.opacity(0.28),
                underlineStyle: nil
            )
        case .substring:
            Appearance(
                nsBackgroundColor: NSColor.orange.withAlphaComponent(0.2),
                swiftBackgroundColor: Color.orange.opacity(0.2),
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
            .backgroundColor: appearance.nsBackgroundColor,
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
    static func splitText(
        _ text: String,
        highlight: Utf16HighlightRange
    ) -> (prefix: String, match: String, suffix: String) {
        guard let range = stringRange(
            utf16Start: Int(highlight.utf16Start),
            utf16End: Int(highlight.utf16End),
            in: text
        ) else {
            return (text, "", "")
        }

        let prefix = String(text[..<range.lowerBound])
        let match = String(text[range])
        let suffix = String(text[range.upperBound...])
        return (prefix, match, suffix)
    }

    /// Check if a highlight falls within the suffix region.
    static func highlightInSuffix(
        _ highlight: Utf16HighlightRange,
        suffixStartUtf16Offset: Int,
        suffixUtf16Count: Int
    ) -> Bool {
        let start = Int(highlight.utf16Start)
        return start >= suffixStartUtf16Offset && start < suffixStartUtf16Offset + suffixUtf16Count
    }

    /// Apply multiple highlights to suffix text as AttributedString.
    static func attributedSuffix(
        _ suffix: String,
        suffixStartUtf16Offset: Int,
        highlights: [Utf16HighlightRange]
    ) -> AttributedString {
        var attributed = AttributedString(suffix)
        apply(highlights: highlights, to: &attributed, utf16Offset: suffixStartUtf16Offset)
        return attributed
    }

    static func attributedText(
        _ text: String,
        highlights: [Utf16HighlightRange]
    ) -> AttributedString {
        var attributed = AttributedString(text)
        apply(highlights: highlights, to: &attributed, utf16Offset: 0)
        return attributed
    }

    static func attributedFragment(
        _ text: String,
        kind: HighlightKind
    ) -> AttributedString {
        attributedText(text, highlights: [
            Utf16HighlightRange(
                utf16Start: 0,
                utf16End: UInt64(text.utf16.count),
                kind: kind
            ),
        ])
    }

    static func fragments(
        in text: String,
        highlights: [Utf16HighlightRange]
    ) -> [String] {
        highlights.compactMap { highlight in
            guard let range = stringRange(
                utf16Start: Int(highlight.utf16Start),
                utf16End: Int(highlight.utf16End),
                in: text
            ) else {
                return nil
            }
            return String(text[range])
        }
    }

    static func exactHighlights(
        in text: String,
        queryWords: [String]
    ) -> [Utf16HighlightRange] {
        let normalizedWords = queryWords.filter { !$0.isEmpty }
        guard !normalizedWords.isEmpty else { return [] }

        let nsText = text as NSString
        var highlights: [Utf16HighlightRange] = []

        for word in normalizedWords {
            var searchRange = NSRange(location: 0, length: nsText.length)
            while searchRange.length > 0 {
                let matchRange = nsText.range(
                    of: word,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange
                )
                guard matchRange.location != NSNotFound else { break }
                highlights.append(Utf16HighlightRange(
                    utf16Start: UInt64(matchRange.location),
                    utf16End: UInt64(matchRange.location + matchRange.length),
                    kind: .exact
                ))

                let nextLocation = matchRange.location + max(matchRange.length, 1)
                guard nextLocation <= nsText.length else { break }
                searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
            }
        }

        return mergeOverlapping(highlights)
    }

    private static func apply(
        highlights: [Utf16HighlightRange],
        to attributed: inout AttributedString,
        utf16Offset: Int
    ) {
        let text = String(attributed.characters)

        for highlight in highlights {
            let relativeStart = Int(highlight.utf16Start) - utf16Offset
            let relativeEnd = Int(highlight.utf16End) - utf16Offset

            guard let range = stringRange(
                utf16Start: relativeStart,
                utf16End: relativeEnd,
                in: text
            ),
                let attrStart = AttributedString.Index(range.lowerBound, within: attributed),
                let attrEnd = AttributedString.Index(range.upperBound, within: attributed)
            else {
                continue
            }

            let appearance = appearance(for: highlight.kind)
            attributed[attrStart ..< attrEnd].backgroundColor = appearance.swiftBackgroundColor
            if appearance.underlineStyle != nil {
                attributed[attrStart ..< attrEnd].underlineStyle = .single
            }
        }
    }

    private static func stringRange(
        utf16Start: Int,
        utf16End: Int,
        in text: String
    ) -> Range<String.Index>? {
        guard utf16Start >= 0, utf16End >= utf16Start, utf16End <= text.utf16.count else {
            return nil
        }

        let utf16 = text.utf16
        let start = utf16.index(utf16.startIndex, offsetBy: utf16Start)
        let end = utf16.index(utf16.startIndex, offsetBy: utf16End)
        guard let stringStart = String.Index(start, within: text),
              let stringEnd = String.Index(end, within: text)
        else {
            return nil
        }
        return stringStart ..< stringEnd
    }

    private static func mergeOverlapping(_ highlights: [Utf16HighlightRange]) -> [Utf16HighlightRange] {
        let sortedHighlights = highlights.sorted {
            if $0.utf16Start == $1.utf16Start {
                return $0.utf16End < $1.utf16End
            }
            return $0.utf16Start < $1.utf16Start
        }

        var merged: [Utf16HighlightRange] = []
        for highlight in sortedHighlights {
            guard let last = merged.last else {
                merged.append(highlight)
                continue
            }

            if highlight.utf16Start <= last.utf16End {
                merged[merged.count - 1] = Utf16HighlightRange(
                    utf16Start: last.utf16Start,
                    utf16End: max(last.utf16End, highlight.utf16End),
                    kind: last.kind
                )
            } else {
                merged.append(highlight)
            }
        }

        return merged
    }
}
