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
            case enabled(store: ClipKittyRust.ClipboardStore, engine: any SyncEngineProtocol)
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
            case .disabled:
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

            case let .enabled(store, engine):
                guard !enabled else { return }
                engine.stop()
                runtime = .disabled(store: store)
            }
        }

        func handleScenePhaseChange(_ phase: ScenePhase) {
            switch runtime {
            case .disabled:
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
            case .disabled:
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
                break
            case let .enabled(_, engine):
                scheduleBackgroundSync()
                await engine.prepareForSuspend()
            }
        }

        func performRemoteNotificationSync() async -> SyncEngine.BackgroundSyncResult {
            switch runtime {
            case .disabled:
                return .unavailable
            case let .enabled(_, engine):
                return await engine.runBackgroundSyncCycle()
            }
        }
    }

    // MARK: - Background Sync

    @MainActor
    enum iOSBackgroundTaskRunner {
        static func run<Result>(
            named name: String,
            operation: @escaping @MainActor () async -> Result
        ) async -> Result {
            let operationTask = Task { @MainActor in
                await operation()
            }
            return await run(named: name, operationTask: operationTask)
        }

        static func run<Result>(
            named name: String,
            operationTask: Task<Result, Never>
        ) async -> Result {
            await withTaskCancellationHandler {
                let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: name) {
                    operationTask.cancel()
                }

                let result = await operationTask.value
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
                return result
            } onCancel: {
                operationTask.cancel()
            }
        }
    }

    @MainActor
    final class iOSBackgroundSyncRunner {
        static let shared = iOSBackgroundSyncRunner()

        private let logger = Logger(subsystem: "com.clipkitty", category: "SyncBackground")
        private let headlessSyncOperation: (@MainActor () async -> UIBackgroundFetchResult)?

        private struct InFlightRun {
            let id: UUID
            let resultTask: Task<UIBackgroundFetchResult, Never>
            let operationTask: Task<UIBackgroundFetchResult, Never>
        }

        private enum InFlightSync {
            case none
            case running(InFlightRun)
        }

        private var inFlightSync: InFlightSync = .none

        init(headlessSyncOperation: (@MainActor () async -> UIBackgroundFetchResult)? = nil) {
            self.headlessSyncOperation = headlessSyncOperation
        }

        func performRemoteNotificationSync() async -> UIBackgroundFetchResult {
            await performSync(named: "ClipKitty iCloud Sync")
        }

        func performScheduledSync() async -> UIBackgroundFetchResult {
            await performSync(named: "ClipKitty Scheduled iCloud Sync")
        }

        func cancelInFlightSync() {
            switch inFlightSync {
            case .none:
                break
            case let .running(run):
                run.operationTask.cancel()
                run.resultTask.cancel()
            }
        }

        private func performSync(named name: String) async -> UIBackgroundFetchResult {
            switch inFlightSync {
            case .none:
                break
            case let .running(run):
                return await run.resultTask.value
            }

            let syncID = UUID()
            let operationTask = Task { @MainActor in
                await self.runHeadlessSyncIfEnabled()
            }
            let resultTask = Task { @MainActor in
                await iOSBackgroundTaskRunner.run(named: name, operationTask: operationTask)
            }
            inFlightSync = .running(
                InFlightRun(
                    id: syncID,
                    resultTask: resultTask,
                    operationTask: operationTask
                )
            )

            let result = await resultTask.value
            switch inFlightSync {
            case .none:
                break
            case let .running(run) where run.id == syncID:
                inFlightSync = .none
            case .running:
                break
            }
            return result
        }

        private func runHeadlessSyncIfEnabled() async -> UIBackgroundFetchResult {
            if let headlessSyncOperation {
                return await headlessSyncOperation()
            }

            if Task.isCancelled {
                return .failed
            }

            guard iOSSettingsStore().syncEnabled else {
                logger.debug("Skipping background sync because iCloud sync is disabled")
                return .noData
            }

            do {
                DatabasePath.migrateIfNeeded()
                let dbPath = try DatabasePath.resolve()
                let plan = try inspectStoreBootstrap(dbPath: dbPath)
                let store = try ClipKittyRust.ClipboardStore(dbPath: dbPath)
                defer { store.prepareForSuspend() }

                switch try iOSIndexMaintenance.queueBootstrapRepairIfNeeded(
                    plan: plan,
                    store: store
                ) {
                case .notNeeded:
                    break
                case let .queued(itemCount):
                    logger.info("Queued background index repair for \(itemCount) items")
                    do {
                        let outcome = try iOSIndexMaintenance.processQueuedBatch(store: store)
                        logIndexMaintenanceOutcome(outcome)
                    } catch {
                        logger.error("Background index maintenance failed: \(error.localizedDescription)")
                    }
                }

                if Task.isCancelled {
                    return .failed
                }

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
            } catch {
                logger.error("Background sync bootstrap failed: \(error.localizedDescription)")
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
                Task { @MainActor in
                    self.handle(task: task, kind: kind)
                }
            }

            if accepted {
                registeredKinds.insert(kind)
                logger.debug("Registered background sync task \(kind.identifier)")
            } else {
                logger.error("Failed to register background sync task \(kind.identifier)")
            }
        }

        private func handle(task: BGTask, kind: iOSBackgroundSyncTaskKind) {
            schedule(kind: kind)

            let operation = Task { @MainActor in
                let result = await iOSBackgroundSyncRunner.shared.performScheduledSync()
                switch result {
                case .newData, .noData:
                    task.setTaskCompleted(success: true)
                case .failed:
                    task.setTaskCompleted(success: false)
                @unknown default:
                    task.setTaskCompleted(success: false)
                }
            }

            task.expirationHandler = {
                operation.cancel()
                Task { @MainActor in
                    iOSBackgroundSyncRunner.shared.cancelInFlightSync()
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
