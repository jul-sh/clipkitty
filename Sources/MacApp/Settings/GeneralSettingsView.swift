import AppKit
import ClipKittyCore
import ClipKittyMacPlatform
#if ENABLE_ICLOUD_SYNC
    import ClipKittyCloudSync
    import CloudKit
#endif
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var runtimeState = AppRuntimeState.shared
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared
    #if ENABLE_BUILD_ATTESTATION_LINK
        @State private var attestationURL: URL?
    #endif
    @State private var isICloudAvailable = true
    @State private var iCloudStatusMessage: String? = nil
    @State private var committedLimitGB: Double?
    @State private var showShrinkConfirmation = false
    @State private var isAdvancedExpanded = false

    let store: ClipboardStore
    #if ENABLE_SPARKLE_UPDATES
        var onInstallUpdate: (() -> Void)? = nil
    #endif

    private let limitScale = StorageLimitScale()

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Unknown"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    private var buildChannel: String {
        Bundle.main.object(forInfoDictionaryKey: "CKBuildChannel") as? String ?? "Unknown"
    }

    private var binaryHash: String? {
        guard let executableURL = Bundle.main.executableURL else { return nil }
        return Utilities.sha256(of: executableURL)
    }

    var body: some View {
        Form {
            Section(String(localized: "Behavior")) {
                Toggle(String(localized: "Launch at login"), isOn: launchAtLoginBinding)

                if let message = launchAtLogin.state.displayMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.red)

                    Button(String(localized: "Open Login Items Settings")) {
                        NSWorkspace.shared.open(
                            URL(
                                string:
                                "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
                            )!
                        )
                    }
                    .font(.subheadline)
                }

                #if ENABLE_ICLOUD_SYNC
                    Toggle(String(localized: "Sync clipboard history across devices via iCloud"), isOn: $settings.syncEnabled)
                        .disabled(!isICloudAvailable)

                    if !isICloudAvailable, let message = iCloudStatusMessage {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                #endif
            }

            #if ENABLE_SYNTHETIC_PASTE
                Section(String(localized: "Paste Items")) {
                    PasteItemsSettingView()
                }
            #endif

            Section(String(localized: "Appearance")) {
                AppearanceSettingsBody()
            }

            Section {
                DisclosureGroup(String(localized: "Advanced"), isExpanded: $isAdvancedExpanded) {
                    historySettings
                    #if ENABLE_SPARKLE_UPDATES
                        updatesSettings
                    #endif
                    aboutSettings
                }
            }
            .task {
                #if ENABLE_BUILD_ATTESTATION_LINK
                    await checkAttestation()
                #endif
                #if ENABLE_ICLOUD_SYNC
                    await checkICloudAccountStatus()
                #endif
            }
        }
        .formStyle(.grouped)
        .onAppear {
            store.refreshDatabaseSize()
            if settings.maxDatabaseSizeGB <= 0 {
                settings.maxDatabaseSizeGB = limitScale.minGB
            }
            committedLimitGB = settings.maxDatabaseSizeGB
        }
    }

    // MARK: - Advanced subsections

    @ViewBuilder
    private var historySettings: some View {
        advancedHeader(String(localized: "History"))

        VStack(spacing: 10) {
            StorageBarView(
                limitGB: $settings.maxDatabaseSizeGB,
                usedBytes: store.databaseSizeBytes,
                scale: limitScale,
                onEditingEnded: handleStorageLimitEdit
            )

            Text(
                String(
                    localized:
                    "Drag the handle to set how much space history can use. When it fills, the oldest items are overwritten."
                )
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .alert(
            String(localized: "Reduce Storage Limit?"),
            isPresented: $showShrinkConfirmation
        ) {
            Button(String(localized: "Remove Oldest Items"), role: .destructive) {
                committedLimitGB = settings.maxDatabaseSizeGB
                Task { await store.pruneToLimit() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                if let committed = committedLimitGB {
                    settings.maxDatabaseSizeGB = committed
                }
            }
        } message: {
            Text(
                String(
                    localized:
                    "History already uses more space than the new limit. The oldest items will be removed to fit."
                )
            )
        }
    }

    #if ENABLE_SPARKLE_UPDATES
        @ViewBuilder
        private var updatesSettings: some View {
            advancedHeader(String(localized: "Updates"))

            Toggle(
                String(localized: "Automatically install updates"),
                isOn: $settings.autoInstallUpdates
            )

            if !settings.autoInstallUpdates, runtimeState.updateCheckState == .available {
                Button(String(localized: "Install Update")) {
                    onInstallUpdate?()
                }
                .buttonStyle(.borderedProminent)
            }

            VStack(alignment: .leading, spacing: 8) {
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
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if case .beta = settings.updateChannel {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        String(
                            localized:
                            "Found a bug? Report it on GitHub with steps to reproduce."
                        )
                    )
                    .font(.subheadline)
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

    @ViewBuilder
    private var aboutSettings: some View {
        advancedHeader(String(localized: "About"))

        LabeledContent(String(localized: "Version")) {
            Text("\(appVersion) (\(buildNumber)) \(buildChannel)")
                .foregroundStyle(.secondary)
        }

        #if ENABLE_BUILD_ATTESTATION_LINK
            if let url = attestationURL {
                LabeledContent(String(localized: "Build Attestation")) {
                    Link(destination: url) {
                        Label(String(localized: "Verify"), systemImage: "checkmark.seal")
                    }
                }
            }
        #endif
    }

    /// Section label shown inside the Advanced disclosure group, styled like a
    /// grouped-form section header so each subsection stays distinct.
    private func advancedHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }

    /// Called when the user releases the dial knob. Shrinking the limit below
    /// the space already used deletes the oldest items, so confirm first;
    /// otherwise just remember the new value as the committed one.
    private func handleStorageLimitEdit() {
        if store.databaseSizeBytes > Utilities.bytes(fromGB: settings.maxDatabaseSizeGB) {
            showShrinkConfirmation = true
        } else {
            committedLimitGB = settings.maxDatabaseSizeGB
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: {
                switch launchAtLogin.state.registrationStatus {
                case .enabled: true
                case .disabled: false
                }
            },
            set: { newValue in
                if launchAtLogin.setEnabled(newValue) {
                    settings.launchAtLoginEnabled = newValue
                }
            }
        )
    }

    #if ENABLE_ICLOUD_SYNC
        private func checkICloudAccountStatus() async {
            // CKContainer.default() throws an unrecoverable ObjC exception when
            // the com.apple.application-identifier entitlement is missing (e.g.
            // unsigned UI test builds with CODE_SIGNING_ALLOWED=NO). Guard against
            // this by checking the entitlement at runtime first.
            guard Self.hasApplicationIdentifierEntitlement else {
                isICloudAvailable = false
                iCloudStatusMessage = String(localized: "iCloud is not available in this build configuration.")
                return
            }

            do {
                let container = CKContainer(identifier: SyncEngine.cloudKitContainerIdentifier)
                let status = try await container.accountStatus()
                switch status {
                case .available:
                    isICloudAvailable = true
                case .noAccount:
                    isICloudAvailable = false
                    iCloudStatusMessage = String(localized: "iCloud account not found. Please log in to enable sync.")
                case .restricted:
                    isICloudAvailable = false
                    iCloudStatusMessage = String(localized: "iCloud access is restricted on this machine.")
                case .couldNotDetermine:
                    isICloudAvailable = false
                    iCloudStatusMessage = String(localized: "Could not determine iCloud account status.")
                case .temporarilyUnavailable:
                    isICloudAvailable = false
                    iCloudStatusMessage = String(localized: "iCloud temporarily unavailable. Please try again later.")
                @unknown default:
                    isICloudAvailable = false
                }
            } catch {
                isICloudAvailable = false
                iCloudStatusMessage = String(localized: "Error checking iCloud status: \(error.localizedDescription)")
            }
        }

        /// Check whether the running binary has the application-identifier entitlement
        /// that CloudKit requires. Returns false for unsigned/ad-hoc signed binaries.
        private static let hasApplicationIdentifierEntitlement: Bool = {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(
                Bundle.main.bundleURL as CFURL, [], &code
            ) == errSecSuccess, let code else { return false }

            var info: CFDictionary?
            guard SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &info
            ) == errSecSuccess, let info = info as? [String: Any] else { return false }

            guard let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
            else { return false }
            return entitlements["com.apple.application-identifier"] != nil
        }()
    #endif

    #if ENABLE_BUILD_ATTESTATION_LINK
        private func checkAttestation() async {
            guard let hash = binaryHash else { return }
            let rekorURL = URL(string: "https://rekor.sigstore.dev/api/v1/index/retrieve")!

            var request = URLRequest(url: rekorURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = "{\"hash\":\"sha256:\(hash)\"}".data(using: .utf8)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200
                else { return }

                let entries = try JSONDecoder().decode([String].self, from: data)
                if !entries.isEmpty {
                    attestationURL = URL(string: "https://search.sigstore.dev/?hash=sha256:\(hash)")
                }
            } catch {
                // No attestation available
            }
        }
    #endif
}
