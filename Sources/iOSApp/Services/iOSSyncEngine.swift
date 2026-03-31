#if ENABLE_SYNC

    import BackgroundTasks
    import ClipKittyRust
    import CloudKit
    import Foundation
    import Observation
    import os.log
    import UIKit

    /// iOS-adapted sync engine.
    ///
    /// Same CloudKit sync protocol as the Mac app, adapted for iOS lifecycle:
    /// - Syncs on app foreground (no persistent background loop)
    /// - Registers BGAppRefreshTask for periodic background sync
    /// - Handles remote push notifications to trigger immediate sync
    @MainActor
    @Observable
    final class iOSSyncEngine {
        // MARK: - Configuration

        static let backgroundTaskIdentifier = "com.eviljuliette.clipkitty.ios.sync"
        private static let zoneName = "ClipKittySync"
        private static let subscriptionID = "clipkitty-sync-changes"
        private static let compactionInterval: TimeInterval = 300
        // blobBundleFieldName is now in BlobBundleCodec
        private static let cloudCleanupAgeDays: UInt32 = 30

        @ObservationIgnored
        private let logger = Logger(subsystem: "com.clipkitty.ios", category: "SyncEngine")

        // MARK: - Dependencies

        @ObservationIgnored
        private let store: ClipKittyRust.ClipboardStore
        @ObservationIgnored
        private let cloud: SyncCloudTransport
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
        private var syncTask: Task<Void, Never>?
        @ObservationIgnored
        private var accountChangeObserver: NSObjectProtocol?
        @ObservationIgnored
        private var lastCompactionDate: Date?
        @ObservationIgnored
        private var lastCloudCleanupDate: Date?

        private(set) var activityState: ActivityState = .idle

        /// Callback invoked after a sync batch changes local content.
        @ObservationIgnored
        var onContentChanged: (() -> Void)?

        enum ActivityState: Equatable {
            case idle
            case syncing
            case synced(lastSync: Date)
            case error(String)
            case unavailable
        }

        // MARK: - Status

        enum SyncStatus: Equatable {
            case idle
            case syncing
            case synced(lastSync: Date)
            case error(String)
            case unavailable
        }

        var status: SyncStatus {
            switch activityState {
            case .idle: return .idle
            case .syncing: return .syncing
            case let .synced(date): return .synced(lastSync: date)
            case let .error(msg): return .error(msg)
            case .unavailable: return .unavailable
            }
        }

        // MARK: - Init

        convenience init(store: ClipKittyRust.ClipboardStore) {
            self.init(
                store: store,
                cloud: CloudKitTransport(
                    containerIdentifier: "iCloud.com.eviljuliette.clipkitty"
                )
            )
        }

        init(
            store: ClipKittyRust.ClipboardStore,
            cloud: SyncCloudTransport,
            userDefaults: UserDefaults = .standard,
            deviceId: String? = nil,
            now: @escaping () -> Date = Date.init
        ) {
            self.store = store
            self.cloud = cloud
            recordZone = CKRecordZone(zoneName: Self.zoneName)
            self.userDefaults = userDefaults
            self.now = now

            if let deviceId {
                self.deviceId = deviceId
            } else if let existing = userDefaults.string(forKey: "clipkitty.sync.deviceId") {
                self.deviceId = existing
            } else {
                let newId = UUID().uuidString
                userDefaults.set(newId, forKey: "clipkitty.sync.deviceId")
                self.deviceId = newId
            }

            lastCloudCleanupDate = userDefaults.object(
                forKey: "clipkitty.sync.lastCloudCleanup"
            ) as? Date

            registerBackgroundTask()
        }

        // MARK: - Lifecycle

        func start() {
            store.setSyncDeviceId(deviceId: deviceId)
            performSync()
        }

        func stop() {
            syncTask?.cancel()
            syncTask = nil
            removeAccountChangeObserver()
            activityState = .idle
        }

        func handleBecameActive() {
            performSync()
        }

        func handleRemoteNotification() {
            performSync()
        }

        // MARK: - Background Refresh

        func scheduleBackgroundRefresh() {
            let request = BGAppRefreshTaskRequest(
                identifier: Self.backgroundTaskIdentifier
            )
            request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            do {
                try BGTaskScheduler.shared.submit(request)
                logger.debug("Scheduled background sync refresh")
            } catch {
                logger.warning(
                    "Failed to schedule background refresh: \(error.localizedDescription)"
                )
            }
        }

        private func registerBackgroundTask() {
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: Self.backgroundTaskIdentifier,
                using: nil
            ) { [weak self] task in
                guard let task = task as? BGAppRefreshTask else { return }
                Task { @MainActor in
                    self?.handleBackgroundTask(task)
                }
            }
        }

        private func handleBackgroundTask(_ task: BGAppRefreshTask) {
            scheduleBackgroundRefresh()

            let syncTask = Task {
                await runSyncCycle()
            }
            self.syncTask = syncTask

            task.expirationHandler = {
                syncTask.cancel()
            }

            Task {
                _ = await syncTask.value
                task.setTaskCompleted(success: true)
            }
        }

        // MARK: - Sync Execution

        private func performSync() {
            guard syncTask == nil || syncTask!.isCancelled else { return }
            syncTask = Task {
                await runSyncCycle()
                syncTask = nil
            }
        }

        private func runSyncCycle() async {
            do {
                let accountStatus = try await cloud.accountStatus()
                switch accountStatus {
                case .available:
                    break
                case .noAccount, .restricted:
                    activityState = .unavailable
                    return
                case .couldNotDetermine, .temporarilyUnavailable:
                    activityState = .error("iCloud temporarily unavailable")
                    return
                @unknown default:
                    activityState = .error("Unknown iCloud status")
                    return
                }

                activityState = .syncing
                registerAccountChangeObserverIfNeeded()

                // Ensure zone exists
                try await cloud.ensureZoneExists(recordZone)

                // Setup push subscription
                await setupSubscription()

                // Check device state
                let deviceState = try store.getSyncDeviceState(deviceId: deviceId)

                if deviceState.needsFullResync {
                    logger.info("Full resync required")
                    try await performFullResync()
                    activityState = .synced(lastSync: now())
                    return
                }

                if deviceState.indexDirty {
                    try store.rebuildIndex()
                    try store.clearIndexDirtyFlag()
                }

                // Fetch remote changes
                let changeToken = deviceState.zoneChangeToken.flatMap {
                    try? NSKeyedUnarchiver.unarchivedObject(
                        ofClass: CKServerChangeToken.self,
                        from: $0
                    )
                }
                let changes = await cloud.fetchZoneChanges(
                    in: recordZone.zoneID,
                    since: changeToken
                )

                if changes.tokenExpired {
                    try await performFullResync()
                    activityState = .synced(lastSync: now())
                    return
                }
                if let fetchError = changes.fetchError {
                    throw fetchError
                }

                // Convert + apply
                let (eventRecords, snapshotRecords) = try BlobBundleCodec.convertCloudKitRecords(changes)
                let batchOutcome = try store.applyRemoteBatch(
                    eventRecords: eventRecords,
                    snapshotRecords: snapshotRecords
                )

                switch batchOutcome {
                case let .applied(eventsApplied, snapshotsApplied):
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

                case let .partialFailure(appliedCount, _, _):
                    if appliedCount > 0 {
                        onContentChanged?()
                    }

                case .fullResyncRequired:
                    try await performFullResync()
                    activityState = .synced(lastSync: now())
                    return
                }

                // Compaction
                if shouldRunCompaction() {
                    try? store.runCompaction()
                    lastCompactionDate = now()
                }

                // Upload pending events (iOS creates events for tag/delete operations)
                await uploadPendingEvents()
                await uploadSnapshots()

                // Periodic cleanup
                await performCloudCleanupIfDue()

                activityState = .synced(lastSync: now())

            } catch {
                logger.error("Sync cycle error: \(error.localizedDescription)")
                activityState = .error(error.localizedDescription)
            }
        }

        // MARK: - Push Subscription

        private func setupSubscription() async {
            do {
                let subscription = CKDatabaseSubscription(
                    subscriptionID: Self.subscriptionID
                )
                let notificationInfo = CKSubscription.NotificationInfo()
                notificationInfo.shouldSendContentAvailable = true
                subscription.notificationInfo = notificationInfo
                try await cloud.saveSubscription(subscription)
            } catch {
                logger.warning(
                    "Push subscription setup failed: \(error.localizedDescription)"
                )
            }
        }

        // MARK: - Compaction

        private func shouldRunCompaction() -> Bool {
            guard let last = lastCompactionDate else { return true }
            return now().timeIntervalSince(last) >= Self.compactionInterval
        }

        // MARK: - Upload

        private func uploadPendingEvents() async {
            do {
                let pendingEvents = try store.pendingLocalEvents()
                guard !pendingEvents.isEmpty else { return }

                let zoneID = recordZone.zoneID
                var records: [CKRecord] = []
                var tempFiles: [URL] = []
                defer { BlobBundleCodec.cleanupTemporaryFiles(tempFiles) }

                for event in pendingEvents {
                    let recordID = CKRecord.ID(
                        recordName: event.eventId,
                        zoneID: zoneID
                    )
                    let record = CKRecord(recordType: "ItemEvent", recordID: recordID)
                    record["itemId"] = event.itemId as CKRecordValue
                    record["originDeviceId"] = event.originDeviceId as CKRecordValue
                    record["schemaVersion"] = Int64(event.schemaVersion) as CKRecordValue
                    record["recordedAt"] = event.recordedAt as CKRecordValue
                    record["payloadType"] = event.payloadType as CKRecordValue

                    if let tempURL = try BlobBundleCodec.configureJSONField(
                        event.payloadData,
                        on: record,
                        field: .payloadData
                    ) {
                        tempFiles.append(tempURL)
                    }
                    records.append(record)
                }

                let saveResult = await cloud.saveRecords(
                    records,
                    savePolicy: .ifServerRecordUnchanged
                )

                var uploadedIds = Set(saveResult.savedRecordIDs.map(\.recordName))
                for (recordID, error) in saveResult.perRecordErrors {
                    if let ckError = error as? CKError,
                       ckError.code == .serverRecordChanged
                    {
                        uploadedIds.insert(recordID.recordName)
                    }
                }

                if !uploadedIds.isEmpty {
                    try store.markEventsUploaded(eventIds: Array(uploadedIds))
                }
            } catch {
                logger.error("Event upload error: \(error.localizedDescription)")
            }
        }

        private func uploadSnapshots() async {
            do {
                let snapshots = try store.pendingSnapshotRecords()
                guard !snapshots.isEmpty else { return }

                let zoneID = recordZone.zoneID
                var tempFiles: [URL] = []
                defer { BlobBundleCodec.cleanupTemporaryFiles(tempFiles) }

                let records: [CKRecord] = try snapshots.map { snapshot in
                    let recordID = CKRecord.ID(
                        recordName: snapshot.itemId,
                        zoneID: zoneID
                    )
                    let record = CKRecord(
                        recordType: "ItemSnapshot",
                        recordID: recordID
                    )
                    record["snapshotRevision"] = Int64(
                        snapshot.snapshotRevision
                    ) as CKRecordValue
                    record["schemaVersion"] = Int64(
                        snapshot.schemaVersion
                    ) as CKRecordValue
                    record["coversThroughEvent"] =
                        snapshot.coversThroughEvent as CKRecordValue?
                    if let tempURL = try BlobBundleCodec.configureJSONField(
                        snapshot.aggregateData,
                        on: record,
                        field: .aggregateData
                    ) {
                        tempFiles.append(tempURL)
                    }
                    return record
                }

                for chunk in records.chunked(into: 400) {
                    let saveResult = await cloud.saveRecords(
                        chunk,
                        savePolicy: .changedKeys
                    )
                    let savedIds = saveResult.savedRecordIDs.map(\.recordName)
                    for itemId in savedIds {
                        try store.markSnapshotUploaded(itemId: itemId)
                    }
                }
            } catch {
                logger.error("Snapshot upload error: \(error.localizedDescription)")
            }
        }

        // MARK: - Cloud Cleanup

        private func performCloudCleanupIfDue() async {
            if let lastCleanup = lastCloudCleanupDate,
               now().timeIntervalSince(lastCleanup) < 86400
            {
                return
            }

            do {
                let eventIds = try store.purgeableCloudEventIds(
                    maxAgeDays: Self.cloudCleanupAgeDays
                )
                guard !eventIds.isEmpty else {
                    lastCloudCleanupDate = now()
                    userDefaults.set(
                        lastCloudCleanupDate,
                        forKey: "clipkitty.sync.lastCloudCleanup"
                    )
                    return
                }

                let zoneID = recordZone.zoneID
                let recordIDs = eventIds.map {
                    CKRecord.ID(recordName: $0, zoneID: zoneID)
                }

                var deletedEventIds: [String] = []
                for chunk in recordIDs.chunked(into: 400) {
                    let deleteResult = await cloud.deleteRecords(chunk)
                    var deletedIds = Set(
                        deleteResult.deletedRecordIDs.map(\.recordName)
                    )
                    for (recordID, error) in deleteResult.perRecordErrors {
                        if let ckError = error as? CKError,
                           ckError.code == .unknownItem
                        {
                            deletedIds.insert(recordID.recordName)
                        }
                    }
                    deletedEventIds.append(contentsOf: deletedIds)
                }

                if !deletedEventIds.isEmpty {
                    _ = try store.purgeCloudEvents(eventIds: deletedEventIds)
                }

                lastCloudCleanupDate = now()
                userDefaults.set(
                    lastCloudCleanupDate,
                    forKey: "clipkitty.sync.lastCloudCleanup"
                )
            } catch {
                logger.error(
                    "Cloud cleanup error: \(error.localizedDescription)"
                )
            }
        }

        // MARK: - Full Resync

        private func performFullResync() async throws {
            let allSnapshots = try await cloud.fetchAllRecords(
                ofType: "ItemSnapshot",
                in: recordZone.zoneID
            )
            let allEvents = try await cloud.fetchAllRecords(
                ofType: "ItemEvent",
                in: recordZone.zoneID
            )

            let snapshotRecords = try allSnapshots.map { record in
                try SyncSnapshotRecord(
                    itemId: record.recordID.recordName,
                    snapshotRevision: UInt64(
                        record["snapshotRevision"] as? Int64 ?? 0
                    ),
                    schemaVersion: UInt32(
                        record["schemaVersion"] as? Int64 ?? 1
                    ),
                    coversThroughEvent: record["coversThroughEvent"] as? String,
                    aggregateData: BlobBundleCodec.rehydratedJSONString(
                        for: record,
                        field: .aggregateData
                    )
                )
            }

            let eventRecords: [SyncEventRecord] = try allEvents.map { record in
                try SyncEventRecord(
                    eventId: record.recordID.recordName,
                    itemId: record["itemId"] as? String ?? "",
                    originDeviceId: record["originDeviceId"] as? String ?? "",
                    schemaVersion: UInt32(
                        record["schemaVersion"] as? Int64 ?? 1
                    ),
                    recordedAt: record["recordedAt"] as? Int64 ?? 0,
                    payloadType: record["payloadType"] as? String ?? "",
                    payloadData: BlobBundleCodec.rehydratedJSONString(
                        for: record,
                        field: .payloadData
                    )
                )
            }

            _ = try store.fullResyncWithTail(
                snapshotRecords: snapshotRecords,
                tailEventRecords: eventRecords
            )

            try store.rebuildIndex()
            try store.clearIndexDirtyFlag()
            try store.updateZoneChangeToken(deviceId: deviceId, token: nil)
            onContentChanged?()
        }

        // MARK: - Account Change Observer

        private func registerAccountChangeObserverIfNeeded() {
            guard accountChangeObserver == nil else { return }
            accountChangeObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name.CKAccountChanged,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.performSync()
                }
            }
        }

        private func removeAccountChangeObserver() {
            guard let observer = accountChangeObserver else { return }
            NotificationCenter.default.removeObserver(observer)
            accountChangeObserver = nil
        }
    }

    // CloudKitTransport is now in Sources/Shared/CloudKitTransport.swift

#endif
