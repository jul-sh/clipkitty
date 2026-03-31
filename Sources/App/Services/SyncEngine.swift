#if ENABLE_SYNC

    import ClipKittyRust
    import CloudKit
    import Foundation
    import Observation
    import os.log

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
        // blobBundleFieldName is now in BlobBundleCodec
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
        private let notificationCenter: NotificationCenter
        @ObservationIgnored
        private let now: () -> Date

        // MARK: - State

        @ObservationIgnored
        private var coordinatorTask: Task<Void, Never>?
        @ObservationIgnored
        private var accountChangeObserver: NSObjectProtocol?
        @ObservationIgnored
        private var backoff = SyncBackoff()
        private var engineState: EngineState

        /// Wake signal for push notifications to collapse the sleep interval.
        @ObservationIgnored
        private let wakeStream: AsyncStream<Void>
        @ObservationIgnored
        private let wakeContinuation: AsyncStream<Void>.Continuation

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

        private enum EngineState {
            case idle(MaintenanceState)
            case active(ActiveState)
            case unavailable(MaintenanceState)
        }

        private struct ActiveState {
            var bootstrap: BootstrapState
            var activity: ActivityState
            var maintenance: MaintenanceState
        }

        private enum BootstrapState: Equatable {
            case needsZone
            case needsSubscription
            case ready
        }

        private enum ActivityState: Equatable {
            case connecting
            case syncing
            case synced(lastSync: Date)
            case error(String)
            case temporarilyUnavailable
        }

        private struct MaintenanceState {
            var lastCompactionDate: Date?
            var lastCloudCleanupDate: Date?
        }

        // MARK: - Init

        convenience init(store: ClipKittyRust.ClipboardStore) {
            self.init(
                store: store,
                cloud: CloudKitTransport(containerIdentifier: "iCloud.com.eviljuliette.clipkitty")
            )
        }

        init(
            store: ClipKittyRust.ClipboardStore,
            cloud: any SyncCloudTransport,
            userDefaults: UserDefaults = .standard,
            deviceId: String? = nil,
            notificationCenter: NotificationCenter = .default,
            now: @escaping () -> Date = Date.init
        ) {
            self.store = store
            self.cloud = cloud
            recordZone = CKRecordZone(zoneName: Self.zoneName)
            self.userDefaults = userDefaults
            self.notificationCenter = notificationCenter
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

            let lastCloudCleanupDate = userDefaults.object(
                forKey: "clipkitty.sync.lastCloudCleanup"
            ) as? Date
            engineState = .idle(
                MaintenanceState(
                    lastCompactionDate: nil,
                    lastCloudCleanupDate: lastCloudCleanupDate
                )
            )

            let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
            wakeStream = stream
            wakeContinuation = continuation
        }

        // MARK: - Lifecycle

        func start() {
            guard coordinatorTask == nil else { return }
            engineState = .active(
                ActiveState(
                    bootstrap: .needsZone,
                    activity: .connecting,
                    maintenance: maintenanceState()
                )
            )
            registerAccountChangeObserverIfNeeded()
            let deviceId = self.deviceId
            logger.info("SyncEngine starting for device \(deviceId)")

            // Set the Rust-side device ID so events are attributed correctly.
            store.setSyncDeviceId(deviceId: deviceId)

            coordinatorTask = Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.runCoordinatorLoop()
            }
        }

        func stop() {
            coordinatorTask?.cancel()
            coordinatorTask = nil
            removeAccountChangeObserver()
            engineState = .idle(maintenanceState())
            logger.info("SyncEngine stopped")
        }

        /// Signal the coordinator to wake up immediately (e.g. from push notification).
        func handleRemoteNotification() {
            guard coordinatorTask != nil else { return }
            wakeContinuation.yield(())
        }

        // MARK: - Status

        enum SyncStatus: Equatable {
            case idle
            case connecting
            case syncing
            case synced(lastSync: Date)
            case error(String)
            case temporarilyUnavailable
            case unavailable
        }

        var status: SyncStatus {
            switch engineState {
            case .idle:
                return .idle
            case .unavailable:
                return .unavailable
            case let .active(state):
                switch state.activity {
                case .connecting:
                    return .connecting
                case .syncing:
                    return .syncing
                case let .synced(lastSync):
                    return .synced(lastSync: lastSync)
                case let .error(message):
                    return .error(message)
                case .temporarilyUnavailable:
                    return .temporarilyUnavailable
                }
            }
        }

        /// Marks the engine as unavailable and stops it. Callable from detached tasks.
        private func setUnavailable() {
            coordinatorTask?.cancel()
            coordinatorTask = nil
            engineState = .unavailable(maintenanceState())
        }

        private func maintenanceState() -> MaintenanceState {
            switch engineState {
            case let .idle(maintenance), let .unavailable(maintenance):
                return maintenance
            case let .active(state):
                return state.maintenance
            }
        }

        private func updateMaintenanceState(_ mutate: (inout MaintenanceState) -> Void) {
            switch engineState {
            case var .idle(maintenance):
                mutate(&maintenance)
                engineState = .idle(maintenance)
            case var .unavailable(maintenance):
                mutate(&maintenance)
                engineState = .unavailable(maintenance)
            case var .active(state):
                mutate(&state.maintenance)
                engineState = .active(state)
            }
        }

        private func updateActiveState(_ mutate: (inout ActiveState) -> Void) {
            switch engineState {
            case var .active(state):
                mutate(&state)
                engineState = .active(state)
            case let .idle(maintenance), let .unavailable(maintenance):
                var state = ActiveState(
                    bootstrap: .needsZone,
                    activity: .connecting,
                    maintenance: maintenance
                )
                mutate(&state)
                engineState = .active(state)
            }
        }

        private func prepareForAvailableCycle() {
            switch engineState {
            case let .idle(maintenance), let .unavailable(maintenance):
                engineState = .active(
                    ActiveState(
                        bootstrap: .needsZone,
                        activity: .connecting,
                        maintenance: maintenance
                    )
                )
            case var .active(state):
                switch (state.bootstrap, state.activity) {
                case (.needsZone, _), (.needsSubscription, _), (.ready, .connecting),
                     (.ready, .temporarilyUnavailable):
                    state.activity = .connecting
                    engineState = .active(state)
                case (.ready, .syncing), (.ready, .synced(_)), (.ready, .error(_)):
                    break
                }
            }
        }

        // MARK: - Zone Setup

        private func ensureZoneExists() async throws {
            guard case let .active(state) = engineState,
                  case .needsZone = state.bootstrap
            else {
                return
            }

            try await cloud.ensureZoneExists(recordZone)
            updateActiveState { state in
                state.bootstrap = .needsSubscription
            }
            logger.debug("Record zone ensured")
        }

        // MARK: - Push Subscription

        private func setupSubscription() async {
            guard case let .active(state) = engineState,
                  case .needsSubscription = state.bootstrap
            else {
                return
            }

            do {
                let subscription = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
                let notificationInfo = CKSubscription.NotificationInfo()
                notificationInfo.shouldSendContentAvailable = true
                subscription.notificationInfo = notificationInfo

                try await cloud.saveSubscription(subscription)
                updateActiveState { state in
                    state.bootstrap = .ready
                }
                logger.info("Push subscription created")
            } catch {
                logger.warning("Push subscription setup failed: \(error.localizedDescription)")
            }
        }

        // MARK: - Coordinator Loop

        private func runCoordinatorLoop() async {
            while !Task.isCancelled {
                await runCoordinatorCycle()
                guard !Task.isCancelled else {
                    break
                }

                let interval: TimeInterval
                switch engineState {
                case let .active(state):
                    switch state.bootstrap {
                    case .ready:
                        interval = Self.subscriptionActiveInterval
                    case .needsZone, .needsSubscription:
                        interval = Self.baseInterval
                    }
                case .idle, .unavailable:
                    return
                }
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
            do {
                switch try await accountAvailability() {
                case .available:
                    break
                case .temporarilyUnavailable:
                    let delay = backoff.registerFailure(error: CKError(.serviceUnavailable))
                    logger.warning("iCloud account temporarily unavailable, backoff \(delay)s")
                    updateActiveState { state in
                        state.activity = .temporarilyUnavailable
                    }
                    return
                case .unavailable:
                    logger.warning("iCloud account unavailable, sync disabled")
                    setUnavailable()
                    return
                }

                prepareForAvailableCycle()
                try await ensureZoneExists()
                await setupSubscription()
                updateActiveState { state in
                    state.activity = .syncing
                }

                // ── Phase 0: Check device state ──
                let deviceState = try store.getSyncDeviceState(deviceId: deviceId)

                if deviceState.needsFullResync {
                    logger.info("Full resync required")
                    try await performFullResync()
                    backoff.reset()
                    updateActiveState { state in
                        state.activity = .synced(lastSync: now())
                    }
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
                    updateActiveState { state in
                        state.activity = .synced(lastSync: now())
                    }
                    return
                }
                if let fetchError = changes.fetchError {
                    throw fetchError
                }

                // ── Phase 2: Convert CKRecords + rehydrate CKAssets ──
                let (eventRecords, snapshotRecords) = try BlobBundleCodec.convertCloudKitRecords(changes)

                // ── Phase 3: Apply batch (Rust) ──
                let batchOutcome = try store.applyRemoteBatch(
                    eventRecords: eventRecords,
                    snapshotRecords: snapshotRecords
                )

                // ── Phase 4: Token advancement (conditional on success) ──
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
                    // Do NOT advance token — retry on next cycle.
                    if appliedCount > 0 {
                        onContentChanged?()
                    }
                    logger.warning("Partial batch failure, not advancing token")

                case .fullResyncRequired:
                    logger.info("Batch triggered full resync")
                    try await performFullResync()
                    backoff.reset()
                    updateActiveState { state in
                        state.activity = .synced(lastSync: now())
                    }
                    return
                }

                // ── Phase 5: Periodic compaction ──
                if shouldRunCompaction() {
                    await performCompaction()
                    updateMaintenanceState { maintenance in
                        maintenance.lastCompactionDate = now()
                    }
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
                    updateActiveState { state in
                        state.activity = .synced(lastSync: now())
                    }
                case let .retryableFailure(reason):
                    let delay = backoff.registerFailure(
                        error: NSError(
                            domain: "SyncEngine", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: reason]
                        )
                    )
                    logger.warning("Upload retryable: \(reason), backoff \(delay)s")
                    updateActiveState { state in
                        state.activity = .error("Upload failed, retrying")
                    }
                case let .permanentFailure(reason):
                    logger.error("Upload permanent failure: \(reason)")
                    updateActiveState { state in
                        state.activity = .error("Upload failed permanently")
                    }
                }

            } catch {
                let delay = backoff.registerFailure(error: error)
                logger.error("Coordinator cycle error: \(error.localizedDescription), backoff \(delay)s")
                updateActiveState { state in
                    state.activity = .error(error.localizedDescription)
                }
            }
        }

        /// Whether enough time has passed to run compaction.
        private func shouldRunCompaction() -> Bool {
            guard let last = maintenanceState().lastCompactionDate else { return true }
            return now().timeIntervalSince(last) >= Self.compactionInterval
        }

        private enum AccountAvailability {
            case available
            case temporarilyUnavailable
            case unavailable
        }

        private func accountAvailability() async throws -> AccountAvailability {
            let status = try await cloud.accountStatus()
            switch status {
            case .available:
                return .available
            case .noAccount, .restricted:
                return .unavailable
            case .couldNotDetermine, .temporarilyUnavailable:
                return .temporarilyUnavailable
            @unknown default:
                throw NSError(
                    domain: "SyncEngine",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Unknown iCloud account status"]
                )
            }
        }

        private func registerAccountChangeObserverIfNeeded() {
            guard accountChangeObserver == nil else { return }
            accountChangeObserver = notificationCenter.addObserver(
                forName: Notification.Name.CKAccountChanged,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.handleAccountChanged()
                }
            }
        }

        private func removeAccountChangeObserver() {
            guard let accountChangeObserver else { return }
            notificationCenter.removeObserver(accountChangeObserver)
            self.accountChangeObserver = nil
        }

        private func handleAccountChanged() {
            if coordinatorTask != nil {
                logger.info("iCloud account changed, waking sync coordinator")
                wakeContinuation.yield(())
                return
            }

            guard case .unavailable = engineState else { return }
            logger.info("iCloud account changed, restarting sync coordinator")
            start()
        }

        // CKRecord conversion is now in BlobBundleCodec.convertCloudKitRecords()

        // MARK: - Upload

        /// Upload pending events to CloudKit with structured outcome.
        private func uploadPendingEvents() async -> UploadOutcome {
            do {
                let pendingEvents = try store.pendingLocalEvents()
                guard !pendingEvents.isEmpty else { return .nothingToUpload }

                let zoneID = recordZone.zoneID
                var records: [CKRecord] = []
                var tempFiles: [URL] = []
                defer { BlobBundleCodec.cleanupTemporaryFiles(tempFiles) }

                for event in pendingEvents {
                    let recordID = CKRecord.ID(recordName: event.eventId, zoneID: zoneID)
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

                let saveResult = await cloud.saveRecords(records, savePolicy: .ifServerRecordUnchanged)

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
            case let (.uploaded(eventIds), .uploaded(_)), let (.uploaded(eventIds), .nothingToUpload):
                return .uploaded(eventIds: eventIds)
            case (.nothingToUpload, .uploaded(_)):
                return .uploaded(eventIds: [])
            case (.nothingToUpload, .nothingToUpload):
                return .nothingToUpload
            }
        }

        // configureJSONField and rehydratedJSONString are now in BlobBundleCodec
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
                var tempFiles: [URL] = []
                defer { BlobBundleCodec.cleanupTemporaryFiles(tempFiles) }
                let records: [CKRecord] = try snapshots.map { snapshot in
                    let recordID = CKRecord.ID(recordName: snapshot.itemId, zoneID: zoneID)
                    let record = CKRecord(recordType: "ItemSnapshot", recordID: recordID)
                    record["snapshotRevision"] = Int64(snapshot.snapshotRevision) as CKRecordValue
                    record["schemaVersion"] = Int64(snapshot.schemaVersion) as CKRecordValue
                    record["coversThroughEvent"] = snapshot.coversThroughEvent as CKRecordValue?
                    if let tempURL = try BlobBundleCodec.configureJSONField(
                        snapshot.aggregateData,
                        on: record,
                        field: .aggregateData
                    ) {
                        tempFiles.append(tempURL)
                    }
                    return record
                }

                var uploadedCount = 0
                for chunk in records.chunked(into: 400) {
                    let saveResult = await cloud.saveRecords(chunk, savePolicy: .changedKeys)
                    let savedIds = saveResult.savedRecordIDs.map(\.recordName)
                    let errors = Array(saveResult.perRecordErrors.values)

                    // Mark each successfully uploaded snapshot.
                    for itemId in savedIds {
                        try store.markSnapshotUploaded(itemId: itemId)
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
            if let lastCleanup = maintenanceState().lastCloudCleanupDate,
               now().timeIntervalSince(lastCleanup) < 86400
            {
                return
            }

            do {
                let eventIds = try store.purgeableCloudEventIds(maxAgeDays: Self.cloudCleanupAgeDays)
                guard !eventIds.isEmpty else {
                    let cleanupDate = now()
                    updateMaintenanceState { maintenance in
                        maintenance.lastCloudCleanupDate = cleanupDate
                    }
                    userDefaults.set(cleanupDate, forKey: "clipkitty.sync.lastCloudCleanup")
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
                    let cleanupDate = now()
                    updateMaintenanceState { maintenance in
                        maintenance.lastCloudCleanupDate = cleanupDate
                    }
                    userDefaults.set(cleanupDate, forKey: "clipkitty.sync.lastCloudCleanup")
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
            let snapshotRecords = try allSnapshots.map { record in
                try SyncSnapshotRecord(
                    itemId: record.recordID.recordName,
                    snapshotRevision: UInt64(record["snapshotRevision"] as? Int64 ?? 0),
                    schemaVersion: UInt32(record["schemaVersion"] as? Int64 ?? 1),
                    coversThroughEvent: record["coversThroughEvent"] as? String,
                    aggregateData: BlobBundleCodec.rehydratedJSONString(for: record, field: .aggregateData)
                )
            }

            let eventRecords: [SyncEventRecord] = try allEvents.map { record in
                try SyncEventRecord(
                    eventId: record.recordID.recordName,
                    itemId: record["itemId"] as? String ?? "",
                    originDeviceId: record["originDeviceId"] as? String ?? "",
                    schemaVersion: UInt32(record["schemaVersion"] as? Int64 ?? 1),
                    recordedAt: record["recordedAt"] as? Int64 ?? 0,
                    payloadType: record["payloadType"] as? String ?? "",
                    payloadData: BlobBundleCodec.rehydratedJSONString(for: record, field: .payloadData)
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

    // CloudKitTransport is now in Sources/Shared/CloudKitTransport.swift

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

#endif
