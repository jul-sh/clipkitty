import SwiftUI
import Carbon

enum HotKeyEditState: Equatable {
    case idle
    case recording
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared
    @State private var hotKeyState: HotKeyEditState = .idle
    @State private var showClearConfirmation = false

    let store: ClipboardStore
    let onHotKeyChanged: (HotKey) -> Void
    private let minDatabaseSizeGB = 0.5
    private let maxDatabaseSizeGB = 64.0

    var body: some View {
        Form {
            Section("Hotkey") {
                HStack {
                    Text("Open Clipboard History")
                    Spacer()
                    Button(action: { hotKeyState = .recording }) {
                        let (labelText, backgroundColor): (String, Color) = {
                            switch hotKeyState {
                            case .recording:
                                return ("Press keys...", Color.accentColor.opacity(0.2))
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
                    Button("Reset to Default (⌥Space)") {
                        settings.hotKey = .default
                        onHotKeyChanged(.default)
                    }
                    .font(.caption)
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                    .disabled(!launchAtLogin.isInApplicationsDirectory)

                if !launchAtLogin.isInApplicationsDirectory {
                    Text("Move ClipKitty to the Applications folder to enable this option.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = launchAtLogin.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Open Login Items Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        launchAtLogin.errorMessage = nil
                    }
                    .font(.caption)
                }
            }

            Section("Storage") {
                LabeledContent("Current Size") {
                    Text(formatBytes(store.databaseSizeBytes))
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Max Database Size") {
                    HStack(spacing: 8) {
                        Slider(value: databaseSizeSlider, in: 0...1)
                            .frame(maxWidth: .infinity)
                        Text(databaseSizeLabel)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity)
                }

                Text("Oldest clipboard items will be automatically deleted when the database exceeds this size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            }

            Section("Behavior") {
                HStack {
                    Text("Automatic Paste")
                    Spacer()
                    if settings.hasAccessibilityPermission {
                        Label("Enabled", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Requires Permission", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                if settings.hasAccessibilityPermission {
                    Text("ClipKitty will automatically paste items into the previous app when you press Enter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Grant Accessibility permission to enable automatic pasting. Without it, items will only be copied to the clipboard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Accessibility Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .font(.caption)
                }
            }

            #if SANDBOXED
            Section("Security") {
                HStack {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                    Text("Sandboxed")
                        .font(.headline)
                }
                Text("ClipKitty runs in an isolated environment, protecting your privacy and keeping your data secure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif

            Section("Data") {
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Clear Clipboard History")
                    }
                }
                .confirmationDialog(
                    "Clear Clipboard History",
                    isPresented: $showClearConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Clear All History", role: .destructive) {
                        store.clear()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Are you sure you want to delete all clipboard history? This cannot be undone.")
                }
            }


        }
        .formStyle(.grouped)
        .frame(width: 420, height: 420)
        .onAppear {
            store.refreshDatabaseSize()
            if settings.maxDatabaseSizeGB <= 0 {
                settings.maxDatabaseSizeGB = minDatabaseSizeGB
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { newValue in
                if launchAtLogin.setEnabled(newValue) {
                    settings.launchAtLoginEnabled = newValue
                }
            }
        )
    }

    private var databaseSizeSlider: Binding<Double> {
        Binding(
            get: {
                sliderValue(for: max(settings.maxDatabaseSizeGB, minDatabaseSizeGB))
            },
            set: { newValue in
                let gb = gbValue(for: newValue)
                settings.maxDatabaseSizeGB = gb
            }
        )
    }

    private var databaseSizeLabel: String {
        return String(format: "%.1f GB", settings.maxDatabaseSizeGB)
    }

    private func sliderValue(for gb: Double) -> Double {
        let clamped = min(max(gb, minDatabaseSizeGB), maxDatabaseSizeGB)
        let ratio = maxDatabaseSizeGB / minDatabaseSizeGB
        return log(clamped / minDatabaseSizeGB) / log(ratio)
    }

    private func gbValue(for sliderValue: Double) -> Double {
        let ratio = maxDatabaseSizeGB / minDatabaseSizeGB
        let value = minDatabaseSizeGB * pow(ratio, sliderValue)
        let rounded: Double
        if value >= 1.0 {
            rounded = value.rounded()
        } else {
            rounded = (value * 10).rounded() / 10
        }
        return min(max(rounded, minDatabaseSizeGB), maxDatabaseSizeGB)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024

        if gb >= 1 {
            return String(format: "%.2f GB", gb)
        } else if mb >= 1 {
            return String(format: "%.1f MB", mb)
        } else if kb >= 1 {
            return String(format: "%.0f KB", kb)
        } else {
            return "\(bytes) bytes"
        }
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


