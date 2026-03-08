import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general = "General"
    case privacy = "Privacy"
    case advanced = "Advanced"
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    let store: ClipboardStore
    let onHotKeyChanged: (HotKey) -> Void
    let onMenuBarBehaviorChanged: () -> Void
    #if !APP_STORE
    var onInstallUpdate: (() -> Void)? = nil
    #endif

    var body: some View {
        TabView(selection: $selectedTab) {
            generalSettingsView
                .tabItem {
                    Label(String(localized: "General"), systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            PrivacySettingsView()
                .tabItem {
                    Label(String(localized: "Privacy"), systemImage: "hand.raised")
                }
                .tag(SettingsTab.privacy)

            AdvancedSettingsTab(onHotKeyChanged: onHotKeyChanged)
                .tabItem {
                    Label(String(localized: "Advanced"), systemImage: "gearshape.2")
                }
                .tag(SettingsTab.advanced)
        }
        .frame(width: 480, height: 420)
    }

    private var generalSettingsView: GeneralSettingsTab {
        #if !APP_STORE
        GeneralSettingsTab(
            store: store,
            onHotKeyChanged: onHotKeyChanged,
            onMenuBarBehaviorChanged: onMenuBarBehaviorChanged,
            onInstallUpdate: onInstallUpdate
        )
        #else
        GeneralSettingsTab(
            store: store,
            onHotKeyChanged: onHotKeyChanged,
            onMenuBarBehaviorChanged: onMenuBarBehaviorChanged
        )
        #endif
    }
}
