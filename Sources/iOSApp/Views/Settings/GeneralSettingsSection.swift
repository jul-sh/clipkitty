import SwiftUI

struct GeneralSettingsSection: View {
    @Environment(iOSSettingsStore.self) private var settings
    @State private var showPermissionFlow = false

    var body: some View {
        @Bindable var settings = settings

        Section(String(localized: "Behavior")) {
            #if ENABLE_ICLOUD_SYNC
                SyncSettingsRow()
            #endif
            Toggle(isOn: $settings.autoAddFromClipboard) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Auto-Add from Clipboard"))
                    // iOS grants no standing clipboard access, so this can only
                    // read on activation and still hits the system prompt until
                    // the user picks "Allow" in Settings. Say so here; the feed
                    // card that explains it can be dismissed for good.
                    Text(String(localized: "Saves the clipboard each time you open ClipKitty. Allow “Paste from Other Apps” in Settings so iOS stops asking every time."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // The only other way into this flow is the feed card, whose ✕
            // hides it permanently; Settings needs its own entry point.
            Button(String(localized: "Set Up Clipboard Access…")) {
                showPermissionFlow = true
            }
            .accessibilityIdentifier("settings.setUpClipboardAccess")
            .sheet(isPresented: $showPermissionFlow) {
                SaveAutomaticallySheet()
            }
        }
    }
}
