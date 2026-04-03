import SwiftUI

struct CardSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(
                color: colorScheme == .light
                    ? .black.opacity(0.08)
                    : .white.opacity(0.04),
                radius: colorScheme == .light ? 4 : 8,
                y: colorScheme == .light ? 2 : 0
            )
    }
}

extension View {
    func cardSurface() -> some View {
        modifier(CardSurface())
    }
}
