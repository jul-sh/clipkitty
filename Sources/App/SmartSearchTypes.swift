import SwiftUI
import ClipKittyRust

/// Represents a filter suggestion in the autocomplete dropdown
struct FilterSuggestion: Identifiable, Equatable {
    let filter: ContentTypeFilter
    let displayName: String
    let icon: String // SF Symbol name
    let iconColor: Color

    var id: ContentTypeFilter { filter }

    /// Checks if this suggestion matches the given input (case-insensitive prefix/contains matching)
    func matches(_ input: String) -> Bool {
        let lowercasedInput = input.lowercased()
        let lowercasedName = displayName.lowercased()
        return lowercasedName.hasPrefix(lowercasedInput) || lowercasedName.contains(lowercasedInput)
    }

    /// All available filter suggestions (excluding .all)
    static let allSuggestions: [FilterSuggestion] = [
        FilterSuggestion(
            filter: .text,
            displayName: String(localized: "Text"),
            icon: "doc.text",
            iconColor: .blue
        ),
        FilterSuggestion(
            filter: .images,
            displayName: String(localized: "Images"),
            icon: "photo",
            iconColor: Color(hue: 0.93, saturation: 0.7, brightness: 0.9)
        ),
        FilterSuggestion(
            filter: .links,
            displayName: String(localized: "Links"),
            icon: "link",
            iconColor: .green
        ),
        FilterSuggestion(
            filter: .colors,
            displayName: String(localized: "Colors"),
            icon: "paintpalette",
            iconColor: .purple
        ),
        FilterSuggestion(
            filter: .files,
            displayName: String(localized: "Files"),
            icon: "doc",
            iconColor: .orange
        )
    ]

    /// Returns suggestions that match the given input
    static func suggestions(for input: String) -> [FilterSuggestion] {
        guard !input.isEmpty else {
            return allSuggestions
        }
        return allSuggestions.filter { $0.matches(input) }
    }

    /// Returns the suggestion for a specific filter type
    static func suggestion(for filter: ContentTypeFilter) -> FilterSuggestion? {
        allSuggestions.first { $0.filter == filter }
    }
}

/// State for the autocomplete dropdown
enum AutocompleteState: Equatable {
    case hidden
    case visible(suggestions: [FilterSuggestion], highlightedIndex: Int)
}
