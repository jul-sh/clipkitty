import ClipKittyShared
import SwiftUI
import UIKit

/// Activation flow for the ClipKitty keyboard. Current input-mode enablement
/// and historical Full Access evidence are parsed into one strict setup state,
/// so disabling the keyboard immediately restores the setup card when the app
/// returns from Settings.
struct KeyboardSettingsSection: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var setupStatus = KeyboardSetupStatus.current()
    @State private var showSetupFlow = false

    var body: some View {
        Section(String(localized: "Keyboard")) {
            switch setupStatus {
            case .enabled:
                Label {
                    Text(String(localized: "The ClipKitty keyboard is set up"))
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                Text(String(localized: "Tap the globe key on any keyboard to switch to ClipKitty. New clipboard content is saved to your history whenever the keyboard opens."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unavailable, .disabled, .enabledAwaitingFirstUse:
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
            // The enabled input-mode list changes while the app is in Settings.
            if newPhase == .active {
                setupStatus = KeyboardSetupStatus.current()
            }
        }
        .task {
            setupStatus = KeyboardSetupStatus.current()
            for await _ in KeyboardFeedStore.changes(for: .activation) {
                guard !Task.isCancelled else { return }
                setupStatus = KeyboardSetupStatus.current()
            }
        }
    }
}
