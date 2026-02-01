import Foundation
import SwiftUI
import AppKit

/// Simple string highlighting for search matches using native trigram matching
extension String {

    /// Create an NSAttributedString with search query matches highlighted (AppKit - fast)
    /// Uses native trigram matching for fuzzy highlighting
    func highlightedNSAttributedString(
        query: String,
        font: NSFont,
        textColor: NSColor,
        highlightColor: NSColor = NSColor.yellow.withAlphaComponent(0.4)
    ) -> NSAttributedString {
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]

        guard !query.isEmpty else {
            return NSAttributedString(string: self, attributes: baseAttributes)
        }

        let result = NSMutableAttributedString(string: self, attributes: baseAttributes)
        let nsString = self as NSString

        // First try exact query match (High Priority)
        var highlightedRanges = Set<NSRange>()
        var matchCount = 0
        let maxMatches = 100

        var searchRange = NSRange(location: 0, length: nsString.length)
        while matchCount < maxMatches, searchRange.location < nsString.length {
            let foundRange = nsString.range(of: query, options: .caseInsensitive, range: searchRange)
            guard foundRange.location != NSNotFound else { break }

            result.addAttribute(.backgroundColor, value: highlightColor, range: foundRange)
            highlightedRanges.insert(foundRange)

            searchRange.location = foundRange.location + foundRange.length
            searchRange.length = nsString.length - searchRange.location
            matchCount += 1
        }

        // If no exact matches, use fuzzy highlighting (trigrams for 3+ chars, individual chars for 2 chars)
        if highlightedRanges.isEmpty && query.count >= 2 {
            let queryLower = query.lowercased()
            let chars = Array(queryLower)

            if chars.count >= 3 {
                // Extract trigrams from query and highlight matching regions
                for i in 0..<(chars.count - 2) {
                    let trigram = String(chars[i..<i+3])
                    highlightRanges(for: trigram, in: nsString, result: result, highlightColor: highlightColor, highlightedRanges: &highlightedRanges, matchCount: &matchCount, maxMatches: maxMatches)
                }
            } else if chars.count == 2 {
                // For 2-char queries, highlight individual characters if no exact match
                for char in chars {
                    let charString = String(char)
                    highlightRanges(for: charString, in: nsString, result: result, highlightColor: highlightColor, highlightedRanges: &highlightedRanges, matchCount: &matchCount, maxMatches: maxMatches)
                }
            }
        }

        return result
    }

    private func highlightRanges(
        for pattern: String,
        in nsString: NSString,
        result: NSMutableAttributedString,
        highlightColor: NSColor,
        highlightedRanges: inout Set<NSRange>,
        matchCount: inout Int,
        maxMatches: Int
    ) {
        var searchRange = NSRange(location: 0, length: nsString.length)
        while matchCount < maxMatches, searchRange.location < nsString.length {
            let foundRange = nsString.range(of: pattern, options: .caseInsensitive, range: searchRange)
            guard foundRange.location != NSNotFound else { break }

            // Only highlight if not already highlighted
            let alreadyHighlighted = highlightedRanges.contains { existing in
                NSIntersectionRange(existing, foundRange).length > 0
            }

            if !alreadyHighlighted {
                result.addAttribute(.backgroundColor, value: highlightColor, range: foundRange)
                highlightedRanges.insert(foundRange)
                matchCount += 1
            }

            searchRange.location = foundRange.location + foundRange.length
            searchRange.length = nsString.length - searchRange.location
        }
    }
}
