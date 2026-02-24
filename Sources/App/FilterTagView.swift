import SwiftUI

/// A pill-shaped view that displays an active filter tag inside the search field
struct FilterTagView: View {
    let suggestion: FilterSuggestion
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            // Filter icon
            Image(systemName: suggestion.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(suggestion.iconColor)

            // Filter display name
            Text(suggestion.displayName)
                .font(.custom(FontManager.sansSerif, size: 14))
                .foregroundColor(.primary)

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Remove filter"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(suggestion.iconColor.opacity(0.15))
        )
        .overlay(
            Capsule()
                .stroke(suggestion.iconColor.opacity(0.3), lineWidth: 1)
        )
    }
}
