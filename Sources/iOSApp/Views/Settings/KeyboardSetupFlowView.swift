import ClipKittyShared
import SwiftUI
import UIKit

/// Step-by-step keyboard setup, presented from the settings card. Each step
/// is one small bit of info: what the keyboard is, where to turn it on, the
/// optional paste-prompt setting, and how to switch to it. Steps swipe like
/// pages and the primary button advances; the "turn it on" step jumps
/// straight to ClipKitty's page in the Settings app.
///
/// Setup can only complete outside this app (in Settings, then by opening
/// the keyboard somewhere), so on every return to the foreground the flow
/// re-checks the keyboard's activation marker and swaps the last step for a
/// success state once it exists.
struct KeyboardSetupFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var stepIndex = 0
    @State private var setupStatus = KeyboardFeedStore.setupStatus()

    private struct Step: Identifiable {
        let id: Int
        let systemImage: String
        let title: String
        let detail: String
        var iconStyle: Color = .accentColor
    }

    private var steps: [Step] {
        [
            Step(
                id: 0,
                systemImage: "keyboard",
                title: String(localized: "Meet the ClipKitty keyboard"),
                detail: String(localized: "Your recent clips appear as cards. Tap one to type it — in any app.")
            ),
            Step(
                id: 1,
                systemImage: "gearshape",
                title: String(localized: "Turn it on"),
                detail: String(localized: "In the Settings app, tap Keyboards, then turn on ClipKitty and Allow Full Access. Nothing you copy ever leaves your device.")
            ),
            Step(
                id: 2,
                systemImage: "doc.on.clipboard",
                title: String(localized: "Skip the paste prompts"),
                detail: String(localized: "Optional: set Paste from Other Apps to Allow, so the keyboard can save new clips without asking.")
            ),
            finalStep,
        ]
    }

    private var finalStep: Step {
        switch setupStatus {
        case .confirmed:
            Step(
                id: 3,
                systemImage: "checkmark.circle.fill",
                title: String(localized: "You're all set"),
                detail: String(localized: "The ClipKitty keyboard is on — your clips are one tap away."),
                iconStyle: .green
            )
        case .unconfirmed:
            Step(
                id: 3,
                systemImage: "globe",
                title: String(localized: "Try it out"),
                detail: String(localized: "In any text field, touch and hold the globe key and choose ClipKitty.")
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.quaternary.opacity(0.5), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Close"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            TabView(selection: $stepIndex) {
                ForEach(steps) { step in
                    stepContent(step)
                        .tag(step.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            stepDots
                .padding(.bottom, 20)

            controls
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                withAnimation(.bouncy) {
                    setupStatus = KeyboardFeedStore.setupStatus()
                }
            }
        }
        .task {
            setupStatus = KeyboardFeedStore.setupStatus()
            for await _ in KeyboardFeedStore.changes(for: .activation) {
                guard !Task.isCancelled else { return }
                withAnimation(.bouncy) {
                    setupStatus = KeyboardFeedStore.setupStatus()
                }
            }
        }
    }

    private func stepContent(_ step: Step) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            Image(systemName: step.systemImage)
                .font(.system(size: 34))
                .foregroundStyle(step.iconStyle)
                .frame(width: 84, height: 84)
                .background(step.iconStyle.opacity(0.12), in: Circle())

            Text(step.title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(step.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(steps) { step in
                Circle()
                    .fill(step.id == stepIndex ? Color.accentColor : Color(.systemFill))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var controls: some View {
        let isLastStep = stepIndex == steps.count - 1
        let isSettingsStep = stepIndex == 1

        VStack(spacing: 4) {
            Button {
                if isSettingsStep {
                    openAppSettings()
                    advance()
                } else if isLastStep {
                    dismiss()
                } else {
                    advance()
                }
            } label: {
                Text(primaryTitle)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("keyboardSetup.primaryButton")

            // The settings step's primary action leaves the app, so give
            // users who have already flipped the switches a way forward.
            Button {
                advance()
            } label: {
                Text(String(localized: "Next"))
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .opacity(isSettingsStep ? 1 : 0)
            .disabled(!isSettingsStep)
        }
    }

    private var primaryTitle: String {
        if stepIndex == 1 {
            return String(localized: "Open Settings")
        }
        if stepIndex == steps.count - 1 {
            return String(localized: "Done")
        }
        return String(localized: "Continue")
    }

    private func advance() {
        withAnimation(.bouncy) {
            stepIndex = min(stepIndex + 1, steps.count - 1)
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
