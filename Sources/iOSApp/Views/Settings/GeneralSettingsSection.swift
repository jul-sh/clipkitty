import SwiftUI

struct GeneralSettingsSection: View {
    @Environment(iOSSettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Section("General") {
            Toggle("Haptic Feedback", isOn: $settings.hapticsEnabled)
            Toggle("Generate Link Previews", isOn: $settings.generateLinkPreviews)
        }
    }
}
