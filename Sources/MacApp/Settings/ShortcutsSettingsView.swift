import AppKit
import ClipKittyShared
import SwiftUI

private enum HotKeyTarget {
    case open
    case delete
}

struct ShortcutsSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var recording: HotKeyTarget?

    let onHotKeyChanged: (HotKey) -> Void

    var body: some View {
        Form {
            Section(String(localized: "Keyboard Shortcut")) {
                shortcutRow(
                    label: String(localized: "Open ClipKitty"),
                    target: .open,
                    hotKey: settings.hotKey,
                    onRecorded: { hotKey in
                        settings.hotKey = hotKey
                        onHotKeyChanged(hotKey)
                    }
                )

                if settings.hotKey != .default {
                    Button(String(localized: "Reset to Default (⌥Space)")) {
                        settings.hotKey = .default
                        onHotKeyChanged(.default)
                    }
                    .font(.subheadline)
                }

                shortcutRow(
                    label: String(localized: "Delete Item"),
                    target: .delete,
                    hotKey: settings.deleteHotKey,
                    onRecorded: { hotKey in
                        settings.deleteHotKey = hotKey
                    }
                )

                if settings.deleteHotKey != .deleteDefault {
                    Button(String(localized: "Reset to Default (⌘-)")) {
                        settings.deleteHotKey = .deleteDefault
                    }
                    .font(.subheadline)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(
        label: String,
        target: HotKeyTarget,
        hotKey: HotKey,
        onRecorded: @escaping (HotKey) -> Void
    ) -> some View {
        let isRecording = recording == target
        let recorderState = Binding<HotKeyEditState>(
            get: { isRecording ? .recording : .idle },
            set: { newState in
                switch newState {
                case .recording:
                    recording = target
                case .idle:
                    if recording == target { recording = nil }
                }
            }
        )

        return HStack {
            Text(label)
            Spacer()
            Button(action: { recording = target }) {
                let labelText = isRecording
                    ? String(localized: "Press keys...")
                    : hotKey.displayString
                let background = isRecording
                    ? Color.accentColor.opacity(0.2)
                    : Color.secondary.opacity(0.1)

                Text(labelText)
                    .frame(minWidth: 100)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(background)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .background(
            HotKeyRecorder(
                state: recorderState,
                onHotKeyRecorded: { hotKey in
                    onRecorded(hotKey)
                }
            )
        )
    }
}
