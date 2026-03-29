#if ENABLE_SYNC

import CloudKit
import ClipKittyRust
import Foundation
import Observation
import os.log

struct SyncZoneChangeResult {
    var events: [CKRecord] = []
    var snapshots: [CKRecord] = []
    var newToken: CKServerChangeToken?
    var tokenExpired = false
    var fetchError: Error?
}

struct SyncRecordSaveResult {
    var savedRecordIDs: [CKRecord.ID] = []
    var perRecordErrors: [CKRecord.ID: Error] = [:]
    var operationError: Error?
}

struct SyncRecordDeleteResult {
    var deletedRecordIDs: [CKRecord.ID] = []
    var perRecordErrors: [CKRecord.ID: Error] = [:]
    var operationError: Error?
}

protocol SyncCloudTransport {
    func accountStatus() async throws -> CKAccountStatus
    func ensureZoneExists(_ zone: CKRecordZone) async throws
    func saveSubscription(_ subscription: CKDatabaseSubscription) async throws
    func fetchZoneChanges(
        in zoneID: CKRecordZone.ID,
        since changeToken: CKServerChangeToken?
    ) async -> SyncZoneChangeResult
    func saveRecords(
        _ records: [CKRecord],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy
    ) async -> SyncRecordSaveResult
    func deleteRecords(_ recordIDs: [CKRecord.ID]) async -> SyncRecordDeleteResult
    func fetchAllRecords(
        ofType recordType: String,
        in zoneID: CKRecordZone.ID
    ) async throws -> [CKRecord]
}

