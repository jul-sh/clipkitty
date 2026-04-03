import SwiftUI

struct SettingsScreen: View {
    var body: some View {
        NavigationStack {
            Form {
                GeneralSettingsSection()
                #if ENABLE_SYNC
                    SyncSettingsSection()
                #endif
                HistorySettingsSection()
                AboutSettingsSection()
            }
            .navigationTitle(String(localized: "Settings"))
        }
    }
}
