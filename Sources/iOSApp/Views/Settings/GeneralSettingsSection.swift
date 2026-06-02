import SwiftUI

struct GeneralSettingsSection: View {
    @Environment(iOSSettingsStore.self) private var settings
    @Environment(AppContainer.self) private var container

    @State private var showingClipboardPermissionSheet = false
    @State private var clipboardPermissionStatus: ClipboardPermissionStatus = .unknown

    var body: some View {
        @Bindable var settings = settings

        Section(String(localized: "General")) {
            Toggle(String(localized: "Haptic Feedback"), isOn: $settings.hapticsEnabled)
            Toggle(String(localized: "Generate Link Previews"), isOn: $settings.generateLinkPreviews)
            Toggle(String(localized: "Auto-Add from Clipboard"), isOn: autoAddFromClipboardBinding)

            if settings.autoAddFromClipboard {
                switch clipboardPermissionStatus {
                case .checked(.granted):
                    ClipboardPermissionVerifiedRow()
                case .unknown, .verifying, .checked(.needsClipboardItem), .checked(.needsSettingsChange):
                    ClipboardPermissionPromptRow(status: clipboardPermissionStatus) {
                        showingClipboardPermissionSheet = true
                    }
                }
            }
        }
        .sheet(isPresented: $showingClipboardPermissionSheet) {
            ClipboardPermissionSheet(
                isPresented: $showingClipboardPermissionSheet,
                status: $clipboardPermissionStatus,
                clipboardService: container.clipboardService
            )
        }
    }

    private var autoAddFromClipboardBinding: Binding<Bool> {
        Binding(
            get: { settings.autoAddFromClipboard },
            set: { enabled in
                settings.autoAddFromClipboard = enabled
                switch enabled {
                case true:
                    clipboardPermissionStatus = .unknown
                    showingClipboardPermissionSheet = true
                case false:
                    clipboardPermissionStatus = .unknown
                }
            }
        )
    }
}