/// Orchestrates iCloud sync via CloudKit using the Rust event-sourced core.
///
/// Architecture:
/// - Single coordinator loop handles all phases serially (no racing tasks)
/// - Token advancement is conditional on batch success
/// - Upload failures degrade status (never claim `.synced` with pending uploads)
/// - Compaction and cleanup run on periodic schedules within the coordinator
/// - Push notifications wake the coordinator via an async signal
@MainActor
@Observable
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

    @ObservationIgnored
    private let logger = Logger(subsystem: "com.clipkitty", category: "SyncEngine")

    // MARK: - Dependencies

    @ObservationIgnored
    private let store: ClipKittyRust.ClipboardStore
    @ObservationIgnored
    private let cloud: any SyncCloudTransport
    @ObservationIgnored
    private let recordZone: CKRecordZone
    @ObservationIgnored
    private let deviceId: String
    @ObservationIgnored
    private let userDefaults: UserDefaults
    @ObservationIgnored
    private let now: () -> Date

    // MARK: - State

    @ObservationIgnored
    private var coordinatorTask: Task<Void, Never>?
    @ObservationIgnored
    private(set) var isRunning = false
    @ObservationIgnored
    private var backoff = SyncBackoff()
    @ObservationIgnored
    private var hasActiveSubscription = false
    @ObservationIgnored
    private var lastCompactionDate: Date?
    @ObservationIgnored
    private var lastCloudCleanupDate: Date?

    /// Wake signal for push notifications to collapse the sleep interval.
    @ObservationIgnored
    private let wakeStream: AsyncStream<Void>
    @ObservationIgnored
    private let wakeContinuation: AsyncStream<Void>.Continuation

    /// Current sync status for UI display.
    private(set) var status: SyncStatus = .idle

    /// Callback invoked after a sync batch changes local content.
    @ObservationIgnored
    var onContentChanged: (() -> Void)?

    // MARK: - Upload Outcome

    /// Structured outcome of uploading pending events to CloudKit.
    private enum UploadOutcome {
        case uploaded(eventIds: [String])
        case nothingToUpload
        case retryableFailure(reason: String)
        case permanentFailure(reason: String)
    }

    /// Structured outcome of uploading snapshots to CloudKit.
    private enum SnapshotUploadOutcome {
        case uploaded(count: Int)
        case nothingToUpload
        case retryableFailure(reason: String)
        case permanentFailure(reason: String)
    }

    // MARK: - Init

    convenience init(store: ClipKittyRust.ClipboardStore) {
        self.init(
            store: store,
            cloud: CloudKitSyncTransport(containerIdentifier: "iCloud.com.clipkitty")
        )
    }

    init(
        store: ClipKittyRust.ClipboardStore,
        cloud: any SyncCloudTransport,
        userDefaults: UserDefaults = .standard,
        deviceId: String? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.cloud = cloud
        self.recordZone = CKRecordZone(zoneName: Self.zoneName)
        self.userDefaults = userDefaults
        self.now = now

        // Use a stable device identifier.
        if let deviceId {
            self.deviceId = deviceId
        } else if let existing = userDefaults.string(forKey: "clipkitty.sync.deviceId") {
            self.deviceId = existing
        } else {
            let newId = UUID().uuidString
            userDefaults.set(newId, forKey: "clipkitty.sync.deviceId")
            self.deviceId = newId
        }

        self.lastCloudCleanupDate = userDefaults.object(
            forKey: "clipkitty.sync.lastCloudCleanup"
        ) as? Date

        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        self.wakeStream = stream
        self.wakeContinuation = continuation
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        logger.info("SyncEngine starting for device \(self.deviceId)")

        // Set the Rust-side device ID so events are attributed correctly.
        store.setSyncDeviceId(deviceId: deviceId)

        coordinatorTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            // Check iCloud availability before starting sync.
            await self.updateStatus(.connecting)
            let status = try? await self.cloud.accountStatus()
            guard status == .available else {
                self.logger.warning("iCloud account not available (status: \(String(describing: status))), sync disabled")
                await self.setUnavailable()
                return
            }

            await self.ensureZoneExists()
            await self.setupSubscription()
            await self.runCoordinatorLoop()
        }
    }

    func stop() {
        isRunning = false
        coordinatorTask?.cancel()
        coordinatorTask = nil
        updateStatus(.idle)
        logger.info("SyncEngine stopped")
    }

    /// Signal the coordinator to wake up immediately (e.g. from push notification).
    func handleRemoteNotification() {
        guard isRunning else { return }
        wakeContinuation.yield(())
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
            try await cloud.ensureZoneExists(recordZone)
            logger.debug("Record zone ensured")
        } catch {
            logger.error("Failed to create record zone: \(error.localizedDescription)")
        }
    }

    // MARK: - Push Subscription

    private func setupSubscription() async {
        if hasActiveSubscription {
            return
        }

        do {
            let subscription = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
            let notificationInfo = CKSubscription.NotificationInfo()
            notificationInfo.shouldSendContentAvailable = true
            subscription.notificationInfo = notificationInfo

            try await cloud.saveSubscription(subscription)
            hasActiveSubscription = true
            logger.info("Push subscription created")
        } catch {
            let nsError = error as NSError
            // "subscription already exists" is fine — treat as success.
            if nsError.domain == CKError.errorDomain,
               nsError.code == CKError.serverRejectedRequest.rawValue
            {
                hasActiveSubscription = true
            } else {
                logger.warning("Push subscription setup failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Coordinator Loop

    private func runCoordinatorLoop() async {
        while !Task.isCancelled && isRunning {
            await runCoordinatorCycle()

            let interval = hasActiveSubscription
                ? Self.subscriptionActiveInterval
                : Self.baseInterval
            let delay = backoff.currentDelay ?? interval

            // Sleep OR wake immediately on push notification — first wins.
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    try? await Task.sleep(for: .seconds(delay))
                }
                group.addTask { [wakeStream] in
                    var iterator = wakeStream.makeAsyncIterator()
                    _ = await iterator.next()
                }
                _ = await group.next()
                group.cancelAll()
            }
        }
    }

    /// Single serial coordinator cycle: fetch → apply → compact → upload → cleanup.
    func runCoordinatorCycle() async {
        updateStatus(.syncing)
        do {
            // ── Phase 0: Check device state ──
            let deviceState = try store.getSyncDeviceState(deviceId: deviceId)

            if deviceState.needsFullResync {
                logger.info("Full resync required")
                try await performFullResync()
                backoff.reset()
                updateStatus(.synced(lastSync: now()))
                return
            }

            if deviceState.indexDirty {
                logger.info("Index dirty, rebuilding")
                try store.rebuildIndex()
                try store.clearIndexDirtyFlag()
            }

            // ── Phase 1: Fetch remote changes ──
            let changeToken = deviceState.zoneChangeToken.flatMap {
                try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
            }
            let changes = await cloud.fetchZoneChanges(in: recordZone.zoneID, since: changeToken)
            if changes.tokenExpired {
                logger.info("Zone change token expired, triggering full resync")
                try await performFullResync()
                backoff.reset()
                updateStatus(.synced(lastSync: now()))
                return
            }
            if let fetchError = changes.fetchError {
                throw fetchError
            }

            // ── Phase 2: Convert CKRecords + rehydrate CKAssets ──
            let (eventRecords, snapshotRecords) = try convertCloudKitRecords(changes)

            // ── Phase 3: Apply batch (Rust) ──
            let batchOutcome = try store.applyRemoteBatch(
                eventRecords: eventRecords,
                snapshotRecords: snapshotRecords
            )

            // ── Phase 4: Token advancement (conditional on success) ──
            switch batchOutcome {
            case .applied(let eventsApplied, let snapshotsApplied):
                if let newToken = changes.newToken {
                    let tokenData = try NSKeyedArchiver.archivedData(
                        withRootObject: newToken,
                        requiringSecureCoding: true
                    )
                    try store.updateZoneChangeToken(deviceId: deviceId, token: tokenData)
                }
                if eventsApplied > 0 || snapshotsApplied > 0 {
                    onContentChanged?()
                }

            case .partialFailure(let appliedCount, _, _):
                // Do NOT advance token — retry on next cycle.
                if appliedCount > 0 {
                    onContentChanged?()
                }
                logger.warning("Partial batch failure, not advancing token")

            case .fullResyncRequired:
                logger.info("Batch triggered full resync")
                try await performFullResync()
                backoff.reset()
                updateStatus(.synced(lastSync: now()))
                return
            }

            // ── Phase 5: Periodic compaction ──
            if shouldRunCompaction() {
                await performCompaction()
                lastCompactionDate = now()
            }

            // ── Phase 6: Upload events ──
            let uploadResult = await uploadPendingEvents()

            // ── Phase 7: Upload checkpoints (snapshots) ──
            let snapshotUploadResult = await uploadSnapshots()

            // ── Phase 8: Periodic cleanup ──
            await performCloudCleanupIfDue()

            // ── Phase 9: Final status ──
            switch combinedUploadOutcome(events: uploadResult, snapshots: snapshotUploadResult) {
            case .uploaded, .nothingToUpload:
                backoff.reset()
                updateStatus(.synced(lastSync: now()))
            case .retryableFailure(let reason):
                let delay = backoff.registerFailure(
                    error: NSError(
                        domain: "SyncEngine", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: reason]
                    )
                )
                logger.warning("Upload retryable: \(reason), backoff \(delay)s")
                updateStatus(.error("Upload failed, retrying"))
            case .permanentFailure(let reason):
                logger.error("Upload permanent failure: \(reason)")
                updateStatus(.error("Upload failed permanently"))
            }

        } catch {
            let delay = backoff.registerFailure(error: error)
            logger.error("Coordinator cycle error: \(error.localizedDescription), backoff \(delay)s")
            updateStatus(.error(error.localizedDescription))
        }
    }

    /// Whether enough time has passed to run compaction.
    private func shouldRunCompaction() -> Bool {
        guard let last = lastCompactionDate else { return true }
        return now().timeIntervalSince(last) >= Self.compactionInterval
    }

    // MARK: - CKRecord Conversion

    /// Convert CKRecords to FFI records, rehydrating CKAssets.
    private func convertCloudKitRecords(
        _ changes: SyncZoneChangeResult
    ) throws -> ([SyncEventRecord], [SyncSnapshotRecord]) {
        let eventRecords: [SyncEventRecord] = try changes.events.map { record in
            return SyncEventRecord(
                eventId: record.recordID.recordName,
                globalItemId: record["globalItemId"] as? String ?? "",
                originDeviceId: record["originDeviceId"] as? String ?? "",
                schemaVersion: UInt32(record["schemaVersion"] as? Int64 ?? 1),
                recordedAt: record["recordedAt"] as? Int64 ?? 0,
                payloadType: record["payloadType"] as? String ?? "",
                payloadData: try rehydratedPayloadData(for: record)
            )
        }

        let snapshotRecords: [SyncSnapshotRecord] = changes.snapshots.map { record in
            SyncSnapshotRecord(
                globalItemId: record.recordID.recordName,
                snapshotRevision: UInt64(record["snapshotRevision"] as? Int64 ?? 0),
                schemaVersion: UInt32(record["schemaVersion"] as? Int64 ?? 1),
                coversThroughEvent: record["coversThroughEvent"] as? String,
                aggregateData: record["aggregateData"] as? String ?? "{}"
            )
        }

        return (eventRecords, snapshotRecords)
    }

    // MARK: - Upload

    /// Upload pending events to CloudKit with structured outcome.
    private func uploadPendingEvents() async -> UploadOutcome {
        do {
            let pendingEvents = try store.pendingLocalEvents()
            guard !pendingEvents.isEmpty else { return .nothingToUpload }

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

            let saveResult = await cloud.saveRecords(records, savePolicy: .ifServerRecordUnchanged)

            // Clean up temp files.
            for url in tempFiles {
                try? FileManager.default.removeItem(at: url)
            }

            var uploadedIds = Set(saveResult.savedRecordIDs.map(\.recordName))
            var errors: [Error] = []
            for (recordID, error) in saveResult.perRecordErrors {
                if Self.isAlreadyUploadedEventError(error) {
                    uploadedIds.insert(recordID.recordName)
                } else {
                    errors.append(error)
                }
            }
            let uploadedEventIds = Array(uploadedIds)

            if !uploadedEventIds.isEmpty {
                try store.markEventsUploaded(eventIds: uploadedEventIds)
                logger.debug("Uploaded \(uploadedEventIds.count) events")
            }

            // Determine outcome based on success/failure counts.
            let missingRecordCount = pendingEvents.count - uploadedEventIds.count - errors.count
            let primaryError = errors.first ?? (missingRecordCount > 0 ? saveResult.operationError : nil)
            if primaryError == nil {
                return .uploaded(eventIds: uploadedEventIds)
            }

            if let primaryError {
                if Self.isPermanentError(primaryError) {
                    return .permanentFailure(reason: primaryError.localizedDescription)
                }
                return .retryableFailure(reason: primaryError.localizedDescription)
            }
            return .retryableFailure(reason: "CloudKit event upload failed")

        } catch {
            if Self.isPermanentError(error) {
                return .permanentFailure(reason: error.localizedDescription)
            }
            return .retryableFailure(reason: error.localizedDescription)
        }
    }

    /// Classify whether a CKError is permanent (non-retryable).
    private static func isPermanentError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .quotaExceeded, .invalidArguments, .assetNotAvailable,
             .managedAccountRestricted, .participantMayNeedVerification:
            return true
        default:
            return false
        }
    }

    /// Event uploads are append-only and keyed by immutable IDs.
    /// If CloudKit already has the record, the desired state is already satisfied.
    private static func isAlreadyUploadedEventError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        return ckError.code == .serverRecordChanged
    }

    /// Event cleanup is idempotent: a missing record is already deleted remotely.
    private static func isAlreadyDeletedRecordError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        return ckError.code == .unknownItem
    }

    private func combinedUploadOutcome(
        events: UploadOutcome,
        snapshots: SnapshotUploadOutcome
    ) -> UploadOutcome {
        switch (events, snapshots) {
        case let (.permanentFailure(reason), _):
            return .permanentFailure(reason: reason)
        case let (_, .permanentFailure(reason)):
            return .permanentFailure(reason: reason)
        case let (.retryableFailure(reason), _):
            return .retryableFailure(reason: reason)
        case let (_, .retryableFailure(reason)):
            return .retryableFailure(reason: reason)
        case (.uploaded(let eventIds), .uploaded(_)), (.uploaded(let eventIds), .nothingToUpload):
            return .uploaded(eventIds: eventIds)
        case (.nothingToUpload, .uploaded(_)):
            return .uploaded(eventIds: [])
        case (.nothingToUpload, .nothingToUpload):
            return .nothingToUpload
        }
    }

    private enum SyncEngineDataError: LocalizedError {
        case missingAssetFileURL(recordID: String)
        case assetReadFailed(recordID: String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case let .missingAssetFileURL(recordID):
                return "CloudKit asset for record \(recordID) did not provide a file URL"
            case let .assetReadFailed(recordID, underlying):
                return "Failed to read CloudKit asset for record \(recordID): \(underlying.localizedDescription)"
            }
        }
    }

    // MARK: - CKAsset Helpers

    private func rehydratedPayloadData(for record: CKRecord) throws -> String {
        let payloadData = record["payloadData"] as? String ?? "{}"
        guard let asset = record["imageAsset"] as? CKAsset else {
            return payloadData
        }
        guard let fileURL = asset.fileURL else {
            throw SyncEngineDataError.missingAssetFileURL(recordID: record.recordID.recordName)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return Self.injectBase64IntoPayload(
                payloadData, key: "data_base64", data: data
            )
        } catch {
            throw SyncEngineDataError.assetReadFailed(
                recordID: record.recordID.recordName,
                underlying: error
            )
        }
    }

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

    /// Upload compacted snapshots to CloudKit and mark them as uploaded.
    private func uploadSnapshots() async -> SnapshotUploadOutcome {
        do {
            let snapshots = try store.pendingSnapshotRecords()
            guard !snapshots.isEmpty else { return .nothingToUpload }

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

            var uploadedCount = 0
            for chunk in records.chunked(into: 400) {
                let saveResult = await cloud.saveRecords(chunk, savePolicy: .changedKeys)
                let savedIds = saveResult.savedRecordIDs.map(\.recordName)
                let errors = Array(saveResult.perRecordErrors.values)

                // Mark each successfully uploaded snapshot.
                for globalItemId in savedIds {
                    try store.markSnapshotUploaded(globalItemId: globalItemId)
                }
                uploadedCount += savedIds.count

                let missingRecordCount = chunk.count - savedIds.count - errors.count
                if let error = errors.first ?? (missingRecordCount > 0 ? saveResult.operationError : nil) {
                    logger.error("Snapshot upload error: \(error.localizedDescription)")
                    if Self.isPermanentError(error) {
                        return .permanentFailure(reason: error.localizedDescription)
                    }
                    return .retryableFailure(reason: error.localizedDescription)
                }
            }

            logger.debug("Uploaded \(uploadedCount) snapshots to CloudKit")
            return .uploaded(count: uploadedCount)
        } catch {
            logger.error("Snapshot upload error: \(error.localizedDescription)")
            if Self.isPermanentError(error) {
                return .permanentFailure(reason: error.localizedDescription)
            }
            return .retryableFailure(reason: error.localizedDescription)
        }
    }

    // MARK: - CloudKit Cleanup

    private func performCloudCleanupIfDue() async {
        // Run at most once per day.
        if let lastCleanup = lastCloudCleanupDate,
           now().timeIntervalSince(lastCleanup) < 86400
        {
            return
        }

        do {
            let eventIds = try store.purgeableCloudEventIds(maxAgeDays: Self.cloudCleanupAgeDays)
            guard !eventIds.isEmpty else {
                lastCloudCleanupDate = now()
                userDefaults.set(lastCloudCleanupDate, forKey: "clipkitty.sync.lastCloudCleanup")
                return
            }

            // Delete from CloudKit.
            let zoneID = recordZone.zoneID
            let recordIDs = eventIds.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }

            // CloudKit batch delete limit is 400; chunk if needed.
            var deletedEventIds: [String] = []
            var encounteredFailure = false
            for chunk in recordIDs.chunked(into: 400) {
                let deleteResult = await cloud.deleteRecords(chunk)
                var deletedIds = Set(deleteResult.deletedRecordIDs.map(\.recordName))
                var errors: [Error] = []
                for (recordID, error) in deleteResult.perRecordErrors {
                    if Self.isAlreadyDeletedRecordError(error) {
                        deletedIds.insert(recordID.recordName)
                    } else {
                        errors.append(error)
                    }
                }
                let deletedRecordNames = Array(deletedIds)

                deletedEventIds.append(contentsOf: deletedRecordNames)
                let missingRecordCount = chunk.count - deletedRecordNames.count - errors.count
                if let error = errors.first ?? (missingRecordCount > 0 ? deleteResult.operationError : nil) {
                    encounteredFailure = true
                    logger.warning("CloudKit cleanup partial failure: \(error.localizedDescription)")
                }
            }

            // Purge locally after successful CloudKit deletion.
            if !deletedEventIds.isEmpty {
                let purged = try store.purgeCloudEvents(eventIds: deletedEventIds)
                logger.info("CloudKit cleanup: deleted \(purged) old compacted events")
            }

            if !encounteredFailure {
                lastCloudCleanupDate = now()
                userDefaults.set(lastCloudCleanupDate, forKey: "clipkitty.sync.lastCloudCleanup")
            }
        } catch {
            logger.error("CloudKit cleanup error: \(error.localizedDescription)")
        }
    }

    // MARK: - Full Resync

    private func performFullResync() async throws {
        logger.info("Starting full resync")
        // 1. Fetch all snapshots (checkpoints) from CloudKit.
        let allSnapshots = try await cloud.fetchAllRecords(
            ofType: "ItemSnapshot",
            in: recordZone.zoneID
        )

        // 2. Fetch all events (tail) from CloudKit.
        let allEvents = try await cloud.fetchAllRecords(
            ofType: "ItemEvent",
            in: recordZone.zoneID
        )

        // 3. Convert to FFI records.
        let snapshotRecords = allSnapshots.map { record in
            SyncSnapshotRecord(
                globalItemId: record.recordID.recordName,
                snapshotRevision: UInt64(record["snapshotRevision"] as? Int64 ?? 0),
                schemaVersion: UInt32(record["schemaVersion"] as? Int64 ?? 1),
                coversThroughEvent: record["coversThroughEvent"] as? String,
                aggregateData: record["aggregateData"] as? String ?? "{}"
            )
        }

        let eventRecords: [SyncEventRecord] = try allEvents.map { record in
            return SyncEventRecord(
                eventId: record.recordID.recordName,
                globalItemId: record["globalItemId"] as? String ?? "",
                originDeviceId: record["originDeviceId"] as? String ?? "",
                schemaVersion: UInt32(record["schemaVersion"] as? Int64 ?? 1),
                recordedAt: record["recordedAt"] as? Int64 ?? 0,
                payloadType: record["payloadType"] as? String ?? "",
                payloadData: try rehydratedPayloadData(for: record)
            )
        }

        // 4. Pass BOTH checkpoints and tail events to Rust.
        let result = try store.fullResyncWithTail(
            snapshotRecords: snapshotRecords,
            tailEventRecords: eventRecords
        )
        logger.info("Full resync: \(result.checkpointsApplied) checkpoints, \(result.tailEventsApplied) tail events applied")

        // 5. Rebuild Tantivy index.
        try store.rebuildIndex()
        try store.clearIndexDirtyFlag()

        // 6. Clear token (start fresh).
        try store.updateZoneChangeToken(deviceId: deviceId, token: nil)

        // 7. Notify UI.
        onContentChanged?()
    }
}

