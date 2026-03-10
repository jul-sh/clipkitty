import SwiftUI

private struct ToastBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // Use tinted glass to prevent automatic desktop color adaptation
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
        }
    }
}

struct ToastView: View {
    let message: String
    let iconSystemName: String
    let iconColor: Color
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconSystemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(iconColor)

            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .fixedSize()
        .modifier(ToastBackgroundModifier())
    }
}
