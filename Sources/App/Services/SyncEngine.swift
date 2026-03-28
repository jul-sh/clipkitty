import CloudKit
import ClipKittyRust
import Foundation
import os.log

/// Orchestrates iCloud sync via CloudKit using the Rust event-sourced core.
///
/// Lifecycle:
/// 1. Starts after ClipboardStore.swift sets lifecycle = .ready
/// 2. Fetches zone changes since the last token
/// 3. Applies remote snapshots, then remote events
/// 4. Uploads pending local events
/// 5. Runs background compaction on a schedule
/// 6. Triggers full resync when the zone token expires
final class SyncEngine {
    // MARK: - Configuration

    private static let zoneName = "ClipKittySync"
    private static let subscriptionID = "clipkitty-sync-changes"
    private static let compactionInterval: TimeInterval = 300 // 5 minutes
    private static let syncInterval: TimeInterval = 30

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
    private var isRunning = false

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
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        logger.info("SyncEngine starting for device \(self.deviceId)")

        syncTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            // Check iCloud availability before starting sync.
            let status = try? await self.container.accountStatus()
            guard status == .available else {
                self.logger.warning("iCloud account not available (status: \(String(describing: status))), sync disabled")
                self.isRunning = false
                return
            }

            await self.ensureZoneExists()
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
        logger.info("SyncEngine stopped")
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

    // MARK: - Sync Loop

    private func runSyncLoop() async {
        while !Task.isCancelled && isRunning {
            await performSyncCycle()
            try? await Task.sleep(for: .seconds(Self.syncInterval))
        }
    }

    func performSyncCycle() async {
        do {
            let deviceState = try store.getSyncDeviceState(deviceId: deviceId)

            if deviceState.needsFullResync {
                logger.info("Full resync required")
                await performFullResync()
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
                    _ = try? store.applyRemoteSnapshot(record: snapshot)
                }
            }

            // 3. Apply remote events.
            if !changes.events.isEmpty {
                let eventRecords = changes.events.map { record in
                    SyncEventRecord(
                        eventId: record.recordID.recordName,
                        globalItemId: record["globalItemId"] as? String ?? "",
                        originDeviceId: record["originDeviceId"] as? String ?? "",
                        schemaVersion: UInt32(record["schemaVersion"] as? Int64 ?? 1),
                        recordedAt: record["recordedAt"] as? Int64 ?? 0,
                        payloadType: record["payloadType"] as? String ?? "",
                        payloadData: record["payloadData"] as? String ?? "{}"
                    )
                }
                for event in eventRecords {
                    _ = try? store.applyRemoteEvent(record: event)
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
            await uploadPendingEvents()

        } catch {
            logger.error("Sync cycle error: \(error.localizedDescription)")
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

    private func uploadPendingEvents() async {
        do {
            let pendingEvents = try store.pendingLocalEvents()
            guard !pendingEvents.isEmpty else { return }

            let zoneID = recordZone.zoneID
            var records: [CKRecord] = []

            for event in pendingEvents {
                let recordID = CKRecord.ID(recordName: event.eventId, zoneID: zoneID)
                let record = CKRecord(recordType: "ItemEvent", recordID: recordID)
                record["globalItemId"] = event.globalItemId as CKRecordValue
                record["originDeviceId"] = event.originDeviceId as CKRecordValue
                record["schemaVersion"] = Int64(event.schemaVersion) as CKRecordValue
                record["recordedAt"] = event.recordedAt as CKRecordValue
                record["payloadType"] = event.payloadType as CKRecordValue
                record["payloadData"] = event.payloadData as CKRecordValue
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

            if !uploadedIds.isEmpty {
                try store.markEventsUploaded(eventIds: uploadedIds)
                logger.debug("Uploaded \(uploadedIds.count) events")
            }
        } catch {
            logger.error("Upload error: \(error.localizedDescription)")
        }
    }

    // MARK: - Compaction

    private func runCompactionLoop() async {
        while !Task.isCancelled && isRunning {
            try? await Task.sleep(for: .seconds(Self.compactionInterval))
            await performCompaction()
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

        let query = CKQuery(recordType: "ItemSnapshot", predicate: NSPredicate(value: true))
        let zoneID = recordZone.zoneID

        do {
            let (results, _) = try await database.records(
                matching: query,
                inZoneWith: zoneID,
                resultsLimit: CKQueryOperation.maximumResults
            )
            for (_, result) in results {
                if case let .success(record) = result {
                    snapshots.append(record)
                }
            }
        } catch {
            logger.error("Fetch all snapshots error: \(error.localizedDescription)")
        }

        return snapshots
    }
}
