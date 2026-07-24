import AppKit
import ClipKittyMacPlatform
import ClipKittyCore
#if ENABLE_ICLOUD_SYNC
    import ClipKittyCloudSync
    import CloudKit
#endif
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared

    var body: some View {
        Section(String(localized: "General")) {
            Toggle(String(localized: "Launch at login"), isOn: launchAtLoginBinding)

            switch launchAtLogin.state {
            case .enabled, .disabled:
                EmptyView()
            case .registrationFailed:
                launchAtLoginFailure(
                    String(
                        localized:
                        "Could not enable launch at login. Please add ClipKitty manually in System Settings."
                    )
                )
            case .unregistrationFailed:
                launchAtLoginFailure(
                    String(
                        localized:
                        "Could not disable launch at login. Please remove ClipKitty manually in System Settings."
                    )
                )
            }
        }
    }

    private func launchAtLoginFailure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)

            Button(String(localized: "Open Login Items Settings")) {
                NSWorkspace.shared.open(
                    URL(
                        string:
                        "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
                    )!
                )
            }
            .font(.caption)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: {
                switch launchAtLogin.state.registrationStatus {
                case .enabled: return true
                case .disabled: return false
                }
            },
            set: { newValue in
                if launchAtLogin.setEnabled(newValue) {
                    settings.launchAtLoginEnabled = newValue
                }
            }
        )
    }
}

#if ENABLE_ICLOUD_SYNC
    struct SyncSettingsSection: View {
        private enum AccountAvailability: Equatable {
            case checking
            case available
            case unavailable(message: String)
        }

        @ObservedObject private var settings = AppSettings.shared
        @State private var accountAvailability = AccountAvailability.checking

        var body: some View {
            SettingsSyncSection(
                syncEnabled: $settings.syncEnabled,
                availability: settingsAvailability
            )
            .task {
                await checkICloudAccountStatus()
            }
        }

        private var settingsAvailability: SettingsSyncPreferenceAvailability {
            switch accountAvailability {
            case .checking:
                return .checking
            case .available:
                return .available(status: .idle)
            case let .unavailable(message):
                return .unavailable(message: message)
            }
        }

        private func checkICloudAccountStatus() async {
            // CKContainer.default() throws an unrecoverable ObjC exception when
            // the application-identifier entitlement is missing (for example in
            // unsigned UI-test builds), so inspect signing information first.
            guard Self.hasApplicationIdentifierEntitlement else {
                accountAvailability = .unavailable(
                    message: String(
                        localized: "iCloud is not available in this build configuration."
                    )
                )
                return
            }

            do {
                let container = CKContainer(identifier: SyncEngine.cloudKitContainerIdentifier)
                switch try await container.accountStatus() {
                case .available:
                    accountAvailability = .available
                case .noAccount:
                    accountAvailability = .unavailable(
                        message: String(
                            localized: "iCloud account not found. Please log in to enable sync."
                        )
                    )
                case .restricted:
                    accountAvailability = .unavailable(
                        message: String(
                            localized: "iCloud access is restricted on this machine."
                        )
                    )
                case .couldNotDetermine:
                    accountAvailability = .unavailable(
                        message: String(
                            localized: "Could not determine iCloud account status."
                        )
                    )
                case .temporarilyUnavailable:
                    accountAvailability = .unavailable(
                        message: String(
                            localized: "iCloud temporarily unavailable. Please try again later."
                        )
                    )
                @unknown default:
                    accountAvailability = .unavailable(
                        message: String(localized: "iCloud is unavailable.")
                    )
                }
            } catch {
                accountAvailability = .unavailable(
                    message: String(
                        localized: "Error checking iCloud status: \(error.localizedDescription)"
                    )
                )
            }
        }

        private static let hasApplicationIdentifierEntitlement: Bool = {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(
                Bundle.main.bundleURL as CFURL, [], &code
            ) == errSecSuccess, let code else { return false }

            var info: CFDictionary?
            guard SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &info
            ) == errSecSuccess, let info = info as? [String: Any] else { return false }

            guard let entitlements =
                info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
            else { return false }
            return entitlements["com.apple.application-identifier"] != nil
        }()
    }
#endif

struct MacAdvancedSettingsSection: View {
    #if ENABLE_BUILD_ATTESTATION_LINK
        private enum AttestationState: Equatable {
            case checking
            case available(URL)
            case unavailable
        }
    #endif

