import ClipKittyRust
import Foundation
import SwiftUI

/// Cross-platform highlight appearance and UTF-16 range conversion helpers.
/// Used by both macOS and iOS surfaces to render Rust-provided highlights.
public enum HighlightAppearance {
    public struct Style {
        public let backgroundColor: Color
        public let underlineStyle: Bool

        public init(backgroundColor: Color, underlineStyle: Bool) {
            self.backgroundColor = backgroundColor
            self.underlineStyle = underlineStyle
        }
    }

    public static func style(for kind: HighlightKind) -> Style {
        switch kind {
        case .exact, .prefix:
            Style(backgroundColor: Color.yellow.opacity(0.4), underlineStyle: false)
        case .prefixTail:
            Style(backgroundColor: Color.yellow.opacity(0.16), underlineStyle: false)
        case .subwordPrefix:
            Style(backgroundColor: Color.yellow.opacity(0.28), underlineStyle: false)
        case .substring:
            Style(backgroundColor: Color.orange.opacity(0.2), underlineStyle: false)
        case .fuzzy:
            Style(backgroundColor: Color.orange.opacity(0.3), underlineStyle: false)
        case .subsequence:
            Style(backgroundColor: Color.orange.opacity(0.2), underlineStyle: true)
        }
    }
}

// MARK: - UTF-16 Range Conversion

public enum HighlightRangeConverter {
    /// Convert a UTF-16 range to a `Range<String.Index>`.
    public static func stringRange(
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

    /// Convert a UTF-16 highlight range to an `NSRange`.
    public static func nsRange(for highlight: Utf16HighlightRange) -> NSRange {
        highlight.nsRange
    }
}

// MARK: - AttributedString Builder

public enum HighlightAttributedStringBuilder {
    /// Build an `AttributedString` with highlight styling applied.
    public static func attributedText(
        _ text: String,
        highlights: [Utf16HighlightRange]
    ) -> AttributedString {
        var attributed = AttributedString(text)
        apply(highlights: highlights, to: &attributed, utf16Offset: 0)
        return attributed
    }

    /// Build an `AttributedString` for a card excerpt with highlight styling.
    public static func attributedSnippet(
        _ text: String,
        highlights: [Utf16HighlightRange]
    ) -> AttributedString {
        attributedText(text, highlights: highlights)
    }

    /// Extract the highlighted text fragments from the source text.
    public static func fragments(
        in text: String,
        highlights: [Utf16HighlightRange]
    ) -> [String] {
        highlights.compactMap { highlight in
            guard let range = HighlightRangeConverter.stringRange(
                utf16Start: Int(highlight.utf16Start),
                utf16End: Int(highlight.utf16End),
                in: text
            ) else {
                return nil
            }
            return String(text[range])
        }
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

            guard let range = HighlightRangeConverter.stringRange(
                utf16Start: relativeStart,
                utf16End: relativeEnd,
                in: text
            ),
                let attrStart = AttributedString.Index(range.lowerBound, within: attributed),
                let attrEnd = AttributedString.Index(range.upperBound, within: attributed)
            else {
                continue
            }

            let style = HighlightAppearance.style(for: highlight.kind)
            attributed[attrStart ..< attrEnd].backgroundColor = style.backgroundColor
            if style.underlineStyle {
                attributed[attrStart ..< attrEnd].underlineStyle = .single
            }
        }
    }
}
