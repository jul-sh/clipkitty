import ClipKittyShared
import SwiftUI

/// Lightweight drag preview rendered from a `DisplayRow`.
/// Reuses the card surface style so the preview matches the feed appearance.
struct CardDragPreview: View {
    let row: DisplayRow

    private var snippet: String {
        let text = row.listDecoration?.text ?? row.metadata.snippet
        return String(text.prefix(120))
    }

    var body: some View {
        Text(snippet)
            .font(.custom(FontManager.sansSerif, size: 14))
            .lineLimit(3)
            .foregroundStyle(.primary)
            .cardSurface()
            .frame(maxWidth: 280)
    }
}
