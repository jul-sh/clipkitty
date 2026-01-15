import Foundation
import SwiftUI
import AppKit

/// Simple string highlighting for search matches
extension String {

    /// Create an NSAttributedString with search query matches highlighted (AppKit - fast)
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

        // Find all occurrences of the query (case insensitive)
        var searchRange = NSRange(location: 0, length: (self as NSString).length)
        var matchCount = 0
        let maxMatches = 50
        let nsString = self as NSString

        while matchCount < maxMatches, searchRange.location < nsString.length {
            let foundRange = nsString.range(of: query, options: .caseInsensitive, range: searchRange)
            guard foundRange.location != NSNotFound else { break }

            result.addAttribute(.backgroundColor, value: highlightColor, range: foundRange)

            searchRange.location = foundRange.location + foundRange.length
            searchRange.length = nsString.length - searchRange.location
            matchCount += 1
        }

        return result
    }
}
