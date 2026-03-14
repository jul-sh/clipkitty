import AppKit
import SwiftUI

struct ShortcutsSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var hotKeyState: HotKeyEditState = .idle

    let onHotKeyChanged: (HotKey) -> Void

    var body: some View {
        Form {
            Section(String(localized: "Keyboard Shortcut")) {
                HStack {
                    Text(String(localized: "Open ClipKitty"))
                    Spacer()
                    Button(action: { hotKeyState = .recording }) {
                        let state = hotKeyState
                        let labelAndBackground: (String, Color) = {
                            switch state {
                            case .recording:
                                return (String(localized: "Press keys..."), Color.accentColor.opacity(0.2))
                            case .idle:
                                return (settings.hotKey.displayString, Color.secondary.opacity(0.1))
                            }
                        }()

                        Text(labelAndBackground.0)
                            .frame(minWidth: 100)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(labelAndBackground.1)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                .background(
                    HotKeyRecorder(
                        state: $hotKeyState,
                        onHotKeyRecorded: { hotKey in
                            settings.hotKey = hotKey
                            onHotKeyChanged(hotKey)
                        }
                    )
                )

                if settings.hotKey != .default {
                    Button(String(localized: "Reset to Default (⌥Space)")) {
                        settings.hotKey = .default
                        onHotKeyChanged(.default)
                    }
                    .font(.subheadline)
                }
            }
        }
        .formStyle(.grouped)
    }
}
