import SwiftUI

/// A pill-shaped view that displays an active filter tag inside the search field
struct FilterTagView: View {
    let suggestion: FilterSuggestion
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            // Filter icon
            Image(systemName: suggestion.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)

            // Filter display name
            Text(suggestion.displayName)
                .font(.custom(FontManager.sansSerif, size: 16))
                .foregroundColor(.primary)

        }
        .accessibilityIdentifier("FilterTag_\(suggestion.displayName)")
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.1))
        )
        .contentShape(Capsule())
        .onTapGesture(perform: onDelete)
    }
}
