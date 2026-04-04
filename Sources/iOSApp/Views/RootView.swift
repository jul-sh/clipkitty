import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HomeFeedView()
            .overlay(alignment: .bottom) {
                toastOverlay
                    .padding(.bottom, 80)
            }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let message = appState.toast.message {
            GlassEffectContainer {
                HStack(spacing: 10) {
                    Image(systemName: message.iconSystemName)
                        .font(.subheadline.weight(.medium))
                    Text(message.text)
                        .font(.subheadline.weight(.medium))

                    if let actionTitle = message.actionTitle, let action = appState.toast.action {
                        Button {
                            action()
                            withAnimation(.bouncy) {
                                appState.toast = .init()
                            }
                        } label: {
                            Text(actionTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
