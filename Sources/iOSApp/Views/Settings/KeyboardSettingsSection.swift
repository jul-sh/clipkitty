import ClipKittyShared
import SwiftUI
import UIKit

/// Activation flow for the ClipKitty keyboard. Until the keyboard has been
/// used once, this shows a compact setup card that opens the step-by-step
/// flow (`KeyboardSetupFlowView`); once the keyboard drops its first
/// activation marker — proof it is enabled with Full Access — the section
/// collapses to a success row.
///
/// There is no API to ask "is my keyboard enabled?", so the marker written by
/// the keyboard itself (`KeyboardFeedStore.recordKeyboardOpened`) is the only
/// trustworthy signal.
struct KeyboardSettingsSection: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var setupStatus = KeyboardFeedStore.setupStatus()
    @State private var showSetupFlow = false

    var body: some View {
        Section(String(localized: "Keyboard")) {
            switch setupStatus {
            case .confirmed:
                Label {
                    Text(String(localized: "The ClipKitty keyboard is set up"))
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                Text(String(localized: "Tap the globe key on any keyboard to switch to ClipKitty. New clipboard content is saved to your history whenever the keyboard opens."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unconfirmed:
                Button {
                    showSetupFlow = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "keyboard.badge.ellipsis")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 40, height: 40)
                            .background(
                                .tint.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            // Concrete colors on purpose: the Form's button
                            // style tints the row, and hierarchical styles
                            // would resolve against that tint.
                            Text(String(localized: "Set up the ClipKitty keyboard"))
                                .font(.body.weight(.medium))
                                .foregroundStyle(Color.primary)
                            Text(String(localized: "Paste your clips in any app"))
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("settings.keyboardSetupCard")
                // On the row, not the Section: presentation modifiers on a
                // Form Section are silently ignored.
                .sheet(isPresented: $showSetupFlow) {
                    KeyboardSetupFlowView()
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Returning from the Settings app (or first use of the keyboard)
            // is when the marker can newly exist — re-check on activation.
            if newPhase == .active {
                setupStatus = KeyboardFeedStore.setupStatus()
            }
        }
        .task {
            setupStatus = KeyboardFeedStore.setupStatus()
            for await _ in KeyboardFeedStore.changes(for: .activation) {
                guard !Task.isCancelled else { return }
                setupStatus = KeyboardFeedStore.setupStatus()
            }
        }
    }
}
