import ClipKittyRust
import CloudKit
import Foundation
import Observation
import os
import UIKit

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ClipKittyiOS",
    category: "iOSClipboardStore"
)

/// Lifecycle state for the iOS clipboard store.
enum iOSStoreLifecycle: Equatable {
    case initializing
    case rebuildingIndex
    case ready
    case failed(String)
}

/// The iOS clipboard store: read-only, sync-powered.
/// No pasteboard monitoring — items arrive exclusively via iCloud sync from Mac.
@MainActor
final class iOSClipboardStore: ObservableObject {
    // MARK: - Published State

    @Published private(set) var lifecycle: iOSStoreLifecycle = .initializing
    @Published private(set) var contentRevision: Int = 0

    // MARK: - Internal State

    private(set) var repository: ClipboardRepository?
    private var bootstrapTask: Task<Void, Never>?

    #if ENABLE_SYNC
        private var syncEngine: iOSSyncEngine?
    #endif

    @Published var syncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(syncEnabled, forKey: "syncEnabled")
            #if ENABLE_SYNC
                applySyncPreference()
            #endif
        }
    }

    // MARK: - Init

    init() {
        syncEnabled = UserDefaults.standard.object(forKey: "syncEnabled") as? Bool ?? true
        startBootstrap()
    }

    // MARK: - Bootstrap

    private func startBootstrap() {
        guard let dbPath = resolveDatabasePath() else { return }

        let plan: StoreBootstrapPlan
        do {
            plan = try inspectStoreBootstrap(dbPath: dbPath)
        } catch {
            lifecycle = .failed("Database initialization failed: \(error.localizedDescription)")
            return
        }

        switch plan {
        case .ready:
            openSynchronously(dbPath: dbPath)
        case .rebuildIndex:
            lifecycle = .rebuildingIndex
            openWithRebuild(dbPath: dbPath)
        }
    }

    private func openSynchronously(dbPath: String) {
        do {
            let rustStore = try ClipKittyRust.ClipboardStore(dbPath: dbPath)
            let repo = ClipboardRepository(store: rustStore)
            self.repository = repo
            lifecycle = .ready
            #if ENABLE_SYNC
                initializeSyncEngine(rustStore: rustStore)
            #endif
        } catch {
            lifecycle = .failed("Database initialization failed: \(error.localizedDescription)")
        }
    }

    private func openWithRebuild(dbPath: String) {
        bootstrapTask = Task {
            do {
                let rustStore = try await Task.detached(priority: .userInitiated) {
                    let store = try ClipKittyRust.ClipboardStore(dbPath: dbPath)
                    try store.rebuildIndex()
                    return store
                }.value
                let repo = ClipboardRepository(store: rustStore)
                self.repository = repo
                self.lifecycle = .ready
                #if ENABLE_SYNC
                    self.initializeSyncEngine(rustStore: rustStore)
                #endif
            } catch {
                self.lifecycle = .failed(
                    "Database initialization failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func resolveDatabasePath() -> String? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            lifecycle = .failed("Could not locate Application Support directory")
            return nil
        }
        let appDir = appSupport.appendingPathComponent("ClipKitty", isDirectory: true)
        do {
            try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        } catch {
            lifecycle = .failed("Could not create data directory: \(error.localizedDescription)")
            return nil
        }
        return appDir.appendingPathComponent("clipboard.sqlite").path
    }

    // MARK: - Sync

    #if ENABLE_SYNC
        private func initializeSyncEngine(rustStore: ClipKittyRust.ClipboardStore) {
            guard syncEnabled else { return }
            let engine = iOSSyncEngine(store: rustStore)
            engine.onContentChanged = { [weak self] in
                Task { @MainActor in
                    self?.contentRevision += 1
                }
            }
            self.syncEngine = engine
            engine.start()
        }

        private func applySyncPreference() {
            if syncEnabled {
                guard syncEngine == nil, let repo = repository else { return }
                initializeSyncEngine(rustStore: repo.store)
            } else {
                syncEngine?.stop()
                syncEngine = nil
            }
        }
    #endif

    // MARK: - Lifecycle Events

    func handleBecameActive() {
        #if ENABLE_SYNC
            syncEngine?.handleBecameActive()
        #endif
    }

    func handleEnteredBackground() {
        #if ENABLE_SYNC
            syncEngine?.scheduleBackgroundRefresh()
        #endif
    }

    // MARK: - Public API (read-only browsing)

    func startSearch(query: String, filter: ItemQueryFilter) -> ClipboardSearchOperation? {
        repository?.startSearch(query: query, filter: filter)
    }

    func fetchItem(id: String) async -> ClipboardItem? {
        await repository?.fetchItem(id: id)
    }

    func loadRowDecorations(itemIds: [String], query: String) async -> [RowDecorationResult] {
        await repository?.computeRowDecorations(itemIds: itemIds, query: query) ?? []
    }

    func loadPreviewPayload(itemId: String, query: String) async -> PreviewPayload? {
        await repository?.loadPreviewPayload(itemId: itemId, query: query)
    }

    func addTag(itemId: String, tag: ItemTag) async -> Bool {
        guard let repo = repository else { return false }
        let result = await repo.addTag(itemId: itemId, tag: tag)
        if case .success = result { contentRevision += 1 }
        return result.isSuccess
    }

    func removeTag(itemId: String, tag: ItemTag) async -> Bool {
        guard let repo = repository else { return false }
        let result = await repo.removeTag(itemId: itemId, tag: tag)
        if case .success = result { contentRevision += 1 }
        return result.isSuccess
    }

    func deleteItem(itemId: String) async -> Bool {
        guard let repo = repository else { return false }
        let result = await repo.delete(itemId: itemId)
        if case .success = result { contentRevision += 1 }
        return result.isSuccess
    }

    func clearAll() async -> Bool {
        guard let repo = repository else { return false }
        let result = await repo.clear()
        if case .success = result { contentRevision += 1 }
        return result.isSuccess
    }

    func databaseSize() async -> Int64 {
        guard let repo = repository else { return 0 }
        let result = await repo.databaseSize()
        if case let .success(size) = result { return size }
        return 0
    }

    #if ENABLE_SYNC
        var syncStatus: iOSSyncEngine.SyncStatus {
            syncEngine?.status ?? .idle
        }
    #endif
}

// MARK: - Result extension

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
