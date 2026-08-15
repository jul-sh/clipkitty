import SwiftUI

struct PrivacySettingsSection: View {
    @Environment(iOSSettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Section(String(localized: "Privacy")) {
            PrivacyToggleRow(
                title: String(localized: "Allow Shortcuts to Read History"),
                description: String(localized: "When off, Shortcuts and automations cannot read or search your clipboard history; saving new clips from Shortcuts still works. Turn this off if you do not want automations to access your history."),
                isOn: $settings.allowShortcutsReadAccess
            )

            PrivacyToggleRow(
                title: String(localized: "Capture Sensitive Clips"),
                description: String(localized: "When off, clips that an app marks as sensitive (such as passwords and one-time codes from a password manager) are not saved to history. Turn this on only if you want those clips captured too."),
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
