import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared
    @State private var showClearConfirmation = false
    @State private var hotKeyState: HotKeyEditState = .idle

    let store: ClipboardStore
    let onHotKeyChanged: (HotKey) -> Void
    let onMenuBarBehaviorChanged: () -> Void
    #if SPARKLE_RELEASE
    var onInstallUpdate: (() -> Void)? = nil
    #endif

    private let minDatabaseSizeGB = 0.5
    private let maxDatabaseSizeGB = 64.0

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    var body: some View {
        Form {
            Section(String(localized: "Startup")) {
                Toggle(String(localized: "Launch at login"), isOn: launchAtLoginBinding)
                    .disabled(!launchAtLogin.state.canToggle)

                if let message = launchAtLogin.state.displayMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(launchAtLogin.state.hasFailureNotice ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))

                    if launchAtLogin.state.hasFailureNotice {
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
                        Text(String(localized: "Click opens window"))
                        Text(String(localized: "Right-click shows menu instead."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

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
                    .font(.caption)
                }
            }

            #if !APP_STORE
            Section(String(localized: "Paste Behavior")) {
                if settings.hasPostEventPermission {
                    Toggle(String(localized: "Paste directly into apps"), isOn: $settings.autoPasteEnabled)
                    Text(settings.autoPasteEnabled
                        ? String(localized: "Items paste directly into the active app.")
                        : String(localized: "Items copy to clipboard only."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle(String(localized: "Paste directly into apps"), isOn: .constant(false))
                        .disabled(true)
                    Text(String(localized: "Requires Accessibility permission. Restart after granting."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Open System Settings")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .font(.caption)
                }
            }
            #endif

            Section(String(localized: "Database")) {
                LabeledContent(String(localized: "Current Size")) {
                    Text(Utilities.formatBytes(store.databaseSizeBytes))
                        .foregroundStyle(.secondary)
                }

                LabeledContent(String(localized: "Storage Limit")) {
                    HStack(spacing: 8) {
                        Slider(value: databaseSizeSlider, in: 0...1)
                            .frame(maxWidth: .infinity)
                        Text(databaseSizeLabel)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity)
                }

                Text(String(localized: "Oldest items removed when limit is reached."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text(String(localized: "Clear History"))
                    }
                }
                .confirmationDialog(
                    String(localized: "Clear History"),
                    isPresented: $showClearConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "Clear All"), role: .destructive) {
                        store.clear()
                    }
                    Button(String(localized: "Cancel"), role: .cancel) {}
                } message: {
                    Text(String(localized: "Delete all clipboard history? This cannot be undone."))
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

                Text(String(localized: "Test new features before release."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if case .beta = settings.updateChannel {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "Found a bug? Report it on GitHub with steps to reproduce."))
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
                settings.maxDatabaseSizeGB = gbValue(for: newValue)
            }
        )
    }

    private var databaseSizeLabel: String {
        String(localized: "\(settings.maxDatabaseSizeGB, specifier: "%.1f") GB")
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
}
