import SwiftUI

struct GeneralSettingsSection: View {
    @Environment(iOSSettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Section(String(localized: "Behavior")) {
            #if ENABLE_ICLOUD_SYNC
                SyncSettingsRow()
            #endif
            Toggle(String(localized: "Auto-Add from Clipboard"), isOn: $settings.autoAddFromClipboard)
        }
    }
}
