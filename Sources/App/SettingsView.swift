import SwiftUI
import Carbon

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

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(
                store: store,
                onHotKeyChanged: onHotKeyChanged,
                onMenuBarBehaviorChanged: onMenuBarBehaviorChanged
            )
                .tabItem {
                    Label(String(localized: "General"), systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            PrivacySettingsView()
                .tabItem {
                    Label(String(localized: "Privacy"), systemImage: "hand.raised")
                }
                .tag(SettingsTab.privacy)

            AdvancedSettingsView(onHotKeyChanged: onHotKeyChanged)
                .tabItem {
                    Label(String(localized: "Advanced"), systemImage: "gearshape.2")
                }
                .tag(SettingsTab.advanced)
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
            Section(String(localized: "Startup")) {
                let canToggle: Bool = {
                    switch launchAtLogin.state {
                    case .enabled, .disabled: return true
                    case .unavailable, .error: return false
                    }
                }()

                Toggle(String(localized: "Launch at login"), isOn: launchAtLoginBinding)
                    .disabled(!canToggle)

                if let message = launchAtLogin.state.displayMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle({
                            if case .error = launchAtLogin.state { return AnyShapeStyle(.red) }
                            return AnyShapeStyle(.secondary)
                        }())

                    if case .error = launchAtLogin.state {
                        Button(String(localized: "Open Login Items Settings")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        }
                        .font(.caption)
                    }
                }
            }

            Section(String(localized: "Menu Bar")) {
                Toggle(isOn: clickToOpenBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Click to open"))
                        Text(String(localized: "Click opens ClipKitty, right-click shows menu."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(String(localized: "Storage")) {
                LabeledContent(String(localized: "Current Size")) {
                    Text(formatBytes(store.databaseSizeBytes))
                        .foregroundStyle(.secondary)
                }

                LabeledContent(String(localized: "Max Database Size")) {
                    HStack(spacing: 8) {
                        Slider(value: databaseSizeSlider, in: 0...1)
                            .frame(maxWidth: .infinity)
                        Text(databaseSizeLabel)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity)
                }

                Text(String(localized: "Oldest clipboard items will be automatically deleted when the database exceeds this size."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

            }



            Section(String(localized: "Data")) {
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text(String(localized: "Clear Clipboard History"))
                    }
                }
                .confirmationDialog(
                    String(localized: "Clear Clipboard History"),
                    isPresented: $showClearConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "Clear All History"), role: .destructive) {
                        store.clear()
                    }
                    Button(String(localized: "Cancel"), role: .cancel) {}
                } message: {
                    Text(String(localized: "Are you sure you want to delete all clipboard history? This cannot be undone."))
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

struct AdvancedSettingsView: View {
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
