import Foundation
import SwiftUI
import AppKit

/// Simple string highlighting for search matches
extension String {

    /// Create an NSAttributedString with search query matches highlighted (AppKit - fast)
    /// Uses trigram matching: highlights all 3-char substrings of query found in text
    /// Optimized: limits matches to first 50 occurrences to avoid pathological cases
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

        // First try exact query match
        var highlightedRanges = Set<NSRange>()
        var matchCount = 0
        let maxMatches = 50

        // Try exact match first
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

        // If no exact matches, use trigram highlighting
        if highlightedRanges.isEmpty && query.count >= 3 {
            // Generate trigrams from query
            let queryLower = query.lowercased()
            let chars = Array(queryLower)
            var trigrams: [String] = []
            for i in 0..<(chars.count - 2) {
                trigrams.append(String(chars[i..<i+3]))
            }

            // Highlight each trigram found in text
            for trigram in trigrams {
                searchRange = NSRange(location: 0, length: nsString.length)
                while matchCount < maxMatches, searchRange.location < nsString.length {
                    let foundRange = nsString.range(of: trigram, options: .caseInsensitive, range: searchRange)
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

        return result
    }
}
