#if ENABLE_ICLOUD_SYNC

    import BackgroundTasks
    import ClipKittyCloudSync
    import ClipKittyCore
    import ClipKittyRust
    import os
    import SwiftUI
    import UIKit

    // MARK: - Sync Engine Protocol

    /// Abstraction over SyncEngine so iOSSyncCoordinator can be tested with a spy.
    @MainActor
    protocol SyncEngineProtocol: AnyObject {
        var onContentChanged: (() -> Void)? { get set }
        var status: SyncEngine.SyncStatus { get }
        func start()
        func stop()
        func prepareForSuspend() async
        func handleRemoteNotification()
        func runBackgroundSyncCycle() async -> SyncEngine.BackgroundSyncResult
    }

    extension SyncEngine: SyncEngineProtocol {}

    // MARK: - Sync Coordinator

    /// Manages the SyncEngine lifecycle based on user settings and app scene phase.
    @MainActor
    @Observable
    final class iOSSyncCoordinator {
        private enum Runtime {
            case disabled(store: ClipKittyRust.ClipboardStore)
            case stopped(
                store: ClipKittyRust.ClipboardStore,
                engine: any SyncEngineProtocol
            )
            case enabled(store: ClipKittyRust.ClipboardStore, engine: any SyncEngineProtocol)
            case suspending(Task<Void, Never>)
            case suspended
        }

        @ObservationIgnored
        private var runtime: Runtime

        @ObservationIgnored
        private let onContentChanged: () -> Void

        @ObservationIgnored
        private let engineFactory: (ClipKittyRust.ClipboardStore) -> any SyncEngineProtocol
        @ObservationIgnored
        private let registerForRemoteNotifications: () -> Void
        @ObservationIgnored
        private let scheduleBackgroundSync: () -> Void

        var status: SyncEngine.SyncStatus {
            switch runtime {
            case .disabled, .stopped, .suspending, .suspended:
                return .idle
            case let .enabled(_, engine):
                return engine.status
            }
        }

        convenience init(
            store: ClipKittyRust.ClipboardStore,
            enabled: Bool,
            onContentChanged: @escaping () -> Void
        ) {
            self.init(
                store: store,
                enabled: enabled,
                onContentChanged: onContentChanged,
                engineFactory: { SyncEngine(store: $0) },
                registerForRemoteNotifications: {
                    iOSRemoteNotificationBridge.shared.registerForRemoteNotifications()
                },
                scheduleBackgroundSync: {
                    iOSBackgroundSyncScheduler.shared.scheduleAll()
                }
            )
        }

        init(
            store: ClipKittyRust.ClipboardStore,
            enabled: Bool,
            onContentChanged: @escaping () -> Void,
            engineFactory: @escaping (ClipKittyRust.ClipboardStore) -> any SyncEngineProtocol,
            registerForRemoteNotifications: @escaping () -> Void = {},
            scheduleBackgroundSync: @escaping () -> Void = {}
        ) {
            self.onContentChanged = onContentChanged
            self.engineFactory = engineFactory
            self.registerForRemoteNotifications = registerForRemoteNotifications
            self.scheduleBackgroundSync = scheduleBackgroundSync
            if enabled {
                let engine = engineFactory(store)
                engine.onContentChanged = onContentChanged
                runtime = .enabled(store: store, engine: engine)
                registerForRemoteNotifications()
                scheduleBackgroundSync()
            } else {
                runtime = .disabled(store: store)
            }
        }

        func setSyncEnabled(_ enabled: Bool) {
            switch runtime {
            case let .disabled(store):
                guard enabled else { return }
                let engine = engineFactory(store)
                engine.onContentChanged = onContentChanged
                runtime = .enabled(store: store, engine: engine)
                registerForRemoteNotifications()
                scheduleBackgroundSync()
                engine.start()

            case let .stopped(store, engine):
                guard enabled else { return }
                runtime = .enabled(store: store, engine: engine)
                registerForRemoteNotifications()
                scheduleBackgroundSync()
                engine.start()

            case let .enabled(store, engine):
                guard !enabled else { return }
                engine.stop()
                runtime = .stopped(store: store, engine: engine)

            case .suspending, .suspended:
                break
            }
        }

        func handleScenePhaseChange(_ phase: ScenePhase) {
            switch runtime {
            case .disabled, .stopped, .suspending, .suspended:
                break
            case let .enabled(_, engine):
                switch phase {
                case .active:
                    engine.start()
                case .background:
                    scheduleBackgroundSync()
                    engine.stop()
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
        }

        func handleRemoteNotification() {
            switch runtime {
            case .disabled, .stopped, .suspending, .suspended:
                break
            case let .enabled(_, engine):
                scheduleBackgroundSync()
                engine.start()
                engine.handleRemoteNotification()
            }
        }

        func prepareForSuspension() async {
            switch runtime {
            case .disabled:
                runtime = .suspended
            case let .stopped(_, engine):
                let task = Task { @MainActor in
                    await engine.prepareForSuspend()
                }
                runtime = .suspending(task)
                await task.value
                runtime = .suspended
            case let .enabled(_, engine):
                scheduleBackgroundSync()
                let task = Task { @MainActor in
                    await engine.prepareForSuspend()
                }
                runtime = .suspending(task)
                await task.value
                runtime = .suspended
            case let .suspending(task):
                await task.value
            case .suspended:
                break
            }
        }

        func performRemoteNotificationSync() async -> SyncEngine.BackgroundSyncResult {
            switch runtime {
            case .disabled, .stopped, .suspending, .suspended:
                return .unavailable
            case let .enabled(_, engine):
                return await engine.runBackgroundSyncCycle()
            }
        }
    }

    // MARK: - Background Sync

    final class iOSBackgroundSyncExpiration: @unchecked Sendable {
        let storeGate = AppStoreOpenGate()
        let cancellation = AppBackgroundTaskCancellation()

        func expireAndDrain() {
            cancellation.cancel()
            storeGate.expireAndDrain()
        }
    }

    fileprivate enum iOSBackgroundSyncRunProtection {
        case uiLease(AppBackgroundTaskLease)
        case systemTask
    }

    private enum iOSBackgroundSyncRequestProtection {
        case requiresUIKitLease
        case systemTask
    }

    private enum iOSBackgroundSyncReservation {
        case uiLease(AppBackgroundTaskLease)
        case systemTask
        case unavailable
    }

    final class iOSBackgroundSyncRun: @unchecked Sendable {
        let id: UUID
        let resultTask: Task<UIBackgroundFetchResult, Never>
        let operationTask: Task<UIBackgroundFetchResult, Never>
        private let expiration: iOSBackgroundSyncExpiration
        private let protection: iOSBackgroundSyncRunProtection

        fileprivate init(
            id: UUID,
            resultTask: Task<UIBackgroundFetchResult, Never>,
            operationTask: Task<UIBackgroundFetchResult, Never>,
            expiration: iOSBackgroundSyncExpiration,
            protection: iOSBackgroundSyncRunProtection
        ) {
            self.id = id
            self.resultTask = resultTask
            self.operationTask = operationTask
            self.expiration = expiration
            self.protection = protection
        }

        func expireAndDrain() {
            expiration.expireAndDrain()
        }

        @MainActor
        func endProtection() {
            switch protection {
            case let .uiLease(lease):
                lease.end()
            case .systemTask:
                break
            }
        }
    }

    private enum iOSHeadlessStoreOpenOutcome: @unchecked Sendable {
        case opened(store: ClipKittyRust.ClipboardStore, plan: StoreBootstrapPlan)
        case failed(String)
    }

    private enum iOSHeadlessIndexRepairOutcome: @unchecked Sendable {
        case notNeeded
        case processed(itemCount: UInt64, outcome: IndexMaintenanceOutcome)
        case processingFailed(itemCount: UInt64, message: String)
        case queueFailed(String)
    }

    @MainActor
    final class iOSBackgroundSyncRunner {
        static let shared = iOSBackgroundSyncRunner()

        private let logger = Logger(subsystem: "com.clipkitty", category: "SyncBackground")
        private let headlessSyncOperation: (@MainActor () async -> UIBackgroundFetchResult)?

        private enum InFlightSync {
            case none
            case running(iOSBackgroundSyncRun)
        }

        private enum StoreAuthority {
            case available
            case foreground(UUID)
        }

        private var inFlightSync: InFlightSync = .none
        private var storeAuthority: StoreAuthority = .available

        init(headlessSyncOperation: (@MainActor () async -> UIBackgroundFetchResult)? = nil) {
            self.headlessSyncOperation = headlessSyncOperation
        }

        func performRemoteNotificationSync() async -> UIBackgroundFetchResult {
            await performSync(
                named: "ClipKitty iCloud Sync",
                protection: .requiresUIKitLease
            )
        }

        func performScheduledSync() async -> UIBackgroundFetchResult {
            await performSync(
                named: "ClipKitty Scheduled iCloud Sync",
                protection: .systemTask
            )
        }

        func cancelInFlightSync() {
            switch inFlightSync {
            case .none:
                break
            case let .running(run):
                run.expireAndDrain()
                run.endProtection()
            }
        }

        func claimForegroundStore(_ claimID: UUID) {
            storeAuthority = .foreground(claimID)
            cancelInFlightSync()
        }

        func releaseForegroundStore(_ claimID: UUID) {
            switch storeAuthority {
            case .available:
                break
            case let .foreground(currentID) where currentID == claimID:
                storeAuthority = .available
            case .foreground:
                break
            }
        }

        private func performSync(
            named name: String,
            protection: iOSBackgroundSyncRequestProtection
        ) async -> UIBackgroundFetchResult {
            await beginSync(named: name, protection: protection).resultTask.value
        }

        func beginScheduledSync() -> iOSBackgroundSyncRun {
            beginSync(
                named: "ClipKitty Scheduled iCloud Sync",
                protection: .systemTask
            )
        }

        private func beginSync(
            named name: String,
            protection requestProtection: iOSBackgroundSyncRequestProtection
        ) -> iOSBackgroundSyncRun {
            switch storeAuthority {
            case .available:
                break
            case .foreground:
                return unavailableRun()
            }

            switch inFlightSync {
            case .none:
                break
            case let .running(run):
                return run
            }

            if headlessSyncOperation == nil {
                switch UIApplication.shared.applicationState {
                case .background:
                    break
                case .active, .inactive:
                    return unavailableRun()
                @unknown default:
                    return unavailableRun()
                }
            }

            let syncID = UUID()
            let expiration = iOSBackgroundSyncExpiration()
            let reservation: iOSBackgroundSyncReservation
            switch requestProtection {
            case .requiresUIKitLease:
                switch AppBackgroundTaskLease.acquire(
                    named: name,
                    onExpiration: { expiration.expireAndDrain() }
                ) {
                case let .granted(lease):
                    reservation = .uiLease(lease)
                case .unavailable:
                    reservation = .unavailable
                }
            case .systemTask:
                reservation = .systemTask
            }

            let operationTask: Task<UIBackgroundFetchResult, Never>
            let resultTask: Task<UIBackgroundFetchResult, Never>
            switch reservation {
            case let .uiLease(lease):
                operationTask = Task { @MainActor in
                    await self.runHeadlessSyncIfEnabled(gate: expiration.storeGate)
                }
                expiration.cancellation.install { operationTask.cancel() }
                resultTask = Task { @MainActor in
                    let result = await operationTask.value
                    lease.end()
                    self.finish(runID: syncID)
                    return result
                }
            case .systemTask:
                operationTask = Task { @MainActor in
                    await self.runHeadlessSyncIfEnabled(gate: expiration.storeGate)
                }
                expiration.cancellation.install { operationTask.cancel() }
                resultTask = Task { @MainActor in
                    let result = await operationTask.value
                    self.finish(runID: syncID)
                    return result
                }
            case .unavailable:
                expiration.expireAndDrain()
                operationTask = Task { .failed }
                resultTask = Task { @MainActor in
                    let result = await operationTask.value
                    self.finish(runID: syncID)
                    return result
                }
            }

            let runProtection: iOSBackgroundSyncRunProtection
            switch reservation {
            case let .uiLease(lease):
                runProtection = .uiLease(lease)
            case .systemTask, .unavailable:
                runProtection = .systemTask
            }

            let run = iOSBackgroundSyncRun(
                id: syncID,
                resultTask: resultTask,
                operationTask: operationTask,
                expiration: expiration,
                protection: runProtection
            )
            inFlightSync = .running(run)
            return run
        }

        private func unavailableRun() -> iOSBackgroundSyncRun {
            let expiration = iOSBackgroundSyncExpiration()
            expiration.expireAndDrain()
            let result = Task<UIBackgroundFetchResult, Never> { .failed }
            return iOSBackgroundSyncRun(
                id: UUID(),
                resultTask: result,
                operationTask: result,
                expiration: expiration,
                protection: .systemTask
            )
        }

        private func finish(runID: UUID) {
            switch inFlightSync {
            case .none:
                break
            case let .running(run) where run.id == runID:
                inFlightSync = .none
            case .running:
                break
            }
        }

        private func runHeadlessSyncIfEnabled(
            gate: AppStoreOpenGate
        ) async -> UIBackgroundFetchResult {
            guard case .start = gate.begin() else { return .failed }

            if let headlessSyncOperation {
                // Injected test operations do not own a real store. Mark the
                // resource gate complete before their first suspension point
                // so synchronous cancellation cannot wait on the main actor.
                gate.completeFailure()
                return await headlessSyncOperation()
            }

            if Task.isCancelled {
                gate.completeFailure()
                return .failed
            }

            guard iOSSettingsStore().syncEnabled else {
                logger.debug("Skipping background sync because iCloud sync is disabled")
                gate.completeFailure()
                return .noData
            }

            // Bootstrap performs synchronous SQLite and mmap work. Keep it off
            // the main actor so UIKit's expiration callback can seal the gate
            // and synchronously wait for this exact open to register or fail.
            let openOutcome = await Task.detached(priority: .utility) {
                do {
                    DatabasePath.migrateIfNeeded()
                    let dbPath = try DatabasePath.resolve()
                    let plan = try inspectStoreBootstrap(dbPath: dbPath)
                    let store = try ClipKittyRust.ClipboardStore(dbPath: dbPath)
                    gate.register(store)
                    return iOSHeadlessStoreOpenOutcome.opened(store: store, plan: plan)
                } catch {
                    gate.completeFailure()
                    return iOSHeadlessStoreOpenOutcome.failed(error.localizedDescription)
                }
            }.value

            switch openOutcome {
            case let .opened(store, plan):
                guard !Task.isCancelled else {
                    gate.expireAndDrain()
                    return .failed
                }
                return await runOpenedHeadlessSync(store: store, plan: plan, gate: gate)
            case let .failed(message):
                logger.error("Background sync bootstrap failed: \(message)")
                return .failed
            }
        }

        private func runOpenedHeadlessSync(
            store: ClipKittyRust.ClipboardStore,
            plan: StoreBootstrapPlan,
            gate: AppStoreOpenGate
        ) async -> UIBackgroundFetchResult {
            defer { gate.expireAndDrain() }

            let repairOutcome = await Task.detached(priority: .utility) {
                do {
                    switch try iOSIndexMaintenance.queueBootstrapRepairIfNeeded(
                        plan: plan,
                        store: store
                    ) {
                    case .notNeeded:
                        return iOSHeadlessIndexRepairOutcome.notNeeded
                    case let .queued(itemCount):
                        do {
                            let outcome = try iOSIndexMaintenance.processQueuedBatch(store: store)
                            return .processed(itemCount: itemCount, outcome: outcome)
                        } catch {
                            return .processingFailed(
                                itemCount: itemCount,
                                message: error.localizedDescription
                            )
                        }
                    }
                } catch {
                    return .queueFailed(error.localizedDescription)
                }
            }.value

            switch repairOutcome {
            case .notNeeded:
                break
            case let .processed(itemCount, outcome):
                logger.info("Queued background index repair for \(itemCount) items")
                logIndexMaintenanceOutcome(outcome)
            case let .processingFailed(itemCount, message):
                logger.info("Queued background index repair for \(itemCount) items")
                logger.error("Background index maintenance failed: \(message)")
            case let .queueFailed(message):
                logger.error("Background sync bootstrap failed: \(message)")
                return .failed
            }

            guard !Task.isCancelled else { return .failed }

            var contentChanged = false
            let engine = SyncEngine(store: store)
            engine.onContentChanged = {
                contentChanged = true
            }

            let result = await engine.runBackgroundSyncCycle()
            switch result {
            case .completed:
                logger.info("Background sync completed")
                return contentChanged ? .newData : .noData
            case .unavailable:
                logger.info("Background sync skipped because iCloud is unavailable")
                return .noData
            case let .failed(reason):
                logger.error("Background sync failed: \(reason)")
                return .failed
            }
        }

        private func logIndexMaintenanceOutcome(_ outcome: IndexMaintenanceOutcome) {
            switch outcome {
            case let .completed(processed):
                logger.info("Background index maintenance completed after \(processed) items")
            case let .moreRemaining(processed, remaining):
                logger.info(
                    "Background index maintenance processed \(processed) items; \(remaining) remain"
                )
            }
        }
    }

    enum iOSBackgroundSyncTaskKind: CaseIterable {
        case appRefresh
        case processing

        var identifier: String {
            switch self {
            case .appRefresh:
                return "com.eviljuliette.clipkitty.sync.refresh"
            case .processing:
                return "com.eviljuliette.clipkitty.sync.processing"
            }
        }
    }

    final class iOSBackgroundTaskCompletion: @unchecked Sendable {
        private enum State {
            case pending
            case completed
        }

        private let lock = NSLock()
        private var state: State = .pending
        private let task: BGTask

        init(task: BGTask) {
            self.task = task
        }

        func finish(success: Bool) {
            lock.lock()
            guard case .pending = state else {
                lock.unlock()
                return
            }
            state = .completed
            lock.unlock()
            task.setTaskCompleted(success: success)
        }
    }

    @MainActor
    final class iOSBackgroundSyncScheduler {
        static let shared = iOSBackgroundSyncScheduler()

        private let logger = Logger(subsystem: "com.clipkitty", category: "SyncBackground")
        private var registeredKinds: Set<iOSBackgroundSyncTaskKind> = []

        private init() {}

        func register() {
            for kind in iOSBackgroundSyncTaskKind.allCases {
                register(kind: kind)
            }
        }

        func scheduleAll() {
            for kind in iOSBackgroundSyncTaskKind.allCases {
                schedule(kind: kind)
            }
        }

        func schedule(kind: iOSBackgroundSyncTaskKind) {
            let request: BGTaskRequest
            switch kind {
            case .appRefresh:
                let refresh = BGAppRefreshTaskRequest(identifier: kind.identifier)
                refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
                request = refresh
            case .processing:
                let processing = BGProcessingTaskRequest(identifier: kind.identifier)
                processing.requiresNetworkConnectivity = true
                processing.requiresExternalPower = false
                processing.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
                request = processing
            }

            do {
                try BGTaskScheduler.shared.submit(request)
                logger.debug("Scheduled background sync task \(kind.identifier)")
            } catch {
                logger.error("Failed to schedule background sync task \(kind.identifier): \(error.localizedDescription)")
            }
        }

        private func register(kind: iOSBackgroundSyncTaskKind) {
            guard !registeredKinds.contains(kind) else { return }

            let accepted = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: kind.identifier,
                using: nil
            ) { task in
                let completion = iOSBackgroundTaskCompletion(task: task)
                let launchExpiration = AppBackgroundTaskCancellation()
                task.expirationHandler = {
                    launchExpiration.cancel()
                    completion.finish(success: false)
                }
                Task { @MainActor in
                    self.handle(
                        kind: kind,
                        completion: completion,
                        launchExpiration: launchExpiration
                    )
                }
            }

            if accepted {
                registeredKinds.insert(kind)
                logger.debug("Registered background sync task \(kind.identifier)")
            } else {
                logger.error("Failed to register background sync task \(kind.identifier)")
            }
        }

        private func handle(
            kind: iOSBackgroundSyncTaskKind,
            completion: iOSBackgroundTaskCompletion,
            launchExpiration: AppBackgroundTaskCancellation
        ) {
            schedule(kind: kind)

            let run = iOSBackgroundSyncRunner.shared.beginScheduledSync()
            launchExpiration.install {
                run.expireAndDrain()
            }
            Task { @MainActor in
                let result = await run.resultTask.value
                switch result {
                case .newData, .noData:
                    completion.finish(success: true)
                case .failed:
                    completion.finish(success: false)
                @unknown default:
                    completion.finish(success: false)
                }
            }
        }
    }

    @MainActor
    final class iOSRemoteNotificationBridge {
        static let shared = iOSRemoteNotificationBridge()

        private let logger = Logger(subsystem: "com.clipkitty", category: "SyncPush")
        private weak var coordinator: iOSSyncCoordinator?
        private var pendingRemoteNotification = false

        private init() {}

        func bind(coordinator: iOSSyncCoordinator) {
            self.coordinator = coordinator
            guard pendingRemoteNotification else { return }
            pendingRemoteNotification = false
            Task {
                _ = await coordinator.performRemoteNotificationSync()
            }
        }

        func registerForRemoteNotifications() {
            UIApplication.shared.registerForRemoteNotifications()
        }

        func handleRemoteNotification() async -> UIBackgroundFetchResult {
            iOSBackgroundSyncScheduler.shared.schedule(kind: .processing)

            if let coordinator {
                let result = await coordinator.performRemoteNotificationSync()
                let fetchResult = result.backgroundFetchResult
                switch fetchResult {
                case .newData, .noData:
                    iOSBackgroundSyncScheduler.shared.schedule(kind: .appRefresh)
                case .failed:
                    pendingRemoteNotification = true
                    iOSBackgroundSyncScheduler.shared.schedule(kind: .processing)
                @unknown default:
                    pendingRemoteNotification = true
                    iOSBackgroundSyncScheduler.shared.schedule(kind: .processing)
                }
                return fetchResult
            }

            logger.info("Handling remote sync notification with headless background sync")
            let result = await iOSBackgroundSyncRunner.shared.performRemoteNotificationSync()
            switch result {
            case .newData, .noData:
                iOSBackgroundSyncScheduler.shared.schedule(kind: .appRefresh)
            case .failed:
                pendingRemoteNotification = true
                iOSBackgroundSyncScheduler.shared.schedule(kind: .processing)
            @unknown default:
                pendingRemoteNotification = true
                iOSBackgroundSyncScheduler.shared.schedule(kind: .processing)
            }
            return result
        }

        func didRegisterForRemoteNotifications() {
            logger.info("Registered for remote sync notifications")
        }

        func didFailToRegisterForRemoteNotifications(error: Error) {
            logger.error("Failed to register for remote sync notifications: \(error.localizedDescription)")
        }
    }

    @MainActor
    final class iOSAppDelegate: NSObject, UIApplicationDelegate {
        func application(
            _: UIApplication,
            didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
        ) -> Bool {
            iOSBackgroundSyncScheduler.shared.register()
            return true
        }

        func application(
            _: UIApplication,
            didRegisterForRemoteNotificationsWithDeviceToken _: Data
        ) {
            Task { @MainActor in
                iOSRemoteNotificationBridge.shared.didRegisterForRemoteNotifications()
            }
        }

        func application(
            _: UIApplication,
            didFailToRegisterForRemoteNotificationsWithError error: Error
        ) {
            Task { @MainActor in
                iOSRemoteNotificationBridge.shared.didFailToRegisterForRemoteNotifications(error: error)
            }
        }

        func application(
            _: UIApplication,
            didReceiveRemoteNotification _: [AnyHashable: Any],
            fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
        ) {
            Task { @MainActor in
                let result = await iOSRemoteNotificationBridge.shared.handleRemoteNotification()
                completionHandler(result)
            }
        }
    }

    private extension SyncEngine.BackgroundSyncResult {
        var backgroundFetchResult: UIBackgroundFetchResult {
            switch self {
            case .completed:
                return .newData
            case .unavailable:
                return .noData
            case .failed:
                return .failed
            }
        }
    }

#endif
