import ClipKittyContentServices
import ClipKittyCore
import ClipKittyRust
import ClipKittyShortcuts
import ClipKittyStore
import Foundation
import os

/// Owns all app-scoped services for the current foreground session.
///
/// A container is assembled warm — before its store has opened — so the real
/// view tree can render the persisted last feed immediately. Repository work
/// awaits the deferred store; `attach` resolves it once the open completes,
/// and `revokeStore` fails it closed when the session is retired first.
@MainActor
@Observable
final class AppContainer {
    private enum StoreAttachment {
        case pending
        case attached(StoreSession)
        case revoked
    }

    private nonisolated static let logger = Logger(subsystem: "com.clipkitty", category: "iOSBootstrap")

    @ObservationIgnored private var attachment: StoreAttachment = .pending
    @ObservationIgnored private let storeHandle: DeferredStoreHandle
    let repository: ClipboardRepository
    let imageDescriptionUpdater: ImageDescriptionUpdater
    let storeClient: iOSBrowserStoreClient
    let clipboardService: iOSClipboardService
    let settings: iOSSettingsStore
    let haptics: HapticsClient

    var attachedStoreSession: StoreSession? {
        if case let .attached(storeSession) = attachment { return storeSession }
        return nil
    }

    var attachedStore: ClipKittyRust.ClipboardStore? {
        attachedStoreSession?.store
    }

    private init(
        storeHandle: DeferredStoreHandle,
        repository: ClipboardRepository,
        imageDescriptionUpdater: ImageDescriptionUpdater,
        storeClient: iOSBrowserStoreClient,
        clipboardService: iOSClipboardService,
        settings: iOSSettingsStore,
        haptics: HapticsClient
    ) {
        self.storeHandle = storeHandle
        self.repository = repository
        self.imageDescriptionUpdater = imageDescriptionUpdater
        self.storeClient = storeClient
        self.clipboardService = clipboardService
        self.settings = settings
        self.haptics = haptics
    }

    /// Resolves the deferred store for every service assembled around it.
    func attach(_ storeSession: StoreSession) {
        switch attachment {
        case .pending:
            attachment = .attached(storeSession)
            storeHandle.fulfill(storeSession.store)
        case .attached, .revoked:
            preconditionFailure("store attached to a container that already resolved")
        }
    }

    /// Retires a warm container whose open was superseded or suspended before
    /// completing. Pending repository work fails instead of waiting forever.
    func revokeStore() {
        switch attachment {
        case .pending:
            attachment = .revoked
            storeHandle.revoke()
        case .attached, .revoked:
            // An attached session's teardown is governed by the store drain;
            // a revoked container is already terminal.
            break
        }
    }

    static func bootstrap(databasePath customPath: String? = nil) -> Result<AppContainer, BootstrapError> {
        openStore(databasePath: customPath).map(assemble(storeSession:))
    }

    /// The heavy, blocking half of bootstrap: path resolution, migration,
    /// index inspection/repair, and opening the Rust store. Deliberately
    /// nonisolated so a foreground resume can run it off the main actor and
    /// keep rendering the last known state while the database reconnects.
    nonisolated static func openStore(
        databasePath customPath: String? = nil,
        didConstructStore: @Sendable (ClipKittyRust.ClipboardStore) -> Void = { _ in }
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
            return try .success(StoreOpener.open(
                path: dbPath,
                repairStrategy: repairStrategy,
                didConstructStore: didConstructStore
            ))
        } catch {
            return .failure(.databaseOpenFailed(error.localizedDescription))
        }
    }

    /// The cheap, main-actor half of bootstrap: wires the service graph
    /// around a store that is still opening. Every service works through the
    /// deferred repository, so nothing here blocks on the open.
    static func assembleWarm(
        feedSnapshotting: iOSFeedSnapshotting
    ) -> AppContainer {
        let storeHandle = DeferredStoreHandle()
        let repository = ClipboardRepository(deferredStore: storeHandle)
        let previewLoader = PreviewLoader(repository: repository)
        let imageDescriptionUpdater = ImageDescriptionUpdater(repository: repository)
        let storeClient = iOSBrowserStoreClient(
            repository: repository,
            previewLoader: previewLoader,
            feedSnapshotting: feedSnapshotting
        )
        let settings = iOSSettingsStore()
        let clipboardService = iOSClipboardService(settings: settings)
        let haptics = HapticsClient()

        return AppContainer(
            storeHandle: storeHandle,
            repository: repository,
            imageDescriptionUpdater: imageDescriptionUpdater,
            storeClient: storeClient,
            clipboardService: clipboardService,
            settings: settings,
            haptics: haptics
        )
    }

    /// Wires the service graph around an already-opened store.
    static func assemble(storeSession: StoreSession) -> AppContainer {
        let container = assembleWarm(feedSnapshotting: .disabled)
        container.attach(storeSession)
        return container
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
        switch attachment {
        case .pending:
            // Matches cold-launch semantics: a foreground open is (or may
            // soon be) in flight, so saves queue durably and reads keep the
            // out-of-process behavior.
            return .unopened
        case let .attached(storeSession):
            return .ready(storeSession)
        case .revoked:
            return .suspended
        }
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
