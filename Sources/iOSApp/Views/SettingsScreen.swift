import SwiftUI

struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                GeneralSettingsSection()
                #if ENABLE_ICLOUD_SYNC
                    SyncSettingsSection()
                #endif
                HistorySettingsSection()
                AboutSettingsSection()
            }
            .navigationTitle(String(localized: "Settings"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done", comment: "Settings dismiss button")
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }
}
