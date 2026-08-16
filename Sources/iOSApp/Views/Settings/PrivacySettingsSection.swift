import SwiftUI

struct PrivacySettingsSection: View {
    @Environment(iOSSettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Section(String(localized: "Privacy")) {
            Toggle(String(localized: "Generate Link Previews"), isOn: $settings.generateLinkPreviews)

            PrivacyToggleRow(
                title: String(localized: "Allow Shortcuts to Read History"),
                description: String(localized: "Lets Shortcuts and automations read your clipboard history."),
                isOn: $settings.allowShortcutsReadAccess
            )

            PrivacyToggleRow(
                title: String(localized: "Capture Sensitive Clips"),
                description: String(localized: "Saves clips marked sensitive by apps, such as passwords and codes."),
                isOn: $settings.captureSensitiveClips
            )
        }
    }
}

private struct PrivacyToggleRow: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
