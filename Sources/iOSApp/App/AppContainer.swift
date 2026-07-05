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
    private static let logger = Logger(subsystem: "com.clipkitty", category: "iOSBootstrap")

    let store: ClipKittyRust.ClipboardStore
    let repository: ClipboardRepository
    let previewLoader: PreviewLoader
    let imageDescriptionUpdater: ImageDescriptionUpdater
    let storeClient: iOSBrowserStoreClient
    let clipboardService: iOSClipboardService
    let settings: iOSSettingsStore
    let haptics: HapticsClient

    private init(
        store: ClipKittyRust.ClipboardStore,
        repository: ClipboardRepository,
        previewLoader: PreviewLoader,
        imageDescriptionUpdater: ImageDescriptionUpdater,
        storeClient: iOSBrowserStoreClient,
        clipboardService: iOSClipboardService,
        settings: iOSSettingsStore,
        haptics: HapticsClient
    ) {
        self.store = store
        self.repository = repository
        self.previewLoader = previewLoader
        self.imageDescriptionUpdater = imageDescriptionUpdater
        self.storeClient = storeClient
        self.clipboardService = clipboardService
        self.settings = settings
        self.haptics = haptics
    }

    static func bootstrap(databasePath customPath: String? = nil) -> Result<AppContainer, BootstrapError> {
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

        // Inspect the bootstrap plan first so we can rebuild the Tantivy
        // index when it's missing or out-of-date relative to the sqlite
        // file. This matches the macOS flow in Sources/MacApp/ClipboardStore.swift
        // and is required for any scenario where the sqlite file is present
        // but the sibling `tantivy_index_<version>/` directory isn't — e.g.
        // a fresh install after an iCloud restore, or the UI screenshot
        // test pointing at a synthetic DB copied to /tmp. Without this,
        // searches silently return zero results.
        let plan: StoreBootstrapPlan
        do {
            plan = try inspectStoreBootstrap(dbPath: dbPath)
        } catch {
            return .failure(.databaseOpenFailed(error.localizedDescription))
        }

        let store: ClipKittyRust.ClipboardStore
        do {
            store = try ClipKittyRust.ClipboardStore(dbPath: dbPath)
        } catch {
            return .failure(.databaseOpenFailed(error.localizedDescription))
        }

        switch plan {
        case .ready:
            break
        case .rebuildIndex:
            #if ENABLE_ICLOUD_SYNC
                do {
                    switch try iOSIndexMaintenance.queueBootstrapRepairIfNeeded(
                        plan: plan,
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
                } catch {
                    return .failure(.databaseOpenFailed("Index repair queue failed: \(error.localizedDescription)"))
                }
            #else
                do {
                    try store.rebuildIndex()
                } catch {
                    return .failure(.databaseOpenFailed("Index rebuild failed: \(error.localizedDescription)"))
                }
            #endif
        }

        let repository = ClipboardRepository(store: store)
        let previewLoader = PreviewLoader(repository: repository)
        let imageDescriptionUpdater = ImageDescriptionUpdater(repository: repository)
        let storeClient = iOSBrowserStoreClient(
            repository: repository,
            previewLoader: previewLoader
        )
        let settings = iOSSettingsStore()
        let clipboardService = iOSClipboardService(settings: settings)
        let haptics = HapticsClient(settings: settings)

        return .success(AppContainer(
            store: store,
            repository: repository,
            previewLoader: previewLoader,
            imageDescriptionUpdater: imageDescriptionUpdater,
            storeClient: storeClient,
            clipboardService: clipboardService,
            settings: settings,
            haptics: haptics
        ))
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

    func shortcutRepositoryAvailability() -> ClipKittyShortcutRepositoryAvailability {
        .ready(repository)
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
        if case let .failure(error) = await repository.pruneToSize(
            maxBytes: Utilities.bytes(fromGB: maxGB)
        ) {
            Self.logger.error("Storage limit prune failed: \(error.localizedDescription)")
        }
    }

    #if ENABLE_ICLOUD_SYNC
        private static func logIndexMaintenanceOutcome(
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
