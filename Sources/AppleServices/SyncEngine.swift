#if ENABLE_SYNC

    import ClipKittyRust
    import CloudKit
    import Foundation
    import Observation
    import os.log

    public struct SyncZoneChangeResult {
        public var events: [CKRecord]
        public var snapshots: [CKRecord]
        public var newToken: CKServerChangeToken?
        public var tokenExpired: Bool
        public var fetchError: Error?

        public init(
            events: [CKRecord] = [],
            snapshots: [CKRecord] = [],
            newToken: CKServerChangeToken? = nil,
            tokenExpired: Bool = false,
            fetchError: Error? = nil
        ) {
            self.events = events
            self.snapshots = snapshots
            self.newToken = newToken
            self.tokenExpired = tokenExpired
            self.fetchError = fetchError
        }
    }

    public struct SyncRecordSaveResult {
        public var savedRecordIDs: [CKRecord.ID]
        public var perRecordErrors: [CKRecord.ID: Error]
        public var operationError: Error?

        public init(
            savedRecordIDs: [CKRecord.ID] = [],
            perRecordErrors: [CKRecord.ID: Error] = [:],
            operationError: Error? = nil
        ) {
            self.savedRecordIDs = savedRecordIDs
            self.perRecordErrors = perRecordErrors
            self.operationError = operationError
        }
    }

    public struct SyncRecordDeleteResult {
        public var deletedRecordIDs: [CKRecord.ID]
        public var perRecordErrors: [CKRecord.ID: Error]
        public var operationError: Error?

        public init(
            deletedRecordIDs: [CKRecord.ID] = [],
            perRecordErrors: [CKRecord.ID: Error] = [:],
            operationError: Error? = nil
        ) {
            self.deletedRecordIDs = deletedRecordIDs
            self.perRecordErrors = perRecordErrors
            self.operationError = operationError
        }
    }

    public protocol SyncCloudTransport {
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
    public final class SyncEngine {
        // MARK: - Configuration

        private static let zoneName = "ClipKittySync"
        private static let subscriptionID = "clipkitty-sync-changes"
        private static let compactionInterval: TimeInterval = 300 // 5 minutes
        private static let baseInterval: TimeInterval = 30
        private static let subscriptionActiveInterval: TimeInterval = 60
        private static let blobBundleFieldName = "blobBundleAsset"
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
        public var onContentChanged: (() -> Void)?

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

        public convenience init(store: ClipKittyRust.ClipboardStore) {
            self.init(
                store: store,
                cloud: CloudKitSyncTransport(containerIdentifier: "iCloud.com.eviljuliette.clipkitty")
            )
        }

        public init(
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

        public func start() {
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

        public func stop() {
            coordinatorTask?.cancel()
            coordinatorTask = nil
            removeAccountChangeObserver()
            engineState = .idle(maintenanceState())
            logger.info("SyncEngine stopped")
        }

        /// Signal the coordinator to wake up immediately (e.g. from push notification).
        public func handleRemoteNotification() {
            guard coordinatorTask != nil else { return }
            wakeContinuation.yield(())
        }

        // MARK: - Status

        public enum SyncStatus: Equatable {
            case idle
            case connecting
            case syncing
            case synced(lastSync: Date)
            case error(String)
            case temporarilyUnavailable
            case unavailable
        }

        public var status: SyncStatus {
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
        public func runCoordinatorCycle() async {
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
                let (eventRecords, snapshotRecords) = try convertCloudKitRecords(changes)

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

        // MARK: - CKRecord Conversion

        /// Convert CKRecords to FFI records, rehydrating CKAssets.
        private func convertCloudKitRecords(
            _ changes: SyncZoneChangeResult
        ) throws -> ([SyncEventRecord], [SyncSnapshotRecord]) {
            let eventRecords: [SyncEventRecord] = try changes.events.map { record in
                try SyncEventRecord(
                    eventId: record.recordID.recordName,
                    itemId: record["itemId"] as? String ?? "",
                    originDeviceId: record["originDeviceId"] as? String ?? "",
                    schemaVersion: UInt32(record["schemaVersion"] as? Int64 ?? 1),
                    recordedAt: record["recordedAt"] as? Int64 ?? 0,
                    payloadType: record["payloadType"] as? String ?? "",
                    payloadData: rehydratedJSONString(for: record, field: .payloadData)
                )
            }

            let snapshotRecords: [SyncSnapshotRecord] = try changes.snapshots.map { record in
                try SyncSnapshotRecord(
                    itemId: record.recordID.recordName,
                    snapshotRevision: UInt64(record["snapshotRevision"] as? Int64 ?? 0),
                    schemaVersion: UInt32(record["schemaVersion"] as? Int64 ?? 1),
                    coversThroughEvent: record["coversThroughEvent"] as? String,
                    aggregateData: rehydratedJSONString(for: record, field: .aggregateData)
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
                defer { Self.cleanupTemporaryFiles(tempFiles) }

                for event in pendingEvents {
                    let recordID = CKRecord.ID(recordName: event.eventId, zoneID: zoneID)
                    let record = CKRecord(recordType: "ItemEvent", recordID: recordID)
                    record["itemId"] = event.itemId as CKRecordValue
                    record["originDeviceId"] = event.originDeviceId as CKRecordValue
                    record["schemaVersion"] = Int64(event.schemaVersion) as CKRecordValue
                    record["recordedAt"] = event.recordedAt as CKRecordValue
                    record["payloadType"] = event.payloadType as CKRecordValue

                    if let tempURL = try configureJSONField(
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

        private enum CloudRecordJSONField {
            case payloadData
            case aggregateData

            var recordFieldName: String {
                switch self {
                case .payloadData:
                    return "payloadData"
                case .aggregateData:
                    return "aggregateData"
                }
            }
        }

        private enum BlobPathComponent: Codable, Equatable {
            case key(String)
            case index(Int)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let key = try? container.decode(String.self) {
                    self = .key(key)
                } else {
                    self = try .index(container.decode(Int.self))
                }
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case let .key(key):
                    try container.encode(key)
                case let .index(index):
                    try container.encode(index)
                }
            }
        }

        private struct BlobBundleEntry: Codable, Equatable {
            let path: [BlobPathComponent]
            let base64Value: String
        }

        private struct BlobBundle: Codable, Equatable {
            let entries: [BlobBundleEntry]
        }

        private enum SyncEngineDataError: LocalizedError {
            case missingAssetFileURL(recordID: String)
            case assetReadFailed(recordID: String, underlying: Error)
            case invalidBlobBundle(recordID: String, underlying: Error)
            case jsonRehydrationFailed(recordID: String, underlying: Error)
            case blobInjectionFailed(recordID: String, path: String)

            var errorDescription: String? {
                switch self {
                case let .missingAssetFileURL(recordID):
                    return "CloudKit asset for record \(recordID) did not provide a file URL"
                case let .assetReadFailed(recordID, underlying):
                    return "Failed to read CloudKit asset for record \(recordID): \(underlying.localizedDescription)"
                case let .invalidBlobBundle(recordID, underlying):
                    return "Failed to decode CloudKit blob bundle for record \(recordID): \(underlying.localizedDescription)"
                case let .jsonRehydrationFailed(recordID, underlying):
                    return "Failed to rehydrate CloudKit JSON for record \(recordID): \(underlying.localizedDescription)"
                case let .blobInjectionFailed(recordID, path):
                    return "CloudKit blob bundle for record \(recordID) could not be injected at path \(path)"
                }
            }
        }

        // MARK: - CKAsset Helpers

        private func configureJSONField(
            _ jsonString: String,
            on record: CKRecord,
            field: CloudRecordJSONField
        ) throws -> URL? {
            if let (strippedJSON, bundle) = Self.extractBase64Bundle(from: jsonString) {
                record[field.recordFieldName] = strippedJSON as CKRecordValue
                let bundleURL = try Self.writeBlobBundle(bundle)
                record[Self.blobBundleFieldName] = CKAsset(fileURL: bundleURL)
                return bundleURL
            }

            record[field.recordFieldName] = jsonString as CKRecordValue
            return nil
        }

        private func rehydratedJSONString(
            for record: CKRecord,
            field: CloudRecordJSONField
        ) throws -> String {
            let jsonString = record[field.recordFieldName] as? String ?? "{}"
            guard let asset = record[Self.blobBundleFieldName] as? CKAsset else {
                return jsonString
            }
            guard let fileURL = asset.fileURL else {
                throw SyncEngineDataError.missingAssetFileURL(recordID: record.recordID.recordName)
            }

            let bundle: BlobBundle
            do {
                let data = try Data(contentsOf: fileURL)
                bundle = try JSONDecoder().decode(BlobBundle.self, from: data)
            } catch let error as DecodingError {
                throw SyncEngineDataError.invalidBlobBundle(
                    recordID: record.recordID.recordName,
                    underlying: error
                )
            } catch {
                throw SyncEngineDataError.assetReadFailed(
                    recordID: record.recordID.recordName,
                    underlying: error
                )
            }

            return try Self.inject(
                blobBundle: bundle,
                into: jsonString,
                recordID: record.recordID.recordName
            )
        }

        private static func writeBlobBundle(_ bundle: BlobBundle) throws -> URL {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".json")
            let data = try JSONEncoder().encode(bundle)
            try data.write(to: tempURL)
            return tempURL
        }

        private static func cleanupTemporaryFiles(_ urls: [URL]) {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }

        /// Recursively extract any non-empty base64 values from `_base64` JSON fields.
        private static func extractBase64Bundle(from jsonString: String) -> (String, BlobBundle)? {
            guard let jsonData = jsonString.data(using: .utf8),
                  var root = try? JSONSerialization.jsonObject(with: jsonData)
            else { return nil }

            var entries: [BlobBundleEntry] = []

            func walk(_ value: inout Any, path: [BlobPathComponent]) {
                if var dict = value as? [String: Any] {
                    for key in dict.keys.sorted() {
                        if let base64Value = dict[key] as? String,
                           key.hasSuffix("_base64"),
                           !base64Value.isEmpty,
                           Data(base64Encoded: base64Value) != nil
                        {
                            entries.append(
                                BlobBundleEntry(
                                    path: path + [.key(key)],
                                    base64Value: base64Value
                                )
                            )
                            dict[key] = ""
                            continue
                        }

                        if var child = dict[key] {
                            walk(&child, path: path + [.key(key)])
                            dict[key] = child
                        }
                    }
                    value = dict
                    return
                }

                if var array = value as? [Any] {
                    for index in array.indices {
                        var child = array[index]
                        walk(&child, path: path + [.index(index)])
                        array[index] = child
                    }
                    value = array
                }
            }

            walk(&root, path: [])

            guard !entries.isEmpty,
                  let strippedData = try? JSONSerialization.data(withJSONObject: root),
                  let strippedString = String(data: strippedData, encoding: .utf8)
            else { return nil }

            return (strippedString, BlobBundle(entries: entries))
        }

        private static func inject(
            blobBundle: BlobBundle,
            into jsonString: String,
            recordID: String
        ) throws -> String {
            guard let jsonData = jsonString.data(using: .utf8) else {
                throw SyncEngineDataError.jsonRehydrationFailed(
                    recordID: recordID,
                    underlying: NSError(
                        domain: "SyncEngine",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "JSON string was not valid UTF-8"]
                    )
                )
            }

            do {
                var root = try JSONSerialization.jsonObject(with: jsonData)
                for entry in blobBundle.entries {
                    guard setJSONValue(
                        entry.base64Value,
                        at: entry.path,
                        in: &root
                    ) else {
                        throw SyncEngineDataError.blobInjectionFailed(
                            recordID: recordID,
                            path: pathDescription(entry.path)
                        )
                    }
                }

                let resultData = try JSONSerialization.data(withJSONObject: root)
                guard let resultString = String(data: resultData, encoding: .utf8) else {
                    throw NSError(
                        domain: "SyncEngine",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to encode rehydrated JSON as UTF-8"]
                    )
                }
                return resultString
            } catch let error as SyncEngineDataError {
                throw error
            } catch {
                throw SyncEngineDataError.jsonRehydrationFailed(
                    recordID: recordID,
                    underlying: error
                )
            }
        }

        private static func setJSONValue(
            _ value: String,
            at path: [BlobPathComponent],
            in node: inout Any
        ) -> Bool {
            guard let component = path.first else { return false }

            switch component {
            case let .key(key):
                guard var dict = node as? [String: Any] else { return false }
                if path.count == 1 {
                    dict[key] = value
                    node = dict
                    return true
                }
                guard var child = dict[key] else { return false }
                guard setJSONValue(value, at: Array(path.dropFirst()), in: &child) else {
                    return false
                }
                dict[key] = child
                node = dict
                return true

            case let .index(index):
                guard var array = node as? [Any], array.indices.contains(index) else {
                    return false
                }
                if path.count == 1 {
                    array[index] = value
                    node = array
                    return true
                }
                var child = array[index]
                guard setJSONValue(value, at: Array(path.dropFirst()), in: &child) else {
                    return false
                }
                array[index] = child
                node = array
                return true
            }
        }

        private static func pathDescription(_ path: [BlobPathComponent]) -> String {
            if path.isEmpty {
                return "$"
            }

            return "$" + path.map { component in
                switch component {
                case let .key(key):
                    return ".\(key)"
                case let .index(index):
                    return "[\(index)]"
                }
            }.joined()
        }

        // MARK: - Compaction

        public func performCompaction() async {
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
                defer { Self.cleanupTemporaryFiles(tempFiles) }
                let records: [CKRecord] = try snapshots.map { snapshot in
                    let recordID = CKRecord.ID(recordName: snapshot.itemId, zoneID: zoneID)
                    let record = CKRecord(recordType: "ItemSnapshot", recordID: recordID)
                    record["snapshotRevision"] = Int64(snapshot.snapshotRevision) as CKRecordValue
                    record["schemaVersion"] = Int64(snapshot.schemaVersion) as CKRecordValue
                    record["coversThroughEvent"] = snapshot.coversThroughEvent as CKRecordValue?
                    if let tempURL = try configureJSONField(
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
                    aggregateData: rehydratedJSONString(for: record, field: .aggregateData)
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
                    payloadData: rehydratedJSONString(for: record, field: .payloadData)
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

        private var database: CKDatabase {
            container.privateCloudDatabase
        }

        init(containerIdentifier: String) {
            container = CKContainer(identifier: containerIdentifier)
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
