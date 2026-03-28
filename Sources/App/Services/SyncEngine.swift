import CloudKit
import ClipKittyRust
import Foundation
import os.log

/// Orchestrates iCloud sync via CloudKit using the Rust event-sourced core.
///
/// Lifecycle:
/// 1. Starts after ClipboardStore.swift sets lifecycle = .ready
/// 2. Sets the Rust-side device ID for event attribution
/// 3. Fetches zone changes since the last token
/// 4. Applies remote snapshots, then remote events
/// 5. Uploads pending local events (with CKAsset for large images)
/// 6. Runs background compaction and CloudKit cleanup on a schedule
/// 7. Triggers full resync when the zone token expires
@MainActor
final class SyncEngine {
    // MARK: - Configuration

    private static let zoneName = "ClipKittySync"
    private static let subscriptionID = "clipkitty-sync-changes"
    private static let compactionInterval: TimeInterval = 300 // 5 minutes
    private static let baseInterval: TimeInterval = 30
    private static let subscriptionActiveInterval: TimeInterval = 60
    /// Base64 payload threshold for CKAsset extraction (500KB ≈ 375KB raw).
    private static let assetThresholdBytes = 500_000
    /// Age threshold for CloudKit event cleanup (30 days).
    private static let cloudCleanupAgeDays: UInt32 = 30

    private let logger = Logger(subsystem: "com.clipkitty", category: "SyncEngine")

    // MARK: - Dependencies

    private let store: ClipKittyRust.ClipboardStore
    private let container: CKContainer
    private let database: CKDatabase
    private let recordZone: CKRecordZone
    private let deviceId: String

    // MARK: - State

    private var syncTask: Task<Void, Never>?
    private var compactionTask: Task<Void, Never>?
    private(set) var isRunning = false
    private var backoff = SyncBackoff()
    private var hasActiveSubscription = false
    private var lastCloudCleanupDate: Date?

    /// Current sync status for UI display.
    @Published private(set) var status: SyncStatus = .idle

    /// Callback invoked after a sync batch changes local content.
    var onContentChanged: (() -> Void)?

    // MARK: - Init

    init(store: ClipKittyRust.ClipboardStore) {
        self.store = store
        self.container = CKContainer(identifier: "iCloud.com.clipkitty")
        self.database = container.privateCloudDatabase
        self.recordZone = CKRecordZone(zoneName: Self.zoneName)

        // Use a stable device identifier.
        if let existing = UserDefaults.standard.string(forKey: "clipkitty.sync.deviceId") {
            self.deviceId = existing
        } else {
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: "clipkitty.sync.deviceId")
            self.deviceId = newId
        }

        self.lastCloudCleanupDate = UserDefaults.standard.object(
            forKey: "clipkitty.sync.lastCloudCleanup"
        ) as? Date
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        logger.info("SyncEngine starting for device \(self.deviceId)")

        // Set the Rust-side device ID so events are attributed correctly.
        store.setSyncDeviceId(deviceId: deviceId)

        syncTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            // Check iCloud availability before starting sync.
            await self.updateStatus(.connecting)
            let status = try? await self.container.accountStatus()
            guard status == .available else {
                self.logger.warning("iCloud account not available (status: \(String(describing: status))), sync disabled")
                await self.setUnavailable()
                return
            }

