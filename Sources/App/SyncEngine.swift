import Foundation
import CloudKit
import Observation
import ClipKittyCore

/// Sync engine that coordinates between local GRDB database and CloudKit
@MainActor
@Observable
final class SyncEngine {
    
    // MARK: - Constants
    
    /// CloudKit container identifier
    private static let containerIdentifier = "iCloud.com.clipkitty.app"
    
    /// Helper to get current max item size in bytes
    private var maxSyncItemSizeBytes: Int {
        Int(AppSettings.shared.maxSyncItemSizeMB * 1024 * 1024)
    }
    
    // MARK: - State (Enum-Driven)

    /// Sync engine operational state - uses sum types to co-locate relevant data
    enum State: Equatable {
        /// Sync is disabled by user
        case disabled

        /// Sync is enabled and idle, ready for operations
        case idle(lastSync: Date?)

        /// Currently performing a sync operation
        case syncing(operation: SyncOperation)

        /// Sync failed - includes error info and allows retry
        case failed(error: SyncFailure)

        var isEnabled: Bool {
            switch self {
            case .disabled: return false
            default: return true
            }
        }

        var isIdle: Bool {
            if case .idle = self { return true }
            return false
        }

        var lastSyncDate: Date? {
            switch self {
            case .idle(let lastSync): return lastSync
            case .failed(let failure): return failure.lastSuccessfulSync
            default: return nil
            }
        }
    }

    /// Type of sync operation in progress
    enum SyncOperation: Equatable {
        case initializing
        case pushing(count: Int)
        case pulling
        case pruning
    }

    /// Sync failure with context for recovery
    struct SyncFailure: Equatable {
        let message: String
        let isRetryable: Bool
        let lastSuccessfulSync: Date?

        static func from(_ error: Error, lastSync: Date?) -> SyncFailure {
            let isRetryable: Bool
            let message: String

            if let syncError = error as? SyncError {
                message = syncError.errorDescription ?? "Unknown error"
                isRetryable = syncError.isRetryable
            } else if let ckError = error as? CKError {
                message = ckError.localizedDescription
                isRetryable = ckError.isRetryable
            } else {
                message = error.localizedDescription
                isRetryable = true
            }

            return SyncFailure(message: message, isRetryable: isRetryable, lastSuccessfulSync: lastSync)
        }
    }

    private(set) var state: State = .disabled
    private(set) var lastSyncDate: Date?
    private(set) var pendingCount: Int = 0
    
    // MARK: - CloudKit
    
    private var container: CKContainer?
    private var privateDatabase: CKDatabase?
    private var subscription: CKSubscription?
    
