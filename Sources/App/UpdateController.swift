#if !APP_STORE
import Sparkle
#endif

@MainActor
final class UpdateController {
    #if !APP_STORE
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
    #else
    init() {}
    #endif
}