            await self.ensureZoneExists()
            await self.setupSubscription()
            await self.runSyncLoop()
        }

        compactionTask = Task.detached(priority: .background) { [weak self] in
            await self?.runCompactionLoop()
        }
    }

    func stop() {
        isRunning = false
        syncTask?.cancel()
        compactionTask?.cancel()
        syncTask = nil
        compactionTask = nil
        updateStatus(.idle)
        logger.info("SyncEngine stopped")
    }

    /// Trigger an immediate sync cycle (e.g. from push notification).
    func handleRemoteNotification() {
        guard isRunning else { return }
        Task.detached(priority: .utility) { [weak self] in
            await self?.performSyncCycle()
        }
    }

    // MARK: - Status

    enum SyncStatus: Equatable {
        case idle
        case connecting
        case syncing
        case synced(lastSync: Date)
        case error(String)
        case unavailable
    }

    private func updateStatus(_ newStatus: SyncStatus) {
        status = newStatus
    }

    /// Marks the engine as unavailable and stops it. Callable from detached tasks.
    private func setUnavailable() {
        isRunning = false
        status = .unavailable
    }

    // MARK: - Zone Setup

    private func ensureZoneExists() async {
        do {
            _ = try await database.modifyRecordZones(
                saving: [recordZone],
                deleting: []
            )
            logger.debug("Record zone ensured")
        } catch {
            logger.error("Failed to create record zone: \(error.localizedDescription)")
        }
    }

    // MARK: - Push Subscription

    private func setupSubscription() async {
        let subscriptionSavedKey = "clipkitty.sync.subscriptionSaved"
        if UserDefaults.standard.bool(forKey: subscriptionSavedKey) {
            hasActiveSubscription = true
            return
        }

        do {
            let subscription = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
            let notificationInfo = CKSubscription.NotificationInfo()
            notificationInfo.shouldSendContentAvailable = true
            subscription.notificationInfo = notificationInfo

            try await database.save(subscription)
            UserDefaults.standard.set(true, forKey: subscriptionSavedKey)
            hasActiveSubscription = true
            logger.info("Push subscription created")
        } catch {
            let nsError = error as NSError
            // "subscription already exists" is fine — treat as success.
            if nsError.domain == CKError.errorDomain,
               nsError.code == CKError.serverRejectedRequest.rawValue
            {
                UserDefaults.standard.set(true, forKey: subscriptionSavedKey)
                hasActiveSubscription = true
            } else {
                logger.warning("Push subscription setup failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Sync Loop

    private func runSyncLoop() async {
        while !Task.isCancelled && isRunning {
            await performSyncCycle()

            let interval = hasActiveSubscription
                ? Self.subscriptionActiveInterval
                : Self.baseInterval
            let delay = backoff.currentDelay ?? interval

            try? await Task.sleep(for: .seconds(delay))
        }
    }

    func performSyncCycle() async {
        updateStatus(.syncing)
        do {
            let deviceState = try store.getSyncDeviceState(deviceId: deviceId)

            if deviceState.needsFullResync {
                logger.info("Full resync required")
                await performFullResync()
                backoff.reset()
                updateStatus(.synced(lastSync: Date()))
                return
            }

            if deviceState.indexDirty {
                logger.info("Index dirty, rebuilding")
                try store.rebuildIndex()
                try store.clearIndexDirtyFlag()
            }

            // 1. Fetch remote changes.
            let changeToken = deviceState.zoneChangeToken.flatMap {
                try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
            }
            let changes = await fetchZoneChanges(since: changeToken)

            // 1b. Handle token expiry — trigger full resync immediately.
            if changes.tokenExpired {
                logger.info("Zone change token expired, triggering full resync")
                await performFullResync()
                backoff.reset()
                updateStatus(.synced(lastSync: Date()))
                return
            }

            // 2. Apply remote snapshots first.
            if !changes.snapshots.isEmpty {
                let snapshotRecords = changes.snapshots.map { record in
                    SyncSnapshotRecord(
                        globalItemId: record.recordID.recordName,
                        snapshotRevision: UInt64(record["snapshotRevision"] as? Int64 ?? 0),
                        schemaVersion: UInt32(record["schemaVersion"] as? Int64 ?? 1),
                        coversThroughEvent: record["coversThroughEvent"] as? String,
                        aggregateData: record["aggregateData"] as? String ?? "{}"
                    )
                }
                for snapshot in snapshotRecords {
                    do {
                        try store.applyRemoteSnapshot(record: snapshot)
                    } catch {
                        logger.warning("Failed to apply snapshot: \(error.localizedDescription)")
                    }
                }
            }

            // 3. Apply remote events (with CKAsset rehydration).
            if !changes.events.isEmpty {
                let eventRecords = changes.events.map { record in
                    var payloadData = record["payloadData"] as? String ?? "{}"

                    // Rehydrate CKAsset: inject base64 image data back into payload.
                    if let asset = record["imageAsset"] as? CKAsset,
                       let fileURL = asset.fileURL,
                       let data = try? Data(contentsOf: fileURL)
                    {
                        payloadData = Self.injectBase64IntoPayload(
                            payloadData, key: "data_base64", data: data
                        )
                    }

                    return SyncEventRecord(
                        eventId: record.recordID.recordName,
                        globalItemId: record["globalItemId"] as? String ?? "",
                        originDeviceId: record["originDeviceId"] as? String ?? "",
                        schemaVersion: UInt32(record["schemaVersion"] as? Int64 ?? 1),
                        recordedAt: record["recordedAt"] as? Int64 ?? 0,
                        payloadType: record["payloadType"] as? String ?? "",
                        payloadData: payloadData
                    )
                }
                for event in eventRecords {
                    do {
                        let outcome = try store.applyRemoteEvent(record: event)
                        if case .forked(let snapshotData) = outcome {
                            // Fork outcomes are handled by Rust-side materialization now
                            logger.info("Event forked for item \(event.globalItemId)")
                        }
                    } catch {
                        logger.warning("Failed to apply event \(event.eventId): \(error.localizedDescription)")
                    }
                }
            }

            // 4. Save new zone change token.
            if let newToken = changes.newToken {
                let tokenData = try NSKeyedArchiver.archivedData(
                    withRootObject: newToken,
                    requiringSecureCoding: true
                )
                try store.updateZoneChangeToken(deviceId: deviceId, token: tokenData)
            }

            // 5. Notify UI if anything changed.
            if !changes.events.isEmpty || !changes.snapshots.isEmpty {
                onContentChanged?()
            }

            // 6. Upload pending local events.
            let uploadSuccess = await uploadPendingEvents()
            if uploadSuccess {
                backoff.reset()
                updateStatus(.synced(lastSync: Date()))
            } else {
                // Don't reset backoff or claim synced if upload failed.
                let delay = backoff.registerFailure(
                    error: NSError(
                        domain: "SyncEngine", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Upload failed"]
                    )
                )
                logger.warning("Upload failed, backing off \(delay)s")
                updateStatus(.error("Upload failed"))
            }

        } catch {
            let delay = backoff.registerFailure(error: error)
            logger.error("Sync cycle error: \(error.localizedDescription), backing off \(delay)s")
            updateStatus(.error(error.localizedDescription))
        }
    }

    // MARK: - Zone Changes

    /// Result of fetching zone changes. `tokenExpired` signals the caller should trigger full resync.
    private struct ZoneChangeResult {
        var events: [CKRecord] = []
        var snapshots: [CKRecord] = []
        var newToken: CKServerChangeToken?
        var tokenExpired = false
    }

    private func fetchZoneChanges(
        since changeToken: CKServerChangeToken?
    ) async -> ZoneChangeResult {
        var result = ZoneChangeResult()

        let zoneID = recordZone.zoneID
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = changeToken

        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: [zoneID: config]
        )

        return await withCheckedContinuation { continuation in
            operation.recordWasChangedBlock = { _, fetchResult in
                switch fetchResult {
                case let .success(record):
                    if record.recordType == "ItemEvent" {
                        result.events.append(record)
                    } else if record.recordType == "ItemSnapshot" {
                        result.snapshots.append(record)
                    }
                case let .failure(error):
                    Logger(subsystem: "com.clipkitty", category: "SyncEngine")
                        .warning("Record fetch error: \(error.localizedDescription)")
                }
            }

            operation.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
                result.newToken = token
            }

            operation.recordZoneFetchResultBlock = { _, fetchResult in
                switch fetchResult {
                case let .success((token, _, _)):
                    result.newToken = token
                case let .failure(error):
                    let nsError = error as NSError
                    if nsError.code == CKError.changeTokenExpired.rawValue {
                        result.tokenExpired = true
                    }
                    Logger(subsystem: "com.clipkitty", category: "SyncEngine")
                        .warning("Zone fetch error: \(error.localizedDescription)")
                }
            }

            operation.fetchRecordZoneChangesResultBlock = { _ in
                continuation.resume(returning: result)
            }

            database.add(operation)
        }
    }

    // MARK: - Upload

    /// Returns true if upload succeeded or there was nothing to upload.
    private func uploadPendingEvents() async -> Bool {
        do {
            let pendingEvents = try store.pendingLocalEvents()
            guard !pendingEvents.isEmpty else { return true }

            let zoneID = recordZone.zoneID
            var records: [CKRecord] = []
            var tempFiles: [URL] = []

            for event in pendingEvents {
                let recordID = CKRecord.ID(recordName: event.eventId, zoneID: zoneID)
                let record = CKRecord(recordType: "ItemEvent", recordID: recordID)
                record["globalItemId"] = event.globalItemId as CKRecordValue
                record["originDeviceId"] = event.originDeviceId as CKRecordValue
                record["schemaVersion"] = Int64(event.schemaVersion) as CKRecordValue
                record["recordedAt"] = event.recordedAt as CKRecordValue
                record["payloadType"] = event.payloadType as CKRecordValue

                // CKAsset extraction for large image payloads.
                var payloadData = event.payloadData
                if let (strippedPayload, imageData) = Self.extractLargeBase64(
                    from: payloadData, key: "data_base64", threshold: Self.assetThresholdBytes
                ) {
                    payloadData = strippedPayload
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + ".bin")
                    try imageData.write(to: tempURL)
                    record["imageAsset"] = CKAsset(fileURL: tempURL)
                    tempFiles.append(tempURL)
                }

                record["payloadData"] = payloadData as CKRecordValue
                records.append(record)
            }

            let operation = CKModifyRecordsOperation(
                recordsToSave: records,
                recordIDsToDelete: nil
            )
            operation.savePolicy = .ifServerRecordUnchanged
            operation.isAtomic = false

            let uploadedIds = await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
                var saved: [String] = []
                operation.perRecordSaveBlock = { recordID, result in
                    if case .success = result {
                        saved.append(recordID.recordName)
                    }
                }
                operation.modifyRecordsResultBlock = { _ in
                    continuation.resume(returning: saved)
                }
                database.add(operation)
            }

            // Clean up temp files.
            for url in tempFiles {
                try? FileManager.default.removeItem(at: url)
            }

            if !uploadedIds.isEmpty {
                try store.markEventsUploaded(eventIds: uploadedIds)
                logger.debug("Uploaded \(uploadedIds.count) events")
            }
            return true
        } catch {
            logger.error("Upload error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - CKAsset Helpers

    /// Recursively find and extract a large base64 value from nested JSON.
    private static func extractLargeBase64(
        from jsonString: String, key: String, threshold: Int
    ) -> (String, Data)? {
        guard let jsonData = jsonString.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { return nil }

        var extractedData: Data?

        func walk(_ dict: inout [String: Any]) -> Bool {
            if let base64String = dict[key] as? String,
               base64String.count > threshold,
               let rawData = Data(base64Encoded: base64String)
            {
                dict[key] = ""
                extractedData = rawData
                return true
            }
            for (k, v) in dict {
                if var nested = v as? [String: Any], walk(&nested) {
                    dict[k] = nested
                    return true
                }
            }
            return false
        }

        guard walk(&root),
              let data = extractedData,
              let strippedData = try? JSONSerialization.data(withJSONObject: root),
              let strippedString = String(data: strippedData, encoding: .utf8)
        else { return nil }

        return (strippedString, data)
    }

    /// Recursively inject base64-encoded data back into nested JSON.
    private static func injectBase64IntoPayload(
        _ jsonString: String, key: String, data: Data
    ) -> String {
        guard let jsonData = jsonString.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { return jsonString }

        let base64String = data.base64EncodedString()

        func walk(_ dict: inout [String: Any]) -> Bool {
            if dict[key] is String {
                dict[key] = base64String
                return true
            }
            for (k, v) in dict {
                if var nested = v as? [String: Any], walk(&nested) {
                    dict[k] = nested
                    return true
                }
            }
            return false
        }

        guard walk(&root),
              let resultData = try? JSONSerialization.data(withJSONObject: root),
              let resultString = String(data: resultData, encoding: .utf8)
        else { return jsonString }

        return resultString
    }

    // MARK: - Compaction

    private func runCompactionLoop() async {
        while !Task.isCancelled && isRunning {
            try? await Task.sleep(for: .seconds(Self.compactionInterval))
            await performCompaction()
            await uploadSnapshots()
            await performCloudCleanupIfDue()
        }
    }

    func performCompaction() async {
        do {
            let result = try store.runCompaction()
            if result.itemsCompacted > 0 || result.eventsPurged > 0 || result.tombstonesPurged > 0 {
                logger.info(
                    "Compaction: \(result.itemsCompacted) items, \(result.eventsPurged) events purged, \(result.tombstonesPurged) tombstones purged"
                )
            }
        } catch {
            logger.error("Compaction error: \(error.localizedDescription)")
        }
    }

    /// Upload compacted snapshots to CloudKit so other devices can full-resync.
    private func uploadSnapshots() async {
        do {
            let snapshots = try store.pendingSnapshotRecords()
            guard !snapshots.isEmpty else { return }

            let zoneID = recordZone.zoneID
            let records: [CKRecord] = snapshots.map { snapshot in
                let recordID = CKRecord.ID(recordName: snapshot.globalItemId, zoneID: zoneID)
                let record = CKRecord(recordType: "ItemSnapshot", recordID: recordID)
                record["snapshotRevision"] = Int64(snapshot.snapshotRevision) as CKRecordValue
                record["schemaVersion"] = Int64(snapshot.schemaVersion) as CKRecordValue
                record["coversThroughEvent"] = snapshot.coversThroughEvent as CKRecordValue?
                record["aggregateData"] = snapshot.aggregateData as CKRecordValue
                return record
            }

            for chunk in records.chunked(into: 400) {
                let operation = CKModifyRecordsOperation(
                    recordsToSave: chunk,
                    recordIDsToDelete: nil
                )
                operation.savePolicy = .changedKeys
                operation.isAtomic = false

                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    operation.modifyRecordsResultBlock = { _ in
                        continuation.resume()
                    }
                    database.add(operation)
                }
            }

            logger.debug("Uploaded \(snapshots.count) snapshots to CloudKit")
        } catch {
            logger.error("Snapshot upload error: \(error.localizedDescription)")
        }
    }

    // MARK: - CloudKit Cleanup

    private func performCloudCleanupIfDue() async {
        // Run at most once per day.
        if let lastCleanup = lastCloudCleanupDate,
           Date().timeIntervalSince(lastCleanup) < 86400
        {
            return
        }

        do {
            let eventIds = try store.purgeableCloudEventIds(maxAgeDays: Self.cloudCleanupAgeDays)
            guard !eventIds.isEmpty else {
                lastCloudCleanupDate = Date()
                UserDefaults.standard.set(lastCloudCleanupDate, forKey: "clipkitty.sync.lastCloudCleanup")
                return
            }

            // Delete from CloudKit.
            let zoneID = recordZone.zoneID
            let recordIDs = eventIds.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }

            // CloudKit batch delete limit is 400; chunk if needed.
            for chunk in recordIDs.chunked(into: 400) {
                let operation = CKModifyRecordsOperation(
                    recordsToSave: nil,
                    recordIDsToDelete: chunk
                )
                operation.isAtomic = false

                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    operation.modifyRecordsResultBlock = { _ in
                        continuation.resume()
                    }
                    database.add(operation)
                }
            }

            // Purge locally after successful CloudKit deletion.
            let purged = try store.purgeCloudEvents(eventIds: eventIds)
            logger.info("CloudKit cleanup: deleted \(purged) old compacted events")

            lastCloudCleanupDate = Date()
            UserDefaults.standard.set(lastCloudCleanupDate, forKey: "clipkitty.sync.lastCloudCleanup")
        } catch {
            logger.error("CloudKit cleanup error: \(error.localizedDescription)")
        }
    }

    // MARK: - Full Resync

    private func performFullResync() async {
        logger.info("Starting full resync")
        do {
            // 1. Fetch all snapshots from CloudKit.
            let allSnapshots = await fetchAllSnapshots()

            // 2. Convert to FFI records.
            let snapshotRecords = allSnapshots.map { record in
                SyncSnapshotRecord(
                    globalItemId: record.recordID.recordName,
                    snapshotRevision: UInt64(record["snapshotRevision"] as? Int64 ?? 0),
                    schemaVersion: UInt32(record["schemaVersion"] as? Int64 ?? 1),
                    coversThroughEvent: record["coversThroughEvent"] as? String,
                    aggregateData: record["aggregateData"] as? String ?? "{}"
                )
            }

            // 3. Clear and rebuild from snapshots.
            let applied = try store.fullResync(snapshotRecords: snapshotRecords)
            logger.info("Full resync applied \(applied) snapshots")

            // 4. Rebuild Tantivy index.
            try store.rebuildIndex()
            try store.clearIndexDirtyFlag()

            // 5. Get fresh token.
            try store.updateZoneChangeToken(deviceId: deviceId, token: nil)

            // 6. Notify UI.
            onContentChanged?()

        } catch {
            logger.error("Full resync error: \(error.localizedDescription)")
        }
    }

    private func fetchAllSnapshots() async -> [CKRecord] {
        var snapshots: [CKRecord] = []
        let zoneID = recordZone.zoneID
        var cursor: CKQueryOperation.Cursor?

        do {
            let query = CKQuery(recordType: "ItemSnapshot", predicate: NSPredicate(value: true))
            let (results, queryCursor) = try await database.records(
                matching: query,
                inZoneWith: zoneID,
                resultsLimit: CKQueryOperation.maximumResults
            )
            for (_, result) in results {
                if case let .success(record) = result {
                    snapshots.append(record)
                }
            }
            cursor = queryCursor

            while let activeCursor = cursor {
                let (moreResults, nextCursor) = try await database.records(
                    continuingMatchFrom: activeCursor,
                    resultsLimit: CKQueryOperation.maximumResults
                )
                for (_, result) in moreResults {
                    if case let .success(record) = result {
                        snapshots.append(record)
                    }
                }
                cursor = nextCursor
            }
        } catch {
            logger.error("Fetch all snapshots error: \(error.localizedDescription)")
        }

        return snapshots
    }
}

