import ClipKittyCore
import SwiftUI

struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(iOSSettingsStore.self) private var settings
    @Environment(HapticsClient.self) private var haptics

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            SettingsForm(
                fontPreference: $settings.fontPreference,
                previewFontPreference: $settings.previewFontPreference,
                uiFont: { preference, size, weight in
                    AppFont.ui(preference, size: size, weight: weight)
                },
                previewFont: { typeface, style, size, weight in
                    AppFont.preview(
                        typeface: typeface,
                        style: style,
                        size: size,
                        weight: weight
                    )
                },
                onAppearanceSelection: {
                    haptics.fire(.selection)
                },
                generalSections: {
                    GeneralSettingsSection()
                },
                privacySections: {
                    PrivacySettingsSection()
                },
                syncSections: {
                    #if ENABLE_ICLOUD_SYNC
                        SyncSettingsSection()
                    #else
                        EmptyView()
                    #endif
                },
                platformSections: {
                    EmptyView()
                },
                shortcutsSections: {
                    ShortcutsSettingsSection()
                },
                advancedSections: {
                    AdvancedSettingsSection()
                }
            )
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
