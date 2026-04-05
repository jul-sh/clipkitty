import AppKit
import ClipKittyRust
import ClipKittyShared
import SwiftUI

/// macOS-specific highlight styling that bridges the shared cross-platform
/// highlight appearance to AppKit's NSColor and NSAttributedString attributes.
///
/// SwiftUI colors and underline policy are sourced from the shared
/// `HighlightAppearance` so both platforms stay in sync.
enum HighlightStyler {
    struct Appearance {
        let nsBackgroundColor: NSColor
        let swiftBackgroundColor: Color
        let underlineStyle: NSUnderlineStyle?
    }

    // MARK: - Colors (derived from shared HighlightAppearance)

    static func appearance(for kind: HighlightKind) -> Appearance {
        let shared = HighlightAppearance.style(for: kind)
        return Appearance(
            nsBackgroundColor: NSColor(shared.backgroundColor),
            swiftBackgroundColor: shared.backgroundColor,
            underlineStyle: shared.underlineStyle ? .single : nil
        )
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

    static func renderingAttributes(for kind: HighlightKind) -> [NSAttributedString.Key: Any] {
        attributes(for: kind)
    }

    // MARK: - SwiftUI Text Support (delegates to shared builder)

    static func splitText(
        _ text: String,
        highlight: Utf16HighlightRange
    ) -> (prefix: String, match: String, suffix: String) {
        guard let range = HighlightRangeConverter.stringRange(
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

    static func highlightInSuffix(
        _ highlight: Utf16HighlightRange,
        suffixStartUtf16Offset: Int,
        suffixUtf16Count: Int
    ) -> Bool {
        let start = Int(highlight.utf16Start)
        return start >= suffixStartUtf16Offset && start < suffixStartUtf16Offset + suffixUtf16Count
    }

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
        HighlightAttributedStringBuilder.attributedText(text, highlights: highlights)
    }

    static func attributedFragment(
        _ text: String,
        kind: HighlightKind
    ) -> AttributedString {
        HighlightAttributedStringBuilder.attributedText(text, highlights: [
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
        HighlightAttributedStringBuilder.fragments(in: text, highlights: highlights)
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

            let appearance = appearance(for: highlight.kind)
            attributed[attrStart ..< attrEnd].backgroundColor = appearance.swiftBackgroundColor
            if appearance.underlineStyle != nil {
                attributed[attrStart ..< attrEnd].underlineStyle = .single
            }
        }
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
