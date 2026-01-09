import Foundation
import SwiftUI

/// Simple string highlighting for search matches
extension String {

    /// Create an AttributedString with search query matches highlighted
    func fuzzyHighlighted(query: String, highlightColor: Color = .yellow.opacity(0.4)) -> AttributedString {
        var result = AttributedString(self)

        guard !query.isEmpty else { return result }

        // Find all occurrences of the query (case insensitive)
        let lowercaseSelf = self.lowercased()
        let lowercaseQuery = query.lowercased()

        var searchStart = lowercaseSelf.startIndex
        while let range = lowercaseSelf.range(of: lowercaseQuery, range: searchStart..<lowercaseSelf.endIndex) {
            // Convert to AttributedString range
            if let attrRange = Range(range, in: result) {
                result[attrRange].backgroundColor = highlightColor
            }
            searchStart = range.upperBound
        }

        return result
    }
}
