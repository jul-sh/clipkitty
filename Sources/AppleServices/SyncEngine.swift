#if ENABLE_ICLOUD_SYNC

    import ClipKittyRust
    import CloudKit
    import Foundation
    import Observation
    import os.log

    public struct SyncZoneChangeResult {
        public var events: [CKRecord]
        public var snapshots: [CKRecord]
        public var newToken: CKServerChangeToken?
        public var moreComing: Bool
        public var tokenExpired: Bool
        public var fetchError: Error?

        public init(
            events: [CKRecord] = [],
            snapshots: [CKRecord] = [],
            newToken: CKServerChangeToken? = nil,
            moreComing: Bool = false,
            tokenExpired: Bool = false,
            fetchError: Error? = nil
        ) {
            self.events = events
            self.snapshots = snapshots
            self.newToken = newToken
            self.moreComing = moreComing
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
    }

    private final class StoreOperationTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var activeOperationCount = 0
        private var drainWaiters: [CheckedContinuation<Void, Never>] = []

        func begin() {
            lock.lock()
            activeOperationCount += 1
            lock.unlock()
        }

        func finish() {
            let waiters: [CheckedContinuation<Void, Never>]
            lock.lock()
            activeOperationCount -= 1
            if activeOperationCount == 0 {
                waiters = drainWaiters
                drainWaiters.removeAll()
            } else {
                waiters = []
            }
            lock.unlock()

            for waiter in waiters {
                waiter.resume()
            }
        }

        func waitForDrain() async {
            await withCheckedContinuation { continuation in
                var shouldResumeImmediately = false
                lock.lock()
                if activeOperationCount == 0 {
                    shouldResumeImmediately = true
                } else {
                    drainWaiters.append(continuation)
                }
                lock.unlock()

                if shouldResumeImmediately {
                    continuation.resume()
                }
            }
        }
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

        public nonisolated static let cloudKitContainerIdentifier = "iCloud.com.eviljuliette.clipkitty"
        private nonisolated static let zoneName = "ClipKittySync"
        private nonisolated static let subscriptionID = "clipkitty-sync-changes"
        fileprivate nonisolated static let itemEventRecordType = "ItemEvent"
        fileprivate nonisolated static let itemSnapshotRecordType = "ItemSnapshot"
        private nonisolated static let compactionInterval: TimeInterval = 300 // 5 minutes
        private nonisolated static let baseInterval: TimeInterval = 30
        private nonisolated static let subscriptionActiveInterval: TimeInterval = 60
        private nonisolated static let blobBundleFieldName = "blobBundleAsset"
        /// Age threshold for CloudKit event cleanup (30 days).
        private nonisolated static let cloudCleanupAgeDays: UInt32 = 30
        private nonisolated static let indexMaintenanceBatchLimit: UInt32 = 64

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
        private let storeOperationTracker = StoreOperationTracker()
        @ObservationIgnored
        private var accountChangeObserver: NSObjectProtocol?
        @ObservationIgnored
        private var backoff = SyncBackoff()
        private var engineState: EngineState

        /// Wake signal for push notifications to collapse the sleep interval.
        /// Implemented as a main-actor flag + pending continuation to avoid the
        /// AsyncStream single-consumer iterator trap that caused a busy-loop.
        @ObservationIgnored
        private var pendingWake: Bool = false
        @ObservationIgnored
        private var wakeContinuation: CheckedContinuation<Void, Never>?
        @ObservationIgnored
        private var coordinatorCycleProgress: CoordinatorCycleProgress = .idle(completedGeneration: 0)
        @ObservationIgnored
        private var coordinatorCycleWaiters: [CoordinatorCycleWaiter] = []

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

        private enum IndexMaintenancePass {
            case notNeeded
            case needed(SyncIndexActivity)
        }

        /// Structured outcome of uploading snapshots to CloudKit.
        private enum SnapshotUploadOutcome {
            case uploaded(count: Int)
            case nothingToUpload
            case retryableFailure(reason: String)
            case permanentFailure(reason: String)
        }

        private enum CoordinatorCycleProgress {
            case idle(completedGeneration: UInt64)
            case running(completedGeneration: UInt64)
        }

        private struct CoordinatorCycleWaiter {
            let targetGeneration: UInt64
            let continuation: CheckedContinuation<BackgroundSyncResult, Never>
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

        public struct SyncRecordCounts: Equatable, Sendable {
            public let events: Int
            public let snapshots: Int

            public init(events: Int, snapshots: Int) {
                self.events = events
                self.snapshots = snapshots
            }

            public var total: Int {
                events + snapshots
            }
        }

        public enum SyncDownloadActivity: Equatable, Sendable {
            case startingFullResync
            case incremental(records: SyncRecordCounts)
            case fullResync(records: SyncRecordCounts)
        }

        public enum SyncIndexActivity: Equatable, Sendable {
            case localMaintenance
            case downloadedContent(SyncDownloadActivity)
        }

        public enum SyncUploadActivity: Equatable, Sendable {
            case events(count: Int)
            case snapshots(count: Int)
        }

        public enum SyncActivity: Equatable, Sendable {
            case downloading(SyncDownloadActivity)
            case applying(SyncDownloadActivity)
            case rebuildingIndex(SyncIndexActivity)
            case compacting
            case uploading(SyncUploadActivity)
            case cleaningUp(count: Int)

            /// Single source of truth for the settings status line shown on both
            /// iOS and macOS. Per-platform overlays may present different copy.
            public var statusDescription: String {
                switch self {
                case let .downloading(download):
                    switch download {
                    case .startingFullResync:
                        return String(localized: "Waiting on iCloud…")
                    case let .incremental(records), let .fullResync(records):
                        return String(localized: "iCloud: \(records.total) changes…")
                    }
                case let .applying(download):
                    switch download {
                    case .startingFullResync:
                        return String(localized: "iCloud catch-up…")
                    case let .incremental(records), let .fullResync(records):
                        return String(localized: "iCloud catch-up: \(records.total) changes…")
                    }
                case let .rebuildingIndex(indexActivity):
                    switch indexActivity {
                    case .localMaintenance:
                        return String(localized: "Indexing…")
                    case .downloadedContent:
                        return String(localized: "Indexing iCloud…")
                    }
                case .compacting:
                    return String(localized: "Compacting history…")
                case let .uploading(upload):
                    switch upload {
                    case let .events(count):
                        return String(localized: "Uploading \(count) changes…")
                    case let .snapshots(count):
                        return String(localized: "Uploading \(count) checkpoints…")
                    }
                case let .cleaningUp(count):
                    return String(localized: "Cleaning up \(count) cloud records…")
                }
            }
        }

        private enum ActivityState: Equatable {
            case connecting
            case syncing(SyncActivity)
            case synced(lastSync: Date)
            case error(String)
            case temporarilyUnavailable
        }

        private struct MaintenanceState {
            var lastCompactionDate: Date?
            var lastCloudCleanupDate: Date?
        }

        private struct FullResyncCloudRecords {
            var events: [CKRecord]
            var snapshots: [CKRecord]
            var finalChangeToken: CKServerChangeToken?
        }

        private struct EventUploadBatch {
            let pendingCount: Int
            let records: [CKRecord]
            let tempFiles: [URL]
        }

        private struct SnapshotUploadBatch {
            let pendingCount: Int
            let records: [CKRecord]
            let tempFiles: [URL]
        }

        // MARK: - Init

        public convenience init(store: ClipKittyRust.ClipboardStore) {
            self.init(
                store: store,
                cloud: CloudKitSyncTransport(containerIdentifier: Self.cloudKitContainerIdentifier)
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
            signalWake()
            completeCoordinatorCycleWaiters(result: .failed("iCloud sync stopped"))
            removeAccountChangeObserver()
            engineState = .idle(maintenanceState())
            logger.info("SyncEngine stopped")
        }

        /// Stop the coordinator and wait until any synchronous Rust store work
        /// has fully drained before allowing iOS to suspend the process.
        public func prepareForSuspend() async {
            let task = coordinatorTask
            coordinatorTask = nil
            task?.cancel()
            signalWake()
            completeCoordinatorCycleWaiters(result: .failed("iCloud sync stopped"))
            removeAccountChangeObserver()
            engineState = .idle(maintenanceState())

            await task?.value
            await storeOperationTracker.waitForDrain()

            guard !Task.isCancelled else {
                logger.info("SyncEngine suspend preparation cancelled before store flush")
                return
            }

            let store = self.store
            await Task.detached(priority: .utility) {
                store.prepareForSuspend()
            }.value
            logger.info("SyncEngine prepared for suspend")
        }

        /// Signal the coordinator to wake up immediately (e.g. from push notification).
        public func handleRemoteNotification() {
            guard coordinatorTask != nil else { return }
            signalWake()
        }

        /// Run a single sync cycle for an iOS background wake.
        ///
        /// When the normal coordinator loop is already active, a background wake
        /// only needs to collapse the sleep interval. Otherwise this performs
        /// the same coordinator cycle headlessly so a silent CloudKit push can
        /// catch up before the user opens the app.
        public func runBackgroundSyncCycle() async -> BackgroundSyncResult {
            guard coordinatorTask == nil else {
                return await waitForCoordinatorCycleAfterBackgroundWake()
            }

            store.setSyncDeviceId(deviceId: deviceId)
            return await runCoordinatorCycle()
        }

        /// Mark a wake as pending and resume any waiting sleeper.
        private func signalWake() {
            pendingWake = true
            if let continuation = wakeContinuation {
                wakeContinuation = nil
                continuation.resume()
            }
        }

        private func waitForCoordinatorCycleAfterBackgroundWake() async -> BackgroundSyncResult {
            let targetGeneration: UInt64
            switch coordinatorCycleProgress {
            case let .idle(completedGeneration):
                targetGeneration = completedGeneration + 1
            case let .running(completedGeneration):
                targetGeneration = completedGeneration + 2
            }

            return await withCheckedContinuation { continuation in
                coordinatorCycleWaiters.append(
                    CoordinatorCycleWaiter(
                        targetGeneration: targetGeneration,
                        continuation: continuation
                    )
                )
                signalWake()
            }
        }

        private func beginCoordinatorCycle() {
            switch coordinatorCycleProgress {
            case let .idle(completedGeneration):
                coordinatorCycleProgress = .running(completedGeneration: completedGeneration)
            case .running:
                break
            }
        }

        private func finishCoordinatorCycle(result: BackgroundSyncResult) {
            let completedGeneration: UInt64
            switch coordinatorCycleProgress {
            case let .idle(generation):
                completedGeneration = generation
            case let .running(generation):
                completedGeneration = generation + 1
            }

            coordinatorCycleProgress = .idle(completedGeneration: completedGeneration)
            let readyWaiters = coordinatorCycleWaiters.filter {
                $0.targetGeneration <= completedGeneration
            }
            coordinatorCycleWaiters.removeAll {
                $0.targetGeneration <= completedGeneration
            }

            for waiter in readyWaiters {
                waiter.continuation.resume(returning: result)
            }
        }

        private func completeCoordinatorCycleWaiters(result: BackgroundSyncResult) {
            let waiters = coordinatorCycleWaiters
            coordinatorCycleWaiters.removeAll()
            for waiter in waiters {
                waiter.continuation.resume(returning: result)
            }
        }

        // MARK: - Status

        public enum SyncStatus: Equatable {
            case idle
            case connecting
            case syncing(SyncActivity)
            case synced(lastSync: Date)
            case error(String)
            case temporarilyUnavailable
            case unavailable
        }

        public enum BackgroundSyncResult: Equatable, Sendable {
            case completed
            case unavailable
            case failed(String)
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
                case let .syncing(activity):
                    return .syncing(activity)
                case let .synced(lastSync):
                    return .synced(lastSync: lastSync)
                case let .error(message):
                    return .error(message)
                case .temporarilyUnavailable:
                    return .temporarilyUnavailable
                }
            }
        }

        /// Marks the engine as unavailable and stops it.
        private func setUnavailable() {
            coordinatorTask?.cancel()
            coordinatorTask = nil
            completeCoordinatorCycleWaiters(result: .unavailable)
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
                case (.ready, .syncing(_)), (.ready, .synced(_)), (.ready, .error(_)):
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

                await sleepOrWake(for: delay)
            }
        }

        /// Sleep for `delay` seconds or return early if a wake signal arrives.
        private func sleepOrWake(for delay: TimeInterval) async {
            // Fast path: consume any wake that arrived while the cycle ran.
            if pendingWake {
                pendingWake = false
                return
            }

            // Race a sleep task against a continuation the wake signal will
            // resume. The sleep task resumes the continuation on expiry so
            // we only ever resume it once.
            let sleepTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.wakeContinuationOnSleepExpiry()
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                wakeContinuation = continuation
                if pendingWake {
                    // A wake arrived between the fast-path check and here.
                    pendingWake = false
                    wakeContinuation = nil
                    continuation.resume()
                }
            }
            sleepTask.cancel()
            pendingWake = false
        }

        /// Called by the sleep task when its timer expires — resumes the
        /// waiting coordinator cycle.
        private func wakeContinuationOnSleepExpiry() {
            guard let continuation = wakeContinuation else { return }
            wakeContinuation = nil
            continuation.resume()
        }

        /// Flip UI status to `.syncing`, but only when the cycle has detected
        /// real work. Called from the phases that actually do observable work
        /// (remote changes arriving, pending uploads, full resync, compaction)
        /// so that idle no-op polls don't flash "Syncing…" in settings.
        private func markSyncing(_ activity: SyncActivity) {
            updateActiveState { state in
                state.activity = .syncing(activity)
            }
        }

        private func performStoreOperation<T>(
            priority: TaskPriority = .utility,
            _ body: @escaping @Sendable (ClipKittyRust.ClipboardStore) throws -> T
        ) async throws -> T {
            let store = self.store
            let tracker = storeOperationTracker
            tracker.begin()
            return try await Task.detached(priority: priority) {
                defer { tracker.finish() }
                return try body(store)
            }.value
        }

        private func processQueuedIndexWork(activity: SyncIndexActivity) async {
            markSyncing(.rebuildingIndex(activity))
            do {
                let outcome = try await performStoreOperation { store in
                    try store.processIndexQueue(maxItems: Self.indexMaintenanceBatchLimit)
                }
                logIndexMaintenanceOutcome(outcome)
            } catch {
                logger.error("Queued index maintenance failed: \(error.localizedDescription)")
            }
        }

        private func logIndexMaintenanceOutcome(_ outcome: IndexMaintenanceOutcome) {
            switch outcome {
            case let .completed(processed):
                logger.info("Queued index maintenance completed after \(processed) items")
            case let .moreRemaining(processed, remaining):
                logger.info(
                    "Queued index maintenance processed \(processed) items; \(remaining) remain"
                )
            }
        }

        /// Single serial coordinator cycle: fetch -> apply -> compact -> upload -> cleanup.
        @discardableResult
        public func runCoordinatorCycle() async -> BackgroundSyncResult {
            beginCoordinatorCycle()
            let result = await performCoordinatorCycle()
            finishCoordinatorCycle(result: result)
            return result
        }

        private func performCoordinatorCycle() async -> BackgroundSyncResult {
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
                    return .failed("iCloud temporarily unavailable")
                case .unavailable:
                    logger.warning("iCloud account unavailable, sync disabled")
                    setUnavailable()
                    return .unavailable
                }

                prepareForAvailableCycle()
                try await ensureZoneExists()
                await setupSubscription()

                // ── Phase 0: Check device state ──
                let deviceId = self.deviceId
                let deviceState = try await performStoreOperation { store in
                    try store.getSyncDeviceState(deviceId: deviceId)
                }

                if deviceState.needsFullResync {
                    logger.info("Full resync required")
                    try await performFullResync()
                    backoff.reset()
                    updateActiveState { state in
                        state.activity = .synced(lastSync: now())
                    }
                    return .completed
                }

                if deviceState.indexDirty {
                    logger.info("Index dirty, processing queued index work")
                    await processQueuedIndexWork(activity: .localMaintenance)
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
                    return .completed
                }
                if let fetchError = changes.fetchError {
                    throw fetchError
                }

                // ── Phase 2: Convert CKRecords + rehydrate CKAssets ──
                let downloadedRecordCounts = SyncRecordCounts(
                    events: changes.events.count,
                    snapshots: changes.snapshots.count
                )
                let incrementalDownload = SyncDownloadActivity.incremental(records: downloadedRecordCounts)
                if !changes.events.isEmpty || !changes.snapshots.isEmpty {
                    markSyncing(.applying(incrementalDownload))
                }
                let (eventRecords, snapshotRecords) = try await convertCloudKitRecords(changes)

                // ── Phase 3: Apply batch (Rust) ──
                let batchOutcome = try await performStoreOperation { store in
                    try store.applyRemoteBatch(
                        eventRecords: eventRecords,
                        snapshotRecords: snapshotRecords
                    )
                }

                // ── Phase 4: Token advancement (conditional on success) ──
                let indexMaintenancePass: IndexMaintenancePass
                switch batchOutcome {
                case let .applied(eventsApplied, snapshotsApplied):
                    if let newToken = changes.newToken {
                        let tokenData = try NSKeyedArchiver.archivedData(
                            withRootObject: newToken,
                            requiringSecureCoding: true
                        )
                        try await performStoreOperation { store in
                            try store.updateZoneChangeToken(deviceId: deviceId, token: tokenData)
                        }
                    }
                    if eventsApplied > 0 || snapshotsApplied > 0 {
                        onContentChanged?()
                        indexMaintenancePass = .needed(.downloadedContent(incrementalDownload))
                    } else {
                        indexMaintenancePass = .notNeeded
                    }

                case let .partialFailure(appliedCount, _, _):
                    // Do NOT advance token — retry on next cycle.
                    if appliedCount > 0 {
                        onContentChanged?()
                        indexMaintenancePass = .needed(.downloadedContent(incrementalDownload))
                    } else {
                        indexMaintenancePass = .notNeeded
                    }
                    logger.warning("Partial batch failure, not advancing token")

                case .fullResyncRequired:
                    logger.info("Batch triggered full resync")
                    try await performFullResync()
                    backoff.reset()
                    updateActiveState { state in
                        state.activity = .synced(lastSync: now())
                    }
                    return .completed
                }

                switch indexMaintenancePass {
                case .notNeeded:
                    break
                case let .needed(activity):
                    await processQueuedIndexWork(activity: activity)
                }

                // ── Phase 5: Periodic compaction ──
                if shouldRunCompaction() {
                    markSyncing(.compacting)
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
                    return .completed
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
                    return .failed(reason)
                case let .permanentFailure(reason):
                    logger.error("Upload permanent failure: \(reason)")
                    updateActiveState { state in
                        state.activity = .error(reason)
                    }
                    return .failed(reason)
                }

            } catch {
                let delay = backoff.registerFailure(error: error)
                logger.error("Coordinator cycle error: \(error.localizedDescription), backoff \(delay)s")
                updateActiveState { state in
                    state.activity = .error(error.localizedDescription)
                }
                return .failed(error.localizedDescription)
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
                signalWake()
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
        ) async throws -> ([SyncEventRecord], [SyncSnapshotRecord]) {
            let events = changes.events
            let snapshots = changes.snapshots
            return try await Task.detached(priority: .utility) {
                try Self.convertCloudKitRecords(events: events, snapshots: snapshots)
            }.value
        }

        private nonisolated static func convertCloudKitRecords(
            events: [CKRecord],
            snapshots: [CKRecord]
        ) throws -> ([SyncEventRecord], [SyncSnapshotRecord]) {
            let eventRecords: [SyncEventRecord] = try events.map { record in
                try SyncEventRecord(
                    eventId: record.recordID.recordName,
                    itemId: record["itemId"] as? String ?? "",
                    originDeviceId: record["originDeviceId"] as? String ?? "",
                    schemaVersion: UInt32(record["schemaVersion"] as? Int64 ?? 1),
                    recordedAt: record["recordedAt"] as? Int64 ?? 0,
                    payloadType: record["payloadType"] as? String ?? "",
                    payloadData: Self.rehydratedJSONString(for: record, field: .payloadData)
                )
            }

            let snapshotRecords: [SyncSnapshotRecord] = try snapshots.map { record in
                try SyncSnapshotRecord(
                    itemId: record.recordID.recordName,
                    snapshotRevision: UInt64(record["snapshotRevision"] as? Int64 ?? 0),
                    schemaVersion: UInt32(record["schemaVersion"] as? Int64 ?? 1),
                    coversThroughEvent: record["coversThroughEvent"] as? String,
                    aggregateData: Self.rehydratedJSONString(for: record, field: .aggregateData)
                )
            }

            return (eventRecords, snapshotRecords)
        }

        // MARK: - Upload

        private func makeEventUploadBatch() async throws -> EventUploadBatch? {
            let zoneID = recordZone.zoneID
            return try await performStoreOperation { store in
                let pendingEvents = try store.pendingLocalEvents()
                guard !pendingEvents.isEmpty else { return nil }

                var records: [CKRecord] = []
                var tempFiles: [URL] = []

                for event in pendingEvents {
                    let recordID = CKRecord.ID(recordName: event.eventId, zoneID: zoneID)
                    let record = CKRecord(recordType: Self.itemEventRecordType, recordID: recordID)
                    record["itemId"] = event.itemId as CKRecordValue
                    record["originDeviceId"] = event.originDeviceId as CKRecordValue
                    record["schemaVersion"] = Int64(event.schemaVersion) as CKRecordValue
                    record["recordedAt"] = event.recordedAt as CKRecordValue
                    record["payloadType"] = event.payloadType as CKRecordValue

                    if let tempURL = try Self.configureJSONField(
                        event.payloadData,
                        on: record,
                        field: .payloadData
                    ) {
                        tempFiles.append(tempURL)
                    }
                    records.append(record)
                }

                return EventUploadBatch(
                    pendingCount: pendingEvents.count,
                    records: records,
                    tempFiles: tempFiles
                )
            }
        }

        /// Upload pending events to CloudKit with structured outcome.
        private func uploadPendingEvents() async -> UploadOutcome {
            do {
                guard let uploadBatch = try await makeEventUploadBatch() else {
                    return .nothingToUpload
                }
                markSyncing(.uploading(.events(count: uploadBatch.pendingCount)))
                defer { Self.cleanupTemporaryFiles(uploadBatch.tempFiles) }

                let saveResult = await cloud.saveRecords(uploadBatch.records, savePolicy: .ifServerRecordUnchanged)

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
                    try await performStoreOperation { store in
                        try store.markEventsUploaded(eventIds: uploadedEventIds)
                    }
                    logger.debug("Uploaded \(uploadedEventIds.count) events")
                }

                // Determine outcome based on success/failure counts.
                let missingRecordCount = uploadBatch.pendingCount - uploadedEventIds.count - errors.count
                let primaryError = errors.first ?? (missingRecordCount > 0 ? saveResult.operationError : nil)
                if primaryError == nil {
                    return .uploaded(eventIds: uploadedEventIds)
                }

                if let primaryError {
                    if Self.isPermanentError(primaryError) {
                        return .permanentFailure(reason: Self.userVisibleSyncError(primaryError))
                    }
                    return .retryableFailure(reason: Self.userVisibleSyncError(primaryError))
                }
                return .retryableFailure(reason: "CloudKit event upload failed")

            } catch {
                if Self.isPermanentError(error) {
                    return .permanentFailure(reason: Self.userVisibleSyncError(error))
                }
                return .retryableFailure(reason: Self.userVisibleSyncError(error))
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

        private static func userVisibleSyncError(_ error: Error) -> String {
            if isMissingRecordTypeError(error, recordType: itemSnapshotRecordType) {
                return SyncEngineSchemaError.missingCloudKitRecordType(
                    recordType: itemSnapshotRecordType,
                    containerIdentifier: cloudKitContainerIdentifier
                ).localizedDescription
            }
            if isMissingRecordTypeError(error, recordType: itemEventRecordType) {
                return SyncEngineSchemaError.missingCloudKitRecordType(
                    recordType: itemEventRecordType,
                    containerIdentifier: cloudKitContainerIdentifier
                ).localizedDescription
            }
            return error.localizedDescription
        }

        private static func isMissingRecordTypeError(
            _ error: Error,
            recordType: String
        ) -> Bool {
            let nsError = error as NSError
            var messages = [nsError.localizedDescription]
            messages.append(contentsOf: nsError.userInfo.values.compactMap { value in
                switch value {
                case let nestedError as NSError:
                    return nestedError.localizedDescription
                case let message as String:
                    return message
                default:
                    return nil
                }
            })

            return messages.contains { message in
                message.localizedCaseInsensitiveContains("did not find record type")
                    && message.localizedCaseInsensitiveContains(recordType)
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
                }
            }
        }

        // MARK: - CKAsset Helpers

        private nonisolated static func configureJSONField(
            _ jsonString: String,
            on record: CKRecord,
            field: CloudRecordJSONField
        ) throws -> URL? {
            if let (strippedJSON, bundle) = extractBase64Bundle(from: jsonString) {
                record[field.recordFieldName] = strippedJSON as CKRecordValue
                let bundleURL = try writeBlobBundle(bundle)
                record[blobBundleFieldName] = CKAsset(fileURL: bundleURL)
                return bundleURL
            }

            record[field.recordFieldName] = jsonString as CKRecordValue
            record[blobBundleFieldName] = nil
            return nil
        }

        private nonisolated static func rehydratedJSONString(
            for record: CKRecord,
            field: CloudRecordJSONField
        ) throws -> String {
            let jsonString = record[field.recordFieldName] as? String ?? "{}"
            guard let asset = record[blobBundleFieldName] as? CKAsset else {
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

        private nonisolated static func writeBlobBundle(_ bundle: BlobBundle) throws -> URL {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".json")
            let data = try JSONEncoder().encode(bundle)
            try data.write(to: tempURL)
            return tempURL
        }

        private nonisolated static func cleanupTemporaryFiles(_ urls: [URL]) {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }

        /// Recursively extract any non-empty base64 values from `_base64` JSON fields.
        private nonisolated static func extractBase64Bundle(from jsonString: String) -> (String, BlobBundle)? {
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

        private nonisolated static func inject(
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
                    // Snapshot uploads use changed keys, so older CloudKit records can retain
                    // a blob asset after the JSON no longer contains that base64 field.
                    guard setJSONValue(
                        entry.base64Value,
                        at: entry.path,
                        in: &root
                    ) else {
                        continue
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

        private nonisolated static func setJSONValue(
            _ value: String,
            at path: [BlobPathComponent],
            in node: inout Any
        ) -> Bool {
            guard let component = path.first else { return false }

            switch component {
            case let .key(key):
                guard var dict = node as? [String: Any] else { return false }
                if path.count == 1 {
                    guard let existing = dict[key] as? String, existing.isEmpty else { return false }
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
                    guard let existing = array[index] as? String, existing.isEmpty else { return false }
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

        // MARK: - Compaction

        public func performCompaction() async {
            do {
                let result = try await performStoreOperation { store in
                    try store.runCompaction()
                }
                if result.itemsCompacted > 0 || result.eventsPurged > 0 || result.tombstonesPurged > 0 {
                    logger.info(
                        "Compaction: \(result.itemsCompacted) items, \(result.eventsPurged) events purged, \(result.tombstonesPurged) tombstones purged"
                    )
                }
            } catch {
                logger.error("Compaction error: \(error.localizedDescription)")
            }
        }

        private func makeSnapshotUploadBatch() async throws -> SnapshotUploadBatch? {
            let zoneID = recordZone.zoneID
            return try await performStoreOperation { store in
                let snapshots = try store.pendingSnapshotRecords()
                guard !snapshots.isEmpty else { return nil }

                var tempFiles: [URL] = []
                let records: [CKRecord] = try snapshots.map { snapshot in
                    let recordID = CKRecord.ID(recordName: snapshot.itemId, zoneID: zoneID)
                    let record = CKRecord(recordType: Self.itemSnapshotRecordType, recordID: recordID)
                    record["snapshotRevision"] = Int64(snapshot.snapshotRevision) as CKRecordValue
                    record["schemaVersion"] = Int64(snapshot.schemaVersion) as CKRecordValue
                    record["coversThroughEvent"] = snapshot.coversThroughEvent as CKRecordValue?
                    if let tempURL = try Self.configureJSONField(
                        snapshot.aggregateData,
                        on: record,
                        field: .aggregateData
                    ) {
                        tempFiles.append(tempURL)
                    }
                    return record
                }

                return SnapshotUploadBatch(
                    pendingCount: snapshots.count,
                    records: records,
                    tempFiles: tempFiles
                )
            }
        }

        /// Upload compacted snapshots to CloudKit and mark them as uploaded.
        private func uploadSnapshots() async -> SnapshotUploadOutcome {
            do {
                guard let uploadBatch = try await makeSnapshotUploadBatch() else {
                    return .nothingToUpload
                }
                markSyncing(.uploading(.snapshots(count: uploadBatch.pendingCount)))
                defer { Self.cleanupTemporaryFiles(uploadBatch.tempFiles) }

                var uploadedCount = 0
                for chunk in uploadBatch.records.chunked(into: 400) {
                    let saveResult = await cloud.saveRecords(chunk, savePolicy: .changedKeys)
                    let savedIds = saveResult.savedRecordIDs.map(\.recordName)
                    let errors = Array(saveResult.perRecordErrors.values)

                    // Mark each successfully uploaded snapshot.
                    if !savedIds.isEmpty {
                        try await performStoreOperation { store in
                            for itemId in savedIds {
                                try store.markSnapshotUploaded(itemId: itemId)
                            }
                        }
                    }
                    uploadedCount += savedIds.count

                    let missingRecordCount = chunk.count - savedIds.count - errors.count
                    if let error = errors.first ?? (missingRecordCount > 0 ? saveResult.operationError : nil) {
                        logger.error("Snapshot upload error: \(error.localizedDescription)")
                        if Self.isPermanentError(error) {
                            return .permanentFailure(reason: Self.userVisibleSyncError(error))
                        }
                        return .retryableFailure(reason: Self.userVisibleSyncError(error))
                    }
                }

                logger.debug("Uploaded \(uploadedCount) snapshots to CloudKit")
                return .uploaded(count: uploadedCount)
            } catch {
                logger.error("Snapshot upload error: \(error.localizedDescription)")
                if Self.isPermanentError(error) {
                    return .permanentFailure(reason: Self.userVisibleSyncError(error))
                }
                return .retryableFailure(reason: Self.userVisibleSyncError(error))
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
                let eventIds = try await performStoreOperation { store in
                    try store.purgeableCloudEventIds(maxAgeDays: Self.cloudCleanupAgeDays)
                }
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
                markSyncing(.cleaningUp(count: recordIDs.count))

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
                    let eventIdsToPurge = deletedEventIds
                    let purged = try await performStoreOperation { store in
                        try store.purgeCloudEvents(eventIds: eventIdsToPurge)
                    }
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

        private enum SyncEngineSchemaError: LocalizedError {
            case missingCloudKitRecordType(
                recordType: String,
                containerIdentifier: String
            )
            case unresolvedFullResyncTailEvents(count: UInt64)
            case incompleteFullResyncMissingContinuationToken

            var errorDescription: String? {
                switch self {
                case let .missingCloudKitRecordType(recordType, containerIdentifier):
                    return """
                    CloudKit schema is missing \(recordType) in \(containerIdentifier). \
                    Deploy the iCloud Production schema for ClipKitty, then try sync again.
                    """
                case let .unresolvedFullResyncTailEvents(count):
                    return """
                    Full iCloud resync left \(count) event(s) waiting for missing history. \
                    Sync will retry instead of claiming success.
                    """
                case .incompleteFullResyncMissingContinuationToken:
                    return """
                    Full iCloud resync received a paginated CloudKit response without a \
                    continuation token. Sync will retry instead of claiming success.
                    """
                }
            }
        }

        private func fetchAllCloudRecordsForFullResync() async throws -> FullResyncCloudRecords {
            var allEvents: [CKRecord] = []
            var allSnapshots: [CKRecord] = []
            var changeToken: CKServerChangeToken?
            var finalChangeToken: CKServerChangeToken?

            repeat {
                let changes = await cloud.fetchZoneChanges(in: recordZone.zoneID, since: changeToken)
                if changes.tokenExpired {
                    throw CKError(.changeTokenExpired)
                }
                if let fetchError = changes.fetchError {
                    throw fetchError
                }

                allEvents.append(contentsOf: changes.events)
                allSnapshots.append(contentsOf: changes.snapshots)
                finalChangeToken = changes.newToken

                guard changes.moreComing else {
                    break
                }
                guard let nextToken = changes.newToken else {
                    throw SyncEngineSchemaError.incompleteFullResyncMissingContinuationToken
                }
                changeToken = nextToken
            } while true

            return FullResyncCloudRecords(
                events: allEvents,
                snapshots: allSnapshots,
                finalChangeToken: finalChangeToken
            )
        }

        private nonisolated static func archivedZoneChangeToken(_ changeToken: CKServerChangeToken?) throws -> Data? {
            if let changeToken {
                return try NSKeyedArchiver.archivedData(
                    withRootObject: changeToken,
                    requiringSecureCoding: true
                )
            }
            return nil
        }

        private func performFullResync() async throws {
            logger.info("Starting full resync")
            // 1. Fetch the complete custom-zone change feed from CloudKit.
            markSyncing(.downloading(.startingFullResync))
            let cloudRecords = try await fetchAllCloudRecordsForFullResync()
            let downloadedRecords = SyncRecordCounts(
                events: cloudRecords.events.count,
                snapshots: cloudRecords.snapshots.count
            )
            let downloadActivity = SyncDownloadActivity.fullResync(records: downloadedRecords)
            markSyncing(.applying(downloadActivity))

            // 2. Convert to FFI records and pass BOTH checkpoints and tail
            // events to Rust away from the main actor.
            let result = try await performStoreOperation { store in
                let (eventRecords, snapshotRecords) = try Self.convertCloudKitRecords(
                    events: cloudRecords.events,
                    snapshots: cloudRecords.snapshots
                )
                return try store.fullResyncWithTail(
                    snapshotRecords: snapshotRecords,
                    tailEventRecords: eventRecords
                )
            }
            logger.info(
                """
                Full resync: \(result.checkpointsApplied) checkpoints, \
                \(result.tailEventsApplied) tail events applied, \
                \(result.tailEventsIgnored) ignored, \
                \(result.tailEventsForked) forked, \
                \(result.tailEventsDeferred) deferred
                """
            )
            if result.tailEventsDeferred > 0 {
                throw SyncEngineSchemaError.unresolvedFullResyncTailEvents(
                    count: result.tailEventsDeferred
                )
            }

            // 3. Queue derived search-index repair and save the fresh zone token
            // from the full feed so the next cycle resumes incrementally instead
            // of replaying the whole zone again. Search indexing is durable,
            // bounded, and resumable; it must not gate token advancement.
            let finalChangeToken = cloudRecords.finalChangeToken
            let deviceId = self.deviceId
            let finalTokenData = try Self.archivedZoneChangeToken(finalChangeToken)
            let queuedItems = try await performStoreOperation { store in
                let queuedItems = try store.enqueueFullIndexRebuild()
                try store.updateZoneChangeToken(
                    deviceId: deviceId,
                    token: finalTokenData
                )
                return queuedItems
            }
            logger.info("Queued full-resync index maintenance for \(queuedItems) items")
            await processQueuedIndexWork(activity: .downloadedContent(downloadActivity))

            // 4. Notify UI.
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
                        if record.recordType == SyncEngine.itemEventRecordType {
                            result.events.append(record)
                        } else if record.recordType == SyncEngine.itemSnapshotRecordType {
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
                    case let .success((token, _, moreComing)):
                        result.newToken = token
                        result.moreComing = moreComing
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