    /// Change token for incremental fetches
    private var serverChangeToken: CKServerChangeToken? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "SyncEngineChangeToken") else {
                return nil
            }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }
        set {
            if let token = newValue,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: "SyncEngineChangeToken")
            } else {
                UserDefaults.standard.removeObject(forKey: "SyncEngineChangeToken")
            }
        }
    }
    
    // MARK: - Dependencies
    
    private weak var clipboardStore: ClipboardStore?
    
    // MARK: - Initialization
    
    init() {}
    
    func configure(clipboardStore: ClipboardStore) {
        self.clipboardStore = clipboardStore
    }
    
    // MARK: - Public API
    
    /// Enable iCloud sync
    func enable() async throws {
        guard state == .disabled else { return }

        state = .syncing(operation: .initializing)

        do {
            // Initialize CloudKit
            container = CKContainer(identifier: Self.containerIdentifier)
            privateDatabase = container?.privateCloudDatabase

            // Verify account status
            guard let container = container else {
                throw SyncError.cloudKitUnavailable
            }

            let status = try await container.accountStatus()
            guard status == .available else {
                throw SyncError.notSignedIn
            }

            // Create custom zone if needed
            try await createZoneIfNeeded()

            // Set up subscription for push notifications
            try await setupSubscription()

            // Perform initial sync
            try await syncNow()

            // State is already set by syncNow on success

        } catch {
            state = .failed(error: SyncFailure.from(error, lastSync: nil))
            throw error
        }
    }
    
    /// Disable iCloud sync
    func disable() {
        state = .disabled
        container = nil
        privateDatabase = nil
        serverChangeToken = nil
    }
    
    /// Perform a full sync cycle
    func syncNow() async throws {
        guard state.isEnabled else { return }

        let previousLastSync = state.lastSyncDate

        do {
            // Push local changes first
            state = .syncing(operation: .pushing(count: pendingCount))
            try await pushPendingChanges()

            // Then pull remote changes
            state = .syncing(operation: .pulling)
            try await fetchRemoteChanges()

            // Finally, prune library if it exceeds the limit
            state = .syncing(operation: .pruning)
            try await pruneSyncedLibraryIfNeeded()

            let now = Date()
            lastSyncDate = now
            state = .idle(lastSync: now)

        } catch {
            state = .failed(error: SyncFailure.from(error, lastSync: previousLastSync))
            throw error
        }
    }
    
    /// Notify that a new item was added locally
    func itemAdded(contentHash: String, sizeBytes: Int) {
        guard state.isEnabled else { return }
        
        // Skip items larger than the size limit
        let limit = maxSyncItemSizeBytes
        guard sizeBytes <= limit else {
            logInfo("Skipping sync for item \(contentHash): size \(sizeBytes) exceeds limit \(limit)")
            return
        }
        
        pendingCount += 1
        
        // Debounce: sync after a short delay to batch multiple changes
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard state.isEnabled else { return }
            try? await pushPendingChanges()
        }
    }
    
    /// Handle a CloudKit push notification
    func handleNotification(_ notification: CKNotification) async {
        guard state.isEnabled,
              notification.subscriptionID == "ClipKittyZoneSubscription" else { return }
        
        do {
            try await fetchRemoteChanges()
        } catch {
            logError("Failed to fetch remote changes: \(error)")
        }
    }
    
    // MARK: - CloudKit Zone Setup
    
    private func createZoneIfNeeded() async throws {
        guard let database = privateDatabase else {
            throw SyncError.cloudKitUnavailable
        }
        
        let zone = CKRecordZone(zoneID: SyncableClipboardItem.zoneID)
        
        do {
            _ = try await database.save(zone)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Zone already exists, that's fine
        }
    }
    
    private func setupSubscription() async throws {
        guard let database = privateDatabase else {
            throw SyncError.cloudKitUnavailable
        }
        
        let subscriptionID = "ClipKittyZoneSubscription"
        
        // Check if subscription already exists
        do {
            _ = try await database.subscription(for: subscriptionID)
            return // Already subscribed
        } catch {
            // Subscription doesn't exist, create it
        }
        
        let subscription = CKRecordZoneSubscription(
            zoneID: SyncableClipboardItem.zoneID,
            subscriptionID: subscriptionID
        )
        
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        
        _ = try await database.save(subscription)
    }
    
    // MARK: - Push Changes
    
    private func pushPendingChanges() async throws {
        guard let database = privateDatabase,
              let store = clipboardStore else { return }
        
        // Get pending items from store
        let pendingItems = await store.getPendingSyncItems(maxSize: maxSyncItemSizeBytes)
        guard !pendingItems.isEmpty else {
            pendingCount = 0
            return
        }
        
        // Convert to CKRecords
        let records = pendingItems.map { $0.toCKRecord() }
        
        // Save in batches (CloudKit has limits)
        let batchSize = 400
        for batch in records.chunked(into: batchSize) {
            let operation = CKModifyRecordsOperation(
                recordsToSave: batch,
                recordIDsToDelete: nil
            )
            operation.savePolicy = .changedKeys
            operation.qualityOfService = QualityOfService.userInitiated
            
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                
                operation.perRecordSaveBlock = { recordID, result in
                    Task { @MainActor in
                        switch result {
                        case .success:
                            await store.markItemAsSynced(recordID: recordID.recordName)
                        case .failure(let error):
                            logError("Failed to save record \(recordID): \(error)")
                        }
                    }
                }
                
                database.add(operation)
            }
        }
        
        pendingCount = 0
    }
    
    // MARK: - Fetch Changes
    
    private func fetchRemoteChanges() async throws {
        guard let database = privateDatabase,
              let store = clipboardStore else { return }
        
        let options = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        options.previousServerChangeToken = serverChangeToken
        
        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [SyncableClipboardItem.zoneID],
            configurationsByRecordZoneID: [SyncableClipboardItem.zoneID: options]
        )
        operation.qualityOfService = QualityOfService.userInitiated
        
        var changedRecords: [CKRecord] = []
        var deletedRecordIDs: [CKRecord.ID] = []
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.recordWasChangedBlock = { (recordID: CKRecord.ID, result: Result<CKRecord, any Error>) in
                if case .success(let record) = result {
                    changedRecords.append(record)
                }
            }
            
            operation.recordWithIDWasDeletedBlock = { (recordID: CKRecord.ID, _) in
                deletedRecordIDs.append(recordID)
            }
            
            operation.recordZoneChangeTokensUpdatedBlock = { [weak self] _, token, _ in
                self?.serverChangeToken = token
            }
            
            operation.recordZoneFetchResultBlock = { [weak self] _, result in
                switch result {
                case .success(let (token, _, _)):
                    self?.serverChangeToken = token
                case .failure(let error):
                    logError("Zone fetch failed: \(error)")
                }
            }
            
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            
            database.add(operation)
        }
        
        // Process fetched records
        for record in changedRecords {
            if let syncableItem = SyncableClipboardItem.from(record: record) {
                // Skip items that are too large
                let itemSize = estimateSize(of: syncableItem)
                let limit = maxSyncItemSizeBytes
                if itemSize <= limit {
                    await store.upsertFromCloud(syncableItem: syncableItem)
                }
            }
        }
        
        // Process deletions
        for recordID in deletedRecordIDs {
            await store.deleteFromCloud(syncRecordID: recordID.recordName)
        }
    }
    
    /// Estimate the size of a syncable item
    private func estimateSize(of item: SyncableClipboardItem) -> Int {
        var size = item.item.textContent.utf8.count
        
        if case .image(let data, _) = item.item.content {
            size += data.count
        }
        
        if case .link(_, let metadata) = item.item.content {
            if let imageData = metadata.imageData {
                size += imageData.count
            }
        }
        
        return size
    }
    
    /// Prune items from synced library if total size exceeds limit
    private func pruneSyncedLibraryIfNeeded() async throws {
        guard let store = clipboardStore else { return }
        
        let limitBytes = Int64(AppSettings.shared.maxSyncLibrarySizeMB) * 1024 * 1024
        guard limitBytes > 0 else { return }
        
        let currentSize = await store.getSyncedLibrarySize()
        if currentSize > limitBytes {
            logInfo("Pruning synced library: \(currentSize) bytes exceeds limit \(limitBytes)")
            await store.pruneSyncedLibrary(maxSizeBytes: limitBytes)
            
            // Note: In a full implementation, we should also delete from CloudKit.
            // For now, items are just marked local or deleted locally to save space.
            // Remote deletions would require tracking recordIDs to delete.
        }
    }
}

// MARK: - Errors

enum SyncError: LocalizedError {
    case cloudKitUnavailable
    case notSignedIn
    case quotaExceeded
    case networkUnavailable

    var errorDescription: String? {
        switch self {
        case .cloudKitUnavailable:
            return "iCloud is not available"
        case .notSignedIn:
            return "Please sign in to iCloud in System Settings"
        case .quotaExceeded:
            return "iCloud storage is full"
        case .networkUnavailable:
            return "Network connection unavailable"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .cloudKitUnavailable, .notSignedIn, .quotaExceeded:
            return false
        case .networkUnavailable:
            return true
        }
    }
}

// MARK: - CKError Extension

extension CKError {
    var isRetryable: Bool {
        switch code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return true
        default:
            return false
        }
    }
}

// MARK: - Array Extension

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
