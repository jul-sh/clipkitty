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
                    defaultHotKey: .default,
                    onRecorded: { hotKey in
                        settings.hotKey = hotKey
                        onHotKeyChanged(hotKey)
                    },
                    onRestoreDefault: {
                        settings.hotKey = .default
                        onHotKeyChanged(.default)
                    }
                )

                shortcutRow(
                    label: String(localized: "Delete Item"),
                    target: .delete,
                    hotKey: settings.deleteHotKey,
                    defaultHotKey: .deleteDefault,
                    onRecorded: { hotKey in
                        settings.deleteHotKey = hotKey
                    },
                    onRestoreDefault: {
                        settings.deleteHotKey = .deleteDefault
                    }
                )
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(
        label: String,
        target: HotKeyTarget,
        hotKey: HotKey,
        defaultHotKey: HotKey,
        onRecorded: @escaping (HotKey) -> Void,
        onRestoreDefault: @escaping () -> Void
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
            HStack(spacing: 8) {
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

                if hotKey != defaultHotKey {
                    Button {
                        if recording == target { recording = nil }
                        onRestoreDefault()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Restore Default"))
                    .accessibilityLabel(String(localized: "Restore Default"))
                }
            }
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
