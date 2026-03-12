import SwiftUI

enum HotKeyEditState: Equatable {
    case idle
    case recording
}

enum SettingsTab: String, CaseIterable {
    case general = "General"
    case privacy = "Privacy"
    case shortcuts = "Shortcuts"
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    let store: ClipboardStore
    let onHotKeyChanged: (HotKey) -> Void
    #if SPARKLE_RELEASE
    var onInstallUpdate: (() -> Void)? = nil
    #endif

    var body: some View {
        TabView(selection: $selectedTab) {
            generalSettingsView
                .tabItem {
                    Label(String(localized: "General"), systemImage: "gearshape")
                }
                .tag(SettingsTab.general)
                .accessibilityIdentifier("SettingsTab_General")

            PrivacySettingsView()
                .tabItem {
                    Label(String(localized: "Privacy"), systemImage: "hand.raised")
                }
                .tag(SettingsTab.privacy)
                .accessibilityIdentifier("SettingsTab_Privacy")

            ShortcutsSettingsView(onHotKeyChanged: onHotKeyChanged)
                .tabItem {
                    Label(String(localized: "Shortcuts"), systemImage: "keyboard")
                }
                .tag(SettingsTab.shortcuts)
                .accessibilityIdentifier("SettingsTab_Shortcuts")
        }
        .frame(width: 520, height: 500)
    }

    private var generalSettingsView: GeneralSettingsView {
        #if SPARKLE_RELEASE
        GeneralSettingsView(
            store: store,
            onInstallUpdate: onInstallUpdate
        )
        #else
        GeneralSettingsView(
            store: store
        )
        #endif
    }
}
