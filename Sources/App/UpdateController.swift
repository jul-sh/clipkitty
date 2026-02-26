#if !APP_STORE
import Sparkle

@MainActor
final class UpdateController {
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        updaterController.updater.automaticallyChecksForUpdates = true
        updaterController.updater.automaticallyDownloadsUpdates = true
        updaterController.updater.updateCheckInterval = 14400 // 4 hours
    }

    func checkForUpdates() { updaterController.checkForUpdates(nil) }
    var canCheckForUpdates: Bool { updaterController.updater.canCheckForUpdates }
}
#endif