// MARK: - Backoff

/// Exponential backoff with CKError-aware delay extraction.
private struct SyncBackoff {
    private static let baseDelay: TimeInterval = 30
    private static let maxDelay: TimeInterval = 900 // 15 minutes
    private static let quotaDelay: TimeInterval = 300 // 5 minutes

    private(set) var currentDelay: TimeInterval?
    private var consecutiveFailures = 0

    mutating func reset() {
        currentDelay = nil
        consecutiveFailures = 0
    }

    /// Register a failure and return the delay to use.
    @discardableResult
    mutating func registerFailure(error: Error) -> TimeInterval {
        consecutiveFailures += 1

        let delay: TimeInterval
        let ckError = error as? CKError

        switch ckError?.code {
        case .requestRateLimited, .serviceUnavailable:
            // Use server-provided retry-after if available.
            if let retryAfter = ckError?.retryAfterSeconds {
                delay = retryAfter
            } else {
                delay = min(Self.baseDelay * pow(2, Double(consecutiveFailures - 1)), Self.maxDelay)
            }
        case .quotaExceeded:
            delay = Self.quotaDelay
        case .networkUnavailable, .networkFailure:
            delay = min(Self.baseDelay * pow(2, Double(consecutiveFailures - 1)), Self.maxDelay)
        case .serverResponseLost:
            // Retry quickly once.
            delay = consecutiveFailures <= 1 ? 2 : Self.baseDelay
        default:
            delay = min(Self.baseDelay * pow(2, Double(consecutiveFailures - 1)), Self.maxDelay)
        }

        currentDelay = delay
        return delay
    }
}

// MARK: - Array Chunking

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
