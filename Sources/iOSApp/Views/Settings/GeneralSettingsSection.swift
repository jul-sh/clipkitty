import SwiftUI
import UIKit

struct GeneralSettingsSection: View {
    @Environment(iOSSettingsStore.self) private var settings
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var settings = settings

        Section(String(localized: "General")) {
            Toggle(String(localized: "Haptic Feedback"), isOn: $settings.hapticsEnabled)
            Toggle(String(localized: "Generate Link Previews"), isOn: $settings.generateLinkPreviews)
            Toggle(String(localized: "Auto-Add from Clipboard"), isOn: $settings.autoAddFromClipboard)
        }

        Section(String(localized: "Permissions")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "To streamline operations, you can allow ClipKitty to always read the clipboard."))
                    .foregroundStyle(.primary)

                Text(String(localized: "Open ClipKitty in the Settings app, tap \"Paste from Other Apps\", then choose \"Allow\"."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

            Button {
                openAppSettings()
            } label: {
                Label(String(localized: "Open ClipKitty Settings"), systemImage: "gearshape")
            }
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
