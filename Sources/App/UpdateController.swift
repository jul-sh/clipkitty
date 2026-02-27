#if !APP_STORE
import Sparkle
import os.log

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ClipKitty", category: "Update")

// MARK: - Silent User Driver

/// SPUUserDriver that auto-accepts every prompt so updates install without UI.
@MainActor
final class SilentUpdateDriver: NSObject, SPUUserDriver {

    /// When true, the next `showUpdateFound` will reply `.install` regardless of auto-install setting.
    var forceInstall = false

    // MARK: Permission

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        log.info("Auto-granting update permission")
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    // MARK: Update found / not found

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let settings = AppSettings.shared
        settings.updateCheckFailed = false
        settings.updateCheckFailingSince = nil

        if appcastItem.isInformationOnlyUpdate {
            log.info("Information-only update found — dismissing")
            reply(.dismiss)
        } else if forceInstall || settings.autoInstallUpdates {
            log.info("Update found: \(appcastItem.displayVersionString) — installing")
            forceInstall = false
            reply(.install)
        } else {
            log.info("Update found: \(appcastItem.displayVersionString) — awaiting user action")
            settings.updateAvailable = true
            reply(.dismiss)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log.debug("No update found")
        let settings = AppSettings.shared
        settings.updateAvailable = false
        settings.updateCheckFailed = false
        settings.updateCheckFailingSince = nil
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log.error("Updater error: \(error.localizedDescription)")
        let settings = AppSettings.shared
        forceInstall = false
        if settings.updateCheckFailingSince == nil {
            settings.updateCheckFailingSince = Date()
        } else if let since = settings.updateCheckFailingSince,
                  Date().timeIntervalSince(since) > 14 * 24 * 60 * 60 {
            settings.updateCheckFailed = true
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
        let settings = AppSettings.shared
        settings.updateAvailable = false
        settings.updateCheckFailed = false
        settings.updateCheckFailingSince = nil
        acknowledgement()
    }

    // MARK: Dismiss

    func dismissUpdateInstallation() {
        // No-op: Sparkle calls this after a `.dismiss` reply — we need `updateAvailable` to persist.
    }
}

// MARK: - Update Controller

@MainActor
final class UpdateController {
    private let driver = SilentUpdateDriver()
    private let updater: SPUUpdater

    init() {
        let bundle = Bundle.main
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: nil)
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = AppSettings.shared.autoInstallUpdates
        updater.updateCheckInterval = 14400 // 4 hours

        do {
            try updater.start()
        } catch {
            log.error("Failed to start updater: \(error.localizedDescription)")
        }
    }

    func checkForUpdates() { updater.checkForUpdates() }
    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    func installUpdate() {
        driver.forceInstall = true
        updater.checkForUpdates()
    }

    func setAutoInstall(_ enabled: Bool) {
        updater.automaticallyDownloadsUpdates = enabled
        if enabled {
            AppSettings.shared.updateAvailable = false
            updater.resetUpdateCycle()
        }
    }
}
#endif
