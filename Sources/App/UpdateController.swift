#if !APP_STORE
import Sparkle
import os.log

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ClipKitty", category: "Update")

// MARK: - Silent User Driver

/// SPUUserDriver that auto-accepts every prompt so updates install without UI.
@MainActor
final class SilentUpdateDriver: NSObject, SPUUserDriver {

    // MARK: Permission

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        log.info("Auto-granting update permission")
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    // MARK: Update found / not found

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if appcastItem.isInformationOnlyUpdate {
            log.info("Information-only update found — dismissing")
            reply(.dismiss)
        } else {
            log.info("Update found: \(appcastItem.displayVersionString) — auto-installing")
            reply(.install)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log.debug("No update found")
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log.error("Updater error: \(error.localizedDescription)")
        AppSettings.shared.updateAvailable = true
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
        AppSettings.shared.updateAvailable = false
        acknowledgement()
    }

    // MARK: Dismiss

    func dismissUpdateInstallation() {
        AppSettings.shared.updateAvailable = false
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

    func setAutoInstall(_ enabled: Bool) {
        updater.automaticallyDownloadsUpdates = enabled
    }
}
#endif
