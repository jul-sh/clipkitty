import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared
    @State private var showClearConfirmation = false

    let store: ClipboardStore
    let onHotKeyChanged: (HotKey) -> Void
    let onMenuBarBehaviorChanged: () -> Void
    #if SPARKLE_RELEASE
    var onInstallUpdate: (() -> Void)? = nil
    #endif

    private let minDatabaseSizeGB = 0.5
    private let maxDatabaseSizeGB = 64.0

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
                        Text(String(localized: "Click to open"))
                        Text(String(localized: "Click opens ClipKitty, right-click shows menu."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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

            Section(String(localized: "Storage")) {
                LabeledContent(String(localized: "Current Size")) {
                    Text(Utilities.formatBytes(store.databaseSizeBytes))
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
