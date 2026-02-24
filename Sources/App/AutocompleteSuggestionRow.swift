import SwiftUI

struct AutocompleteSuggestionRow: View {
    let suggestion: FilterSuggestion
    let isHighlighted: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: suggestion.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isHighlighted ? .white : suggestion.iconColor)
                    .frame(width: 20)

                Text(suggestion.displayName)
                    .font(.custom(FontManager.sansSerif, size: 14))
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
                        Color.primary.opacity(0.05)
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("Suggestion_\(suggestion.displayName)")
    }
}
