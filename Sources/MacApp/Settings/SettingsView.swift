import ClipKittyMacPlatform
import ClipKittyCore
import SwiftUI

enum HotKeyEditState: Equatable {
    case idle
    case recording
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    let store: ClipboardStore
    let onHotKeyChanged: (HotKey) -> Void
    #if ENABLE_SPARKLE_UPDATES
        var onInstallUpdate: (() -> Void)? = nil
    #endif

    var body: some View {
        SettingsForm(
            fontPreference: $settings.fontPreference,
            previewFontPreference: $settings.previewFontPreference,
            uiFont: { preference, size, weight in
                AppFontSpecimen.uiFont(preference, size: size, weight: weight)
            },
            previewFont: { typeface, style, size, weight in
                AppFontSpecimen.previewFont(
                    typeface: typeface,
                    style: style,
                    size: size,
                    weight: weight
                )
            },
            generalSections: {
                GeneralSettingsView()
            },
            privacySections: {
                PrivacySettingsView()
            },
            syncSections: {
                #if ENABLE_ICLOUD_SYNC
                    SyncSettingsSection()
                #else
                    EmptyView()
                #endif
            },
            platformSections: {
                #if ENABLE_SYNTHETIC_PASTE
                    Section(String(localized: "Paste Items")) {
                        PasteItemsSettingView()
                    }
                #else
                    EmptyView()
                #endif
            },
            shortcutsSections: {
                ShortcutsSettingsView()
            },
            advancedSections: {
                advancedSettingsView
            }
        )
        .frame(width: 560, height: 520)
    }

    private var advancedSettingsView: MacAdvancedSettingsSection {
        #if ENABLE_SPARKLE_UPDATES
            MacAdvancedSettingsSection(
                store: store,
                onInstallUpdate: onInstallUpdate
            )
        #else
            MacAdvancedSettingsSection(
                store: store
            )
        #endif
    }
}