    @ObservedObject private var settings = AppSettings.shared
    #if ENABLE_BUILD_ATTESTATION_LINK
        @State private var attestationState = AttestationState.checking
    #endif

    let store: ClipboardStore
    #if ENABLE_SPARKLE_UPDATES
        var onInstallUpdate: (() -> Void)? = nil
    #endif

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? String(localized: "Unknown")
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? String(localized: "Unknown")
    }

    private var buildChannel: String {
        Bundle.main.object(forInfoDictionaryKey: "CKBuildChannel") as? String
            ?? String(localized: "Unknown")
    }

    var body: some View {
        SettingsAdvancedSection(
            limitGB: $settings.maxDatabaseSizeGB,
            loadUsedBytes: {
                switch await store.loadDatabaseSizeForSettings() {
                case let .success(usedBytes):
                    return .loaded(usedBytes: usedBytes)
                case let .failure(error):
                    return .failed(message: error.localizedDescription)
                }
            },
            pruneToLimit: {
                switch await store.pruneToLimit() {
                case .success:
                    return .succeeded
                case let .failure(error):
                    return .failed(message: error.localizedDescription)
                }
            },
            clearHistory: {
                switch await store.clearAll() {
                case .success:
                    return .succeeded
                case let .failure(error):
                    return .failed(message: error.localizedDescription)
                }
            },
            appVersion: appVersion,
            buildNumber: buildNumber,
            additionalContent: {
                #if ENABLE_SPARKLE_UPDATES
                    SettingsAdvancedSubsection(title: String(localized: "Updates")) {
                        updatesSettings
                    }
                #else
                    EmptyView()
                #endif
            },
            aboutAdditionalContent: {
                LabeledContent(String(localized: "Build Channel"), value: buildChannel)

                #if ENABLE_BUILD_ATTESTATION_LINK
                    switch attestationState {
                    case .checking, .unavailable:
                        EmptyView()
                    case let .available(url):
                        LabeledContent(String(localized: "Build Attestation")) {
                            Link(destination: url) {
                                Label(
                                    String(localized: "Verify"),
                                    systemImage: "checkmark.seal"
                                )
                            }
                        }
                    }
                #endif
            }
        )
        .task {
            #if ENABLE_BUILD_ATTESTATION_LINK
                await checkAttestation()
            #endif
        }
    }

    #if ENABLE_SPARKLE_UPDATES
        @ViewBuilder
        private var updatesSettings: some View {
            Toggle(
                String(localized: "Automatically install updates"),
                isOn: $settings.autoInstallUpdates
            )

            if !settings.autoInstallUpdates, settings.updateCheckState == .available {
                Button(String(localized: "Install Update")) {
                    onInstallUpdate?()
                }
                .buttonStyle(.borderedProminent)
            }

            SettingsToggleRow(
                title: String(localized: "Get beta updates"),
                description: String(localized: "Test new features before release."),
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

            if case .beta = settings.updateChannel {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        String(
                            localized:
                            "Found a bug? Report it on GitHub with steps to reproduce."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button(String(localized: "Report a Bug")) {
                        NSWorkspace.shared.open(
                            URL(
                                string:
                                "https://github.com/jul-sh/clipkitty/issues/new/choose"
                            )!
                        )
                    }
                }
            }
        }
    #endif

    #if ENABLE_BUILD_ATTESTATION_LINK
        private var binaryHash: String? {
            guard let executableURL = Bundle.main.executableURL else { return nil }
            return Utilities.sha256(of: executableURL)
        }

        private func checkAttestation() async {
            guard let hash = binaryHash else {
                attestationState = .unavailable
                return
            }
            let rekorURL = URL(string: "https://rekor.sigstore.dev/api/v1/index/retrieve")!

            var request = URLRequest(url: rekorURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = "{\"hash\":\"sha256:\(hash)\"}".data(using: .utf8)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200
                else {
                    attestationState = .unavailable
                    return
                }

                let entries = try JSONDecoder().decode([String].self, from: data)
                guard !entries.isEmpty,
                      let url = URL(
                          string: "https://search.sigstore.dev/?hash=sha256:\(hash)"
                      )
                else {
                    attestationState = .unavailable
                    return
                }
                attestationState = .available(url)
            } catch {
                attestationState = .unavailable
            }
        }
    #endif
}
