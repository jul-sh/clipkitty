import SwiftUI

struct AboutSettingsSection: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    var body: some View {
        Section("About") {
            LabeledContent("Version", value: appVersion)
            LabeledContent("Build", value: buildNumber)
        }
    }
}
