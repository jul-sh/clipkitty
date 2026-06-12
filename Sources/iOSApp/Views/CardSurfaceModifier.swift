import SwiftUI

struct CardSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if colorScheme == .dark {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
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

struct CardPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
