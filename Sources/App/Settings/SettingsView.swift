import SwiftUI

enum HotKeyEditState: Equatable {
    case idle
    case recording
}

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

            PrivacySettingsView()
                .tabItem {
                    Label(String(localized: "Privacy"), systemImage: "hand.raised")
                }
                .tag(SettingsTab.privacy)

            advancedSettingsView
                .tabItem {
                    Label(String(localized: "Advanced"), systemImage: "gearshape.2")
                }
                .tag(SettingsTab.advanced)
        }
        .frame(width: 480, height: 420)
    }

    private var generalSettingsView: GeneralSettingsView {
        GeneralSettingsView(
            store: store,
            onHotKeyChanged: onHotKeyChanged,
            onMenuBarBehaviorChanged: onMenuBarBehaviorChanged
        )
    }

    private var advancedSettingsView: AdvancedSettingsView {
        #if SPARKLE_RELEASE
        AdvancedSettingsView(
            onHotKeyChanged: onHotKeyChanged,
            onInstallUpdate: onInstallUpdate
        )
        #else
        AdvancedSettingsView(onHotKeyChanged: onHotKeyChanged)
        #endif
    }

    private var advancedSettingsView: AdvancedSettingsView {
        AdvancedSettingsView(onHotKeyChanged: onHotKeyChanged)
    }
}
