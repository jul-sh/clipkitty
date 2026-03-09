import AppKit
import SwiftUI
import Carbon

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

final class HotKeyRecorderView: NSView {
    var onHotKeyRecorded: ((HotKey) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }

        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }

        guard modifiers != 0 else { return }

        let hotKey = HotKey(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        onHotKeyRecorded?(hotKey)
    }

    override func flagsChanged(with event: NSEvent) {}
}

struct AdvancedSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var hotKeyState: HotKeyEditState = .idle

    let onHotKeyChanged: (HotKey) -> Void
    #if SPARKLE_RELEASE
    var onInstallUpdate: (() -> Void)? = nil
    #endif

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    var body: some View {
        Form {
            Section(String(localized: "Hotkey")) {
                HStack {
                    Text(String(localized: "Open Clipboard History"))
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

            #if SPARKLE_RELEASE
            Section(String(localized: "Updates")) {
                switch settings.updateCheckState {
                case .checkFailed:
                    HStack {
                        Label(String(localized: "Unable to check for updates."), systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button(String(localized: "Download")) {
                            NSWorkspace.shared.open(URL(string: "https://github.com/jul-sh/clipkitty/releases/latest")!)
                        }
                    }
                case .available:
                    HStack {
                        Label(String(localized: "A new version of ClipKitty is available."), systemImage: "arrow.down.circle")
                        Spacer()
                        Button(String(localized: "Install")) {
                            onInstallUpdate?()
                        }
                    }
                case .idle:
                    EmptyView()
                }

                LabeledContent(String(localized: "Version")) {
                    Text("\(appVersion) (\(buildNumber))")
                        .foregroundStyle(.secondary)
                }

                Toggle(String(localized: "Automatically install updates"), isOn: $settings.autoInstallUpdates)

                Toggle(
                    String(localized: "Get beta updates"),
                    isOn: Binding(
                        get: {
                            switch settings.updateChannel {
                            case .stable:
                                return false
                            case .beta:
                                return true
                            }
                        },
                        set: { isBetaEnabled in
                            settings.updateChannel = isBetaEnabled ? .beta : .stable
                        }
                    )
                )

                Text(
                    String(
                        localized: "Beta releases ship to testers first. Turn this on to receive early builds from the release branch before they roll out to everyone."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                switch settings.updateChannel {
                case .stable:
                    EmptyView()
                case .beta:
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            String(
                                localized: "If you hit a bug in a beta build, please report it on GitHub with what broke, steps to reproduce it, your ClipKitty version, and your macOS version."
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Button(String(localized: "Report a Bug")) {
                            NSWorkspace.shared.open(URL(string: "https://github.com/jul-sh/clipkitty/issues/new/choose")!)
                        }
                    }
                }
            }
            #endif
        }
        .formStyle(.grouped)
    }
}
