#if !APP_STORE
import AppKit
import Sparkle
import os.log

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ClipKitty", category: "Update")

// MARK: - Silent User Driver

/// A Sparkle user driver that auto-accepts all updates without showing UI.
@MainActor
final class SilentUpdateDriver: NSObject, SPUUserDriver {

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        log.info("Update found: \(appcastItem.displayVersionString)")
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        log.error("Updater error: \(error.localizedDescription)")
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Update Available", comment: "Alert title prompting user to update manually")
        alert.informativeText = NSLocalizedString(
            "A new version of ClipKitty is available. Please download it from GitHub.",
            comment: "Alert message when silent auto-update fails"
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("Download", comment: "Button to open GitHub releases page"))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: "Dismiss button"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/jul-sh/clipkitty/releases/latest")!)
        }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

    func showDownloadDidReceiveData(ofLength length: UInt64) {}

    func showDownloadDidStartExtractingUpdate() {}

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        log.info("Update ready, installing and relaunching")
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        if !applicationTerminated {
            retryTerminatingApplication()
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {}
}

// MARK: - Update Controller

@MainActor
final class UpdateController {
    private let updater: SPUUpdater
    private let driver = SilentUpdateDriver()

    init() {
        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: nil
        )
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = true
        updater.updateCheckInterval = 14400 // 4 hours
        do {
            try updater.start()
        } catch {
            log.error("Failed to start updater: \(error.localizedDescription)")
        }
    }

    func checkForUpdates() { updater.checkForUpdates() }
    var canCheckForUpdates: Bool { updater.canCheckForUpdates }
}
#endif
