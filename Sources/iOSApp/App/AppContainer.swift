import ClipKittyAppleServices
import ClipKittyRust
import ClipKittyShared
import ClipKittyShortcuts
import Foundation
import os

/// Owns all app-scoped services for the current foreground session.
@MainActor
@Observable
final class AppContainer {
    private nonisolated static let logger = Logger(subsystem: "com.clipkitty", category: "iOSBootstrap")

    let storeSession: StoreSession
    let imageDescriptionUpdater: ImageDescriptionUpdater
    let storeClient: iOSBrowserStoreClient
    let clipboardService: iOSClipboardService
    let settings: iOSSettingsStore
    let haptics: HapticsClient

    var store: ClipKittyRust.ClipboardStore {
        storeSession.store
    }

    var repository: ClipboardRepository {
        storeSession.repository
    }

    private init(
        storeSession: StoreSession,
        imageDescriptionUpdater: ImageDescriptionUpdater,
        storeClient: iOSBrowserStoreClient,
        clipboardService: iOSClipboardService,
        settings: iOSSettingsStore,
        haptics: HapticsClient
    ) {
        self.storeSession = storeSession
        self.imageDescriptionUpdater = imageDescriptionUpdater
        self.storeClient = storeClient
        self.clipboardService = clipboardService
        self.settings = settings
        self.haptics = haptics
    }

    static func bootstrap(databasePath customPath: String? = nil) -> Result<AppContainer, BootstrapError> {
        openStore(databasePath: customPath).map(assemble(storeSession:))
    }

    /// The heavy, blocking half of bootstrap: path resolution, migration,
    /// index inspection/repair, and opening the Rust store. Deliberately
    /// nonisolated so a foreground resume can run it off the main actor and
    /// keep rendering the last known state while the database reconnects.
    nonisolated static func openStore(
        databasePath customPath: String? = nil
    ) -> Result<StoreSession, BootstrapError> {
        // Migrate legacy Application Support database to App Group container
        // before resolving the path, so existing users keep their data.
        if customPath == nil {
            DatabasePath.migrateIfNeeded()
        }

        let dbPath: String
        do {
            dbPath = try customPath ?? DatabasePath.resolve()
        } catch {
            return .failure(.databasePathFailed(error.localizedDescription))
        }

        let repairStrategy: StoreIndexRepairStrategy
        #if ENABLE_ICLOUD_SYNC
            repairStrategy = .custom { store in
                switch try iOSIndexMaintenance.queueBootstrapRepairIfNeeded(
                    plan: .rebuildIndex,
                    store: store
                ) {
                case .notNeeded:
                    break
                case let .queued(itemCount):
                    logger.info("Queued bootstrap index repair for \(itemCount) items")
                }

                do {
                    let outcome = try iOSIndexMaintenance.processQueuedBatch(store: store)
                    logIndexMaintenanceOutcome(outcome, context: "bootstrap")
                } catch {
                    logger.error("Bootstrap index maintenance failed: \(error.localizedDescription)")
                }
            }
        #else
            repairStrategy = .rebuildImmediately
        #endif

        do {
            return try .success(StoreOpener.open(path: dbPath, repairStrategy: repairStrategy))
        } catch {
            return .failure(.databaseOpenFailed(error.localizedDescription))
        }
    }

    /// The cheap, main-actor half of bootstrap: wires the service graph
    /// around an already-opened store.
    static func assemble(storeSession: StoreSession) -> AppContainer {
        let repository = storeSession.repository
        let previewLoader = PreviewLoader(repository: repository)
        let imageDescriptionUpdater = ImageDescriptionUpdater(repository: repository)
        let storeClient = iOSBrowserStoreClient(
            repository: repository,
            previewLoader: previewLoader
        )
        let settings = iOSSettingsStore()
        let clipboardService = iOSClipboardService(settings: settings)
        let haptics = HapticsClient(settings: settings)

        return AppContainer(
            storeSession: storeSession,
            imageDescriptionUpdater: imageDescriptionUpdater,
            storeClient: storeClient,
            clipboardService: clipboardService,
            settings: settings,
            haptics: haptics
        )
    }

    enum BootstrapError: LocalizedError {
        case databasePathFailed(String)
        case databaseOpenFailed(String)

        var errorDescription: String? {
            switch self {
            case let .databasePathFailed(reason):
                return "Could not create database directory: \(reason)"
            case let .databaseOpenFailed(reason):
                return "Could not open database: \(reason)"
            }
        }
    }

    func shortcutStoreAvailability() -> ClipKittyShortcutStoreAvailability {
        .ready(storeSession)
    }

    func prepareForSuspension() {
        store.prepareForSuspend()
    }

    /// Prune the database to the user's storage limit, removing oldest items
    /// first. Runs once at bootstrap and again when the limit is lowered in
    /// Settings.
    func pruneToStorageLimit() async {
        let maxGB = settings.maxDatabaseSizeGB
        guard maxGB > 0 else { return }
        let result = await repository.pruneToSize(
            maxBytes: Utilities.bytes(fromGB: maxGB)
        )
        if case let .failure(error) = result {
            Self.logger.error("Storage limit prune failed: \(error.localizedDescription)")
        }
    }

    #if ENABLE_ICLOUD_SYNC
        private nonisolated static func logIndexMaintenanceOutcome(
            _ outcome: IndexMaintenanceOutcome,
            context: String
        ) {
            switch outcome {
            case let .completed(processed):
                logger.info("\(context) index maintenance completed after \(processed) items")
            case let .moreRemaining(processed, remaining):
                logger.info(
                    "\(context) index maintenance processed \(processed) items; \(remaining) remain"
                )
            }
        }
    #endif
}