private final class CloudKitSyncTransport: SyncCloudTransport {
    private let logger = Logger(subsystem: "com.clipkitty", category: "SyncEngine")
    private let container: CKContainer
    private let database: CKDatabase

    init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
        database = container.privateCloudDatabase
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    func ensureZoneExists(_ zone: CKRecordZone) async throws {
        _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
    }

    func saveSubscription(_ subscription: CKDatabaseSubscription) async throws {
        _ = try await database.save(subscription)
    }

    func fetchZoneChanges(
        in zoneID: CKRecordZone.ID,
        since changeToken: CKServerChangeToken?
    ) async -> SyncZoneChangeResult {
        var result = SyncZoneChangeResult()

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
                    if result.fetchError == nil {
                        result.fetchError = error
                    }
                    self.logger.warning("Record fetch error: \(error.localizedDescription)")
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
                    } else if result.fetchError == nil {
                        result.fetchError = error
                    }
                    self.logger.warning("Zone fetch error: \(error.localizedDescription)")
                }
            }

            operation.fetchRecordZoneChangesResultBlock = { fetchResult in
                if case let .failure(error) = fetchResult {
                    let nsError = error as NSError
                    if nsError.code == CKError.changeTokenExpired.rawValue {
                        result.tokenExpired = true
                    } else if result.fetchError == nil {
                        result.fetchError = error
                    }
                }
                continuation.resume(returning: result)
            }

            database.add(operation)
        }
    }

    func saveRecords(
        _ records: [CKRecord],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy
    ) async -> SyncRecordSaveResult {
        guard !records.isEmpty else { return SyncRecordSaveResult() }

        let operation = CKModifyRecordsOperation(
            recordsToSave: records,
            recordIDsToDelete: nil
        )
        operation.savePolicy = savePolicy
        operation.isAtomic = false

        return await withCheckedContinuation { continuation in
            var result = SyncRecordSaveResult()

            operation.perRecordSaveBlock = { recordID, saveResult in
                switch saveResult {
                case .success:
                    result.savedRecordIDs.append(recordID)
                case let .failure(error):
                    result.perRecordErrors[recordID] = error
                }
            }

            operation.modifyRecordsResultBlock = { modifyResult in
                if case let .failure(error) = modifyResult {
                    result.operationError = error
                }
                continuation.resume(returning: result)
            }

            self.database.add(operation)
        }
    }

    func deleteRecords(_ recordIDs: [CKRecord.ID]) async -> SyncRecordDeleteResult {
        guard !recordIDs.isEmpty else { return SyncRecordDeleteResult() }

        let operation = CKModifyRecordsOperation(
            recordsToSave: nil,
            recordIDsToDelete: recordIDs
        )
        operation.isAtomic = false

        return await withCheckedContinuation { continuation in
            var result = SyncRecordDeleteResult()

            operation.perRecordDeleteBlock = { recordID, deleteResult in
                switch deleteResult {
                case .success:
                    result.deletedRecordIDs.append(recordID)
                case let .failure(error):
                    result.perRecordErrors[recordID] = error
                }
            }

            operation.modifyRecordsResultBlock = { modifyResult in
                if case let .failure(error) = modifyResult {
                    result.operationError = error
                }
                continuation.resume(returning: result)
            }

            self.database.add(operation)
        }
    }

    func fetchAllRecords(
        ofType recordType: String,
        in zoneID: CKRecordZone.ID
    ) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?

        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        let (results, queryCursor) = try await database.records(
            matching: query,
            inZoneWith: zoneID,
            resultsLimit: CKQueryOperation.maximumResults
        )
        try collectQueryResults(results, into: &records)
        cursor = queryCursor

        while let activeCursor = cursor {
            let (moreResults, nextCursor) = try await database.records(
                continuingMatchFrom: activeCursor,
                resultsLimit: CKQueryOperation.maximumResults
            )
            try collectQueryResults(moreResults, into: &records)
            cursor = nextCursor
        }

        return records
    }

    private func collectQueryResults(
        _ results: [(CKRecord.ID, Result<CKRecord, Error>)],
        into records: inout [CKRecord]
    ) throws {
        for (_, result) in results {
            switch result {
            case let .success(record):
                records.append(record)
            case let .failure(error):
                throw error
            }
        }
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

#endif
