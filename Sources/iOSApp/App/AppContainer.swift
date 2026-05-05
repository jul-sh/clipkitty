import ClipKittyAppleServices
import ClipKittyRust
import ClipKittyShared
import ClipKittyShortcuts
import Foundation

/// Owns all app-scoped services. Created once at launch.
@MainActor
@Observable
final class AppContainer {
    let store: ClipKittyRust.ClipboardStore
    let repository: ClipboardRepository
    let previewLoader: PreviewLoader
    let storeClient: iOSBrowserStoreClient
    let clipboardService: iOSClipboardService
    let settings: iOSSettingsStore
    let haptics: HapticsClient

    private init(
        store: ClipKittyRust.ClipboardStore,
        repository: ClipboardRepository,
        previewLoader: PreviewLoader,
        storeClient: iOSBrowserStoreClient,
        clipboardService: iOSClipboardService,
        settings: iOSSettingsStore,
        haptics: HapticsClient
    ) {
        self.store = store
        self.repository = repository
        self.previewLoader = previewLoader
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

        if plan == .rebuildIndex {
            do {
                try store.rebuildIndex()
            } catch {
                return .failure(.databaseOpenFailed("Index rebuild failed: \(error.localizedDescription)"))
            }
        }

        let repository = ClipboardRepository(store: store)
        let previewLoader = PreviewLoader(repository: repository)
        let storeClient = iOSBrowserStoreClient(
            repository: repository,
            previewLoader: previewLoader
        )
        let clipboardService = iOSClipboardService()
        let settings = iOSSettingsStore()
        let haptics = HapticsClient(settings: settings)

        return .success(AppContainer(
            store: store,
            repository: repository,
            previewLoader: previewLoader,
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

}
