import AppKit
import SwiftUI
import Carbon

enum HotKeyEditState: Equatable {
    case idle
    case recording
}

struct AdvancedSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var hotKeyState: HotKeyEditState = .idle

    let onHotKeyChanged: (HotKey) -> Void

    var body: some View {
        Form {
            Section(String(localized: "Hotkey")) {
                HStack {
                    Text(String(localized: "Open Clipboard History"))
                    Spacer()
                    Button(action: { hotKeyState = .recording }) {
                        let (labelText, backgroundColor): (String, Color) = {
                            switch hotKeyState {
                            case .recording:
                                return (String(localized: "Press keys..."), Color.accentColor.opacity(0.2))
                            case .idle:
                                return (settings.hotKey.displayString, Color.secondary.opacity(0.1))
                            }
                        }()

                        Text(labelText)
                            .frame(minWidth: 100)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(backgroundColor)
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
                    .font(.caption)
                }
            }

            Section(String(localized: "Integration")) {
                if settings.hasPostEventPermission {
                    Toggle(String(localized: "Direct Paste"), isOn: $settings.autoPasteEnabled)
                    if settings.autoPasteEnabled {
                        Text(String(localized: "ClipKitty will paste items directly into the previous app."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "Items will be copied to the clipboard without pasting."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Toggle(String(localized: "Direct Paste"), isOn: .constant(false))
                        .disabled(true)
                    Text(String(localized: "Paste items directly into the previous app. Requires permission in System Settings."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Open System Settings")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct HotKeyRecorder: NSViewRepresentable {
    @Binding var state: HotKeyEditState
    let onHotKeyRecorded: (HotKey) -> Void

    func makeNSView(context: Context) -> HotKeyRecorderView {
        let view = HotKeyRecorderView()
        view.onHotKeyRecorded = { hotKey in
            onHotKeyRecorded(hotKey)
            state = .idle
        }
        view.onCancel = {
            state = .idle
        }
        return view
    }

    func updateNSView(_ nsView: HotKeyRecorderView, context: Context) {
        if case .recording = state {
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
