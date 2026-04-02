import AppKit
import ClipKittyMacPlatform
import ClipKittyShared
import CloudKit
import SwiftUI
import OSLog

struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared
    @State private var showClearConfirmation = false
    @State private var attestationURL: URL?
    @State private var isICloudAvailable = true
    @State private var iCloudStatusMessage: String? = nil
    @State private var logsCopied = false

    let store: ClipboardStore
    #if SPARKLE_RELEASE
        var onInstallUpdate: (() -> Void)? = nil
        var onCheckForUpdates: (() -> Void)? = nil
    #endif

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private let minDatabaseSizeGB = 0.5
    private let maxDatabaseSizeGB = 64.0

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Unknown"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    private var buildChannel: String {
        #if APP_STORE
            return "AppStore"
        #elseif SPARKLE_RELEASE
            return "Sparkle"
        #elseif DEBUG
            return "Debug"
        #else
            return "Release"
        #endif
    }

    private var binaryHash: String? {
        guard let executableURL = Bundle.main.executableURL else { return nil }
        return Utilities.sha256(of: executableURL)
    }

    var body: some View {
        Form {
            Section(String(localized: "Startup")) {
                Toggle(String(localized: "Launch at login"), isOn: launchAtLoginBinding)
                    .disabled(!launchAtLogin.state.canToggle)

                if let message = launchAtLogin.state.displayMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(
                            launchAtLogin.state.hasFailureNotice
                                ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)
                        )

                    if launchAtLogin.state.hasFailureNotice {
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
                }
            }


            #if !APP_STORE
                Section(String(localized: "Paste Items")) {
                    PasteItemsSettingView()
                }
            #endif

            #if ENABLE_SYNC
                Section(String(localized: "iCloud Sync")) {
                    Toggle(String(localized: "Sync clipboard history across devices"), isOn: $settings.syncEnabled)
                        .disabled(!isICloudAvailable)

                    if !isICloudAvailable, let message = iCloudStatusMessage {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if settings.syncEnabled {
                        HStack {
                            syncStatusIcon
                            Text(syncStatusText)
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
            #endif

            Section(String(localized: "History")) {
                LabeledContent(String(localized: "Storage Limit")) {
                    HStack(spacing: 8) {
                        Slider(value: databaseSizeSlider, in: 0 ... 1)
                            .frame(maxWidth: .infinity)
                        Text(databaseSizeLabel)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity)
                }

                Text(
                    String(
                        localized:
                        "Currently using \(Utilities.formatBytes(store.databaseSizeBytes)). Oldest items removed when limit is reached."
                    )
                )
                .font(.subheadline)
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
                    HStack {
                        Text(String(localized: "Status:"))
                        Spacer()
                        switch settings.updateCheckState {
                        case .idle:
                            Text(String(localized: "Up to date"))
                                .foregroundStyle(.secondary)
                        case .checking:
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(String(localized: "Checking…"))
                                    .foregroundStyle(.secondary)
                            }
                        case .downloading:
                            Text(String(localized: "Downloading update…"))
                                .foregroundStyle(.secondary)
                        case .installing:
                            Text(String(localized: "Installing update…"))
                                .foregroundStyle(.secondary)
                        case .available:
                            HStack(spacing: 6) {
                                Text(String(localized: "Update available"))
                                    .fontWeight(.semibold)
                                Button(String(localized: "Install")) {
                                    onInstallUpdate?()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        case .checkFailed(let errorMessage):
                            VStack(alignment: .trailing, spacing: 6) {
                                Label(
                                    String(localized: "Update check failed"),
                                    systemImage: "exclamationmark.triangle"
                                )
                                .foregroundStyle(.orange)

                                Text(errorMessage)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)

                                Button(String(localized: "View Releases on GitHub")) {
                                    NSWorkspace.shared.open(
                                        URL(
                                            string:
                                            "https://github.com/jul-sh/clipkitty/releases/latest"
                                        )!
                                    )
                                }
                                .font(.subheadline)
                            }
                        }
                    }

                    if let lastChecked = settings.lastUpdateCheckDate {
                        HStack(spacing: 4) {
                            switch settings.lastUpdateCheckResult {
                            case .idle:
                                Text(String(localized: "Up to date, as of"))
                            case .available:
                                Text(String(localized: "Update available, as of"))
                            case .downloading:
                                Text(String(localized: "Downloading update, as of"))
                            case .installing:
                                Text(String(localized: "Installing update, as of"))
                            case .checkFailed:
                                Text(String(localized: "Update check failed, as of"))
                            case .checking:
                                EmptyView()
                            }

                            Text(lastChecked, style: .date)
                            Text(lastChecked, style: .time)
                        }
                        .foregroundStyle(.secondary)
                    }

                    Toggle(
                        String(localized: "Automatically install updates"),
                        isOn: $settings.autoInstallUpdates
                    )

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
                        Button(String(localized: "Check for Updates")) {
                            onCheckForUpdates?()
                        }
                        .disabled(settings.updateCheckState != .idle)

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

                        Button(logsCopied ? String(localized: "Logs Copied!") : String(localized: "Copy Recent Logs")) {
                            copyRecentLogs()
                        }
                        .disabled(logsCopied)
                    }
                }
            #endif

            Section(String(localized: "About")) {
                LabeledContent(String(localized: "Version")) {
                    Text("\(appVersion) (\(buildNumber)) \(buildChannel)")
                        .foregroundStyle(.secondary)
                }

                if let url = attestationURL {
                    LabeledContent(String(localized: "Build Attestation")) {
                        Link(destination: url) {
                            Label(String(localized: "Verify"), systemImage: "checkmark.seal")
                        }
                    }
                }
            }
            .task {
                await checkAttestation()
                #if ENABLE_SYNC
                await checkICloudAccountStatus()
                #endif
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

    #if ENABLE_SYNC
        @ViewBuilder
        private var syncStatusIcon: some View {
            if let engine = store.syncEngine {
                switch engine.status {
                case .idle:
                    Image(systemName: "icloud").foregroundStyle(.secondary)
                case .connecting:
                    ProgressView().controlSize(.small)
                case .syncing:
                    ProgressView().controlSize(.small)
                case .synced:
                    Image(systemName: "checkmark.icloud").foregroundStyle(.green)
                case .error:
                    Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
                case .temporarilyUnavailable:
                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
                case .unavailable:
                    Image(systemName: "xmark.icloud").foregroundStyle(.red)
                }
            } else {
                Image(systemName: "icloud.slash").foregroundStyle(.secondary)
            }
        }

        private var syncStatusText: String {
            guard let engine = store.syncEngine else {
                return String(localized: "Not running")
            }
            switch engine.status {
            case .idle:
                return String(localized: "Waiting to sync")
            case .connecting:
                return String(localized: "Connecting to iCloud…")
            case .syncing:
                return String(localized: "Syncing…")
            case let .synced(lastSync):
                let relative = Self.relativeDateFormatter.localizedString(for: lastSync, relativeTo: Date())
                return String(localized: "Synced \(relative)")
            case let .error(message):
                return String(localized: "Error: \(message)")
            case .temporarilyUnavailable:
                return String(localized: "iCloud temporarily unavailable")
            case .unavailable:
                return String(localized: "iCloud not available")
            }
        }

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
                let status = try await CKContainer.default().accountStatus()
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

    private func copyRecentLogs() {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: Date().addingTimeInterval(-3600))
            let entries = try store.getEntries(at: since)
                .compactMap { $0 as? OSLogEntryLog }
                .map { "[\($0.date.formatted(.iso8601))] [\($0.category)] \($0.composedMessage)" }
                .joined(separator: "\n")

            let header = "ClipKitty \(appVersion) (\(buildNumber)) \(buildChannel) — logs from last hour"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(header)\n\n\(entries)", forType: .string)
            logsCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                logsCopied = false
            }
        } catch {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("Failed to read logs: \(error.localizedDescription)", forType: .string)
        }
    }

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
}
