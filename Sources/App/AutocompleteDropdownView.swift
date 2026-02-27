import SwiftUI

struct AutocompleteDropdownView: View {
    let suggestions: [FilterSuggestion]
    let highlightedIndex: Int
    let searchText: String
    let onSelect: (FilterSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(suggestions.enumerated()), id: \.element.filter) { index, suggestion in
                AutocompleteSuggestionRow(
                    suggestion: suggestion,
                    isHighlighted: index == highlightedIndex,
                    searchText: searchText,
                    onSelect: { onSelect(suggestion) }
                )
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .frame(width: 180)
    }
}
