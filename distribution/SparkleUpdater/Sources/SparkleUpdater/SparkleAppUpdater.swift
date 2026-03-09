import Foundation
import Combine
import Sparkle
import os.log

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ClipKitty", category: "Update")

/// State of update checking
public enum UpdateCheckState: Equatable, Sendable {
    case idle
    case available
    case checkFailed
}

// MARK: - Silent User Driver

/// SPUUserDriver that auto-accepts every prompt so updates install without UI.
@MainActor
final class SilentUpdateDriver: NSObject, SPUUserDriver {

    /// When true, the next `showUpdateFound` will reply `.install` regardless of auto-install setting.
    var forceInstall = false

    /// Callback to update state in the main app
    var onStateChange: ((UpdateCheckState) -> Void)?

    /// Current state
    private(set) var updateCheckState: UpdateCheckState = .idle {
        didSet { onStateChange?(updateCheckState) }
    }

    /// Records when consecutive update-check failures started
    var updateCheckFailingSince: Date? {
        get { UserDefaults.standard.object(forKey: "updateCheckFailingSince") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "updateCheckFailingSince") }
    }

    /// Whether auto-install is enabled
    var autoInstallUpdates: Bool {
        get { UserDefaults.standard.object(forKey: "autoInstallUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoInstallUpdates") }
    }

    // MARK: Permission

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        log.info("Auto-granting update permission")
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    // MARK: Update found / not found

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        log.info("Update found: \(appcastItem.displayVersionString) (build \(appcastItem.versionString))")
        updateCheckState = .idle
        updateCheckFailingSince = nil

        if appcastItem.isInformationOnlyUpdate {
            log.info("Information-only update found — dismissing")
            reply(.dismiss)
        } else if forceInstall || autoInstallUpdates {
            log.info("Update found: \(appcastItem.displayVersionString) — installing")
            forceInstall = false
            reply(.install)
        } else {
            log.info("Update found: \(appcastItem.displayVersionString) — awaiting user action")
            updateCheckState = .available
            reply(.dismiss)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log.debug("No update found")
        updateCheckState = .idle
        updateCheckFailingSince = nil
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log.error("Updater error: \(error.localizedDescription)")
        forceInstall = false
        if updateCheckFailingSince == nil {
            updateCheckFailingSince = Date()
        } else if let since = updateCheckFailingSince,
                  Date().timeIntervalSince(since) > 14 * 24 * 60 * 60 {
            updateCheckState = .checkFailed
        }
        acknowledgement()
    }

    // MARK: Download progress

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

    func showDownloadDidReceiveData(ofLength length: UInt64) {}

    // MARK: Extraction progress

    func showDownloadDidStartExtractingUpdate() {}

    func showExtractionReceivedProgress(_ progress: Double) {}

    // MARK: Install

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        log.info("Update ready — auto-installing and relaunching")
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        log.info("Update installed (relaunched: \(relaunched))")
        updateCheckState = .idle
        updateCheckFailingSince = nil
        acknowledgement()
    }

    // MARK: Dismiss

    func dismissUpdateInstallation() {
        // No-op: Sparkle calls this after a `.dismiss` reply — we need `updateCheckState` to persist.
    }

    func resetState() {
        updateCheckState = .idle
    }
}

// MARK: - Sparkle App Updater

/// Sparkle-based implementation of AppUpdater.
/// Call `start(onStateChange:)` after initialization to begin receiving state updates.
@MainActor
public final class SparkleAppUpdater {
    private let driver = SilentUpdateDriver()
    private let updater: SPUUpdater

    public var autoInstallUpdates: Bool {
        get { driver.autoInstallUpdates }
        set { driver.autoInstallUpdates = newValue }
    }

    /// Initialize the updater. Call `start(onStateChange:)` to begin.
    public init() {
        let bundle = Bundle.main
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: nil)
    }

    /// Start the updater and begin checking for updates.
    /// - Parameter onStateChange: Callback invoked when update state changes (idle, available, checkFailed)
    public func start(onStateChange: @escaping (UpdateCheckState) -> Void) {
        driver.onStateChange = onStateChange

        #if DEBUG
        // Disable auto-updates in debug builds to avoid interrupting development
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        log.info("Debug build — auto-updates disabled")
        #else
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = driver.autoInstallUpdates
        #endif
        updater.updateCheckInterval = 14400 // 4 hours

        let bundle = Bundle.main
        log.info("Feed URL: \(bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "not set")")
        log.info("Version: \(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"), build: \(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")")

        do {
            try updater.start()
            log.info("Sparkle updater started")
            #if !DEBUG
            // Trigger a check shortly after launch to ensure updates are found promptly,
            // rather than waiting for the full scheduled interval on first launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.updater.canCheckForUpdates else { return }
                log.info("Running startup update check")
                self.updater.checkForUpdates()
            }
            #endif
        } catch {
            log.error("Failed to start updater: \(error.localizedDescription)")
        }
    }

    public func checkForUpdates() { updater.checkForUpdates() }

    public func installUpdate() {
        driver.forceInstall = true
        updater.checkForUpdates()
    }

    public func setAutoInstall(_ enabled: Bool) {
        updater.automaticallyDownloadsUpdates = enabled
        if enabled {
            driver.resetState()
            updater.resetUpdateCycle()
        }
    }
}
