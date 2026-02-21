import SwiftUI
import Carbon

enum HotKeyEditState: Equatable {
    case idle
    case recording
}

enum SettingsTab: String, CaseIterable {
    case general = "General"
    case privacy = "Privacy"
    case shortcuts = "Shortcuts"
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    let store: ClipboardStore
    let onHotKeyChanged: (HotKey) -> Void
    let onMenuBarBehaviorChanged: () -> Void

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(
                store: store,
                onHotKeyChanged: onHotKeyChanged,
                onMenuBarBehaviorChanged: onMenuBarBehaviorChanged
            )
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            PrivacySettingsView()
                .tabItem {
                    Label("Privacy", systemImage: "hand.raised")
                }
                .tag(SettingsTab.privacy)

            ShortcutsSettingsView(onHotKeyChanged: onHotKeyChanged)
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
                .tag(SettingsTab.shortcuts)
        }
        .frame(width: 480, height: 420)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared
    @State private var showClearConfirmation = false

    let store: ClipboardStore
    let onHotKeyChanged: (HotKey) -> Void
    let onMenuBarBehaviorChanged: () -> Void
    private let minDatabaseSizeGB = 0.5
    private let maxDatabaseSizeGB = 64.0

    var body: some View {
        Form {
            Section("Startup") {
                let canToggle: Bool = {
                    switch launchAtLogin.state {
                    case .enabled, .disabled: return true
                    case .unavailable, .error: return false
                    }
                }()

                Toggle("Launch at login", isOn: launchAtLoginBinding)
                    .disabled(!canToggle)

                if let message = launchAtLogin.state.displayMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle({
                            if case .error = launchAtLogin.state { return AnyShapeStyle(.red) }
                            return AnyShapeStyle(.secondary)
                        }())

                    if case .error = launchAtLogin.state {
                        Button("Open Login Items Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        }
                        .font(.caption)
                    }
                }
            }

            Section("Menu Bar") {
                Toggle(isOn: clickToOpenBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Click to open")
                        Text("Click opens ClipKitty, right-click shows menu.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                    Text("Accessibility Permission")
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
                    Toggle("Automatic Paste", isOn: $settings.autoPasteEnabled)
                    if settings.autoPasteEnabled {
                        Text("ClipKitty will automatically paste items into the previous app when you press Enter.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Items will be copied to the clipboard without pasting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Grant Accessibility permission to enable automatic pasting. Without it, items will only be copied to the clipboard. Restart the app after updating accessibility permissions for the change to take effect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Accessibility Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .font(.caption)
                }
            }

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

    private var clickToOpenBinding: Binding<Bool> {
        Binding(
            get: { settings.clickToOpenEnabled },
            set: { newValue in
                settings.clickToOpenEnabled = newValue
                onMenuBarBehaviorChanged()
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
        return String(localized: "\(settings.maxDatabaseSizeGB, specifier: "%.1f") GB")
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
            return String(localized: "\(gb, specifier: "%.2f") GB")
        } else if mb >= 1 {
            return String(localized: "\(mb, specifier: "%.1f") MB")
        } else if kb >= 1 {
            return String(localized: "\(kb, specifier: "%.0f") KB")
        } else {
            return String(localized: "\(bytes) bytes")
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

struct ShortcutsSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var hotKeyState: HotKeyEditState = .idle

    let onHotKeyChanged: (HotKey) -> Void

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
                    Button("Reset to Default (⌥Space)") {
                        settings.hotKey = .default
                        onHotKeyChanged(.default)
                    }
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }
}
