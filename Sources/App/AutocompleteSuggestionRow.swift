import SwiftUI

struct AutocompleteSuggestionRow: View {
    let suggestion: FilterSuggestion
    let isHighlighted: Bool
    let searchText: String
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: suggestion.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isHighlighted ? .white : .primary.opacity(0.6))
                    .frame(width: 20)

                prefixHighlightedText
                    .foregroundColor(isHighlighted ? .white : .primary)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Group {
                    if isHighlighted {
                        selectionBackground()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else if isHovered {
                        Color.primary.opacity(0.1)
                    } else {
                        Color.primary.opacity(0.05)
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("Suggestion_\(suggestion.displayName)")
    }

    /// Renders the display name with the matching prefix in bold
    private var prefixHighlightedText: Text {
        let name = suggestion.displayName
        let matchLen = min(searchText.count, name.count)

        if matchLen > 0,
           name.lowercased().hasPrefix(searchText.lowercased()) {
            let matchEnd = name.index(name.startIndex, offsetBy: matchLen)
            let matched = Text(name[name.startIndex..<matchEnd])
                .font(.custom(FontManager.sansSerif, size: 14).bold())
            let rest = Text(name[matchEnd...])
                .font(.custom(FontManager.sansSerif, size: 14))
            return matched + rest
        } else {
            return Text(name)
                .font(.custom(FontManager.sansSerif, size: 14))
        }
    }
}
