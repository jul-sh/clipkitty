#if !APP_STORE
import Sparkle
import os.log

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ClipKitty", category: "Update")

/// Delegate for gentle scheduled update reminders (settings banner instead of modal).
@MainActor
final class GentleUpdateDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Only show Sparkle's standard UI when it demands immediate focus.
        // Otherwise, use gentle reminder (settings banner).
        return immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate {
            log.info("Update available (gentle reminder): \(update.displayVersionString)")
            AppSettings.shared.updateAvailable = true
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        AppSettings.shared.updateAvailable = false
    }
}

@MainActor
final class UpdateController {
    private let driverDelegate = GentleUpdateDelegate()
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: driverDelegate
        )
        updaterController.updater.automaticallyChecksForUpdates = true
        updaterController.updater.automaticallyDownloadsUpdates = true
        updaterController.updater.updateCheckInterval = 14400 // 4 hours
    }

    func checkForUpdates() { updaterController.checkForUpdates(nil) }
    var canCheckForUpdates: Bool { updaterController.updater.canCheckForUpdates }
}
#endif
