import SwiftUI

struct CardSurface: ViewModifier {
    static let cornerRadius: CGFloat = 14

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay {
                if colorScheme == .dark {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                }
            }
            .shadow(
                color: colorScheme == .light
                    ? .black.opacity(0.08)
                    : .white.opacity(0.06),
                radius: colorScheme == .light ? 4 : 10,
                y: colorScheme == .light ? 2 : 0
            )
    }
}

extension View {
    func cardSurface() -> some View {
        modifier(CardSurface())
    }
}
