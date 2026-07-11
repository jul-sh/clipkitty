import ClipKittyShared
import SwiftUI
import UIKit

/// Activation flow for the ClipKitty keyboard. Until the keyboard has been
/// used once, this walks through enabling it (mirroring the clipboard
/// permission hint in `GeneralSettingsSection`); once the keyboard drops its
/// first activation marker — proof it is enabled with Full Access — the
/// section collapses to a success row.
///
/// There is no API to ask "is my keyboard enabled?", so the marker written by
/// the keyboard itself (`KeyboardFeedStore.recordKeyboardOpened`) is the only
/// trustworthy signal.
struct KeyboardSettingsSection: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var keyboardLastOpened: Date? = KeyboardFeedStore.keyboardLastOpened()

    var body: some View {
        Section(String(localized: "Keyboard")) {
            if keyboardLastOpened != nil {
                Label {
                    Text(String(localized: "The ClipKitty keyboard is set up"))
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                Text(String(localized: "Tap the globe key on any keyboard to switch to ClipKitty. New clipboard content is saved to your history whenever the keyboard opens."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Paste from your clip history in any app — the ClipKitty keyboard shows your recent clips as cards. Tap one to insert it, or drag it in. It also saves anything new you've copied."))
                        .foregroundStyle(.primary)

                    Text(String(localized: "Open ClipKitty in the Settings app, tap \"Keyboards\", then turn on ClipKitty and \"Allow Full Access\" — that's what lets the keyboard read and save your clips; nothing leaves your device."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(String(localized: "To save new clips without paste prompts, also set \"Paste from Other Apps\" to \"Allow\" while you're there."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)

                Button {
                    openAppSettings()
                } label: {
                    Label(String(localized: "Set Up Keyboard"), systemImage: "keyboard")
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Returning from the Settings app (or first use of the keyboard)
            // is when the marker can newly exist — re-check on activation.
            if newPhase == .active {
                keyboardLastOpened = KeyboardFeedStore.keyboardLastOpened()
            }
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
