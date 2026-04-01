import SwiftUI

struct ToastView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let toast = appState.toastMessage {
            HStack(spacing: 8) {
                Image(systemName: toast.iconSystemName)
                    .font(.subheadline.weight(.semibold))
                Text(toast.text)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.snappy, value: appState.toastMessage)
        }
    }
}
