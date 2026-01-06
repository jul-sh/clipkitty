import SwiftUI
import Carbon

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var isRecordingHotKey = false
    let onHotKeyChanged: (HotKey) -> Void

    var body: some View {
        Form {
            Section("Hotkey") {
                HStack {
                    Text("Toggle Clipboard")
                    Spacer()
                    Button(action: { isRecordingHotKey = true }) {
                        Text(isRecordingHotKey ? "Press keys..." : settings.hotKey.displayString)
                            .frame(minWidth: 100)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isRecordingHotKey ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                .background(
                    HotKeyRecorder(
                        isRecording: $isRecordingHotKey,
                        onHotKeyRecorded: { hotKey in
                            settings.hotKey = hotKey
                            onHotKeyChanged(hotKey)
                        }
                    )
                )

                if settings.hotKey != .default {
                    Button("Reset to Default (⌥Space)") {
                        settings.hotKey = .default
                        onHotKeyChanged(.default)
                    }
                    .font(.caption)
                }
            }

            Section("Storage") {
                HStack {
                    Text("Max Database Size")
                    Spacer()
                    TextField("Size", value: $settings.maxDatabaseSizeMB, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("MB")
                        .foregroundStyle(.secondary)
                }

                Text("Oldest clipboard items will be automatically deleted when the database exceeds this size. Set to 0 for unlimited.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 250)
    }
}

struct HotKeyRecorder: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onHotKeyRecorded: (HotKey) -> Void

    func makeNSView(context: Context) -> HotKeyRecorderView {
        let view = HotKeyRecorderView()
        view.onHotKeyRecorded = { hotKey in
            onHotKeyRecorded(hotKey)
            isRecording = false
        }
        view.onCancel = {
            isRecording = false
        }
        return view
    }

    func updateNSView(_ nsView: HotKeyRecorderView, context: Context) {
        if isRecording {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

class HotKeyRecorderView: NSView {
    var onHotKeyRecorded: ((HotKey) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }

        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }

        // Require at least one modifier
        guard modifiers != 0 else { return }

        let hotKey = HotKey(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        onHotKeyRecorded?(hotKey)
    }

    override func flagsChanged(with event: NSEvent) {
        // Don't record modifier-only presses
    }
}
