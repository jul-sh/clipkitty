#if ENABLE_ICLOUD_SYNC

    import ClipKittyAppleServices
    import ClipKittyRust
    import ClipKittyShared
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
                }
            )
        }

        init(
            store: ClipKittyRust.ClipboardStore,
            enabled: Bool,
            onContentChanged: @escaping () -> Void,
            engineFactory: @escaping (ClipKittyRust.ClipboardStore) -> any SyncEngineProtocol,
            registerForRemoteNotifications: @escaping () -> Void = {}
        ) {
            self.onContentChanged = onContentChanged
            self.engineFactory = engineFactory
            self.registerForRemoteNotifications = registerForRemoteNotifications
            if enabled {
                let engine = engineFactory(store)
                engine.onContentChanged = onContentChanged
                runtime = .enabled(store: store, engine: engine)
                registerForRemoteNotifications()
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
                case .background, .inactive:
                    engine.stop()
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
                engine.start()
                engine.handleRemoteNotification()
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
    final class iOSBackgroundSyncRunner {
        static let shared = iOSBackgroundSyncRunner()

        private let logger = Logger(subsystem: "com.clipkitty", category: "SyncBackground")
        private let timeout: TimeInterval = 25
        private var inFlightSync: Task<UIBackgroundFetchResult, Never>?

        private init() {}

        func performRemoteNotificationSync() async -> UIBackgroundFetchResult {
            if let inFlightSync {
                return await inFlightSync.value
            }

            let task = Task { @MainActor in
                await self.withTimeout {
                    await self.runHeadlessSyncIfEnabled()
                }
            }
            inFlightSync = task
            let result = await task.value
            inFlightSync = nil
            return result
        }

        private func runHeadlessSyncIfEnabled() async -> UIBackgroundFetchResult {
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

                if plan == .rebuildIndex {
                    logger.info("Rebuilding index before background sync")
                    try store.rebuildIndex()
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

        private func withTimeout(
            operation: @escaping @MainActor () async -> UIBackgroundFetchResult
        ) async -> UIBackgroundFetchResult {
            await withCheckedContinuation { continuation in
                let completion = BackgroundFetchCompletion(continuation)
                let timeout = self.timeout
                let operationTask = Task { @MainActor in
                    let result = await operation()
                    completion.resume(returning: result)
                }
                Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    operationTask.cancel()
                    completion.resume(returning: .failed)
                }
            }
        }
    }

    private final class BackgroundFetchCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false
        private let continuation: CheckedContinuation<UIBackgroundFetchResult, Never>

        init(_ continuation: CheckedContinuation<UIBackgroundFetchResult, Never>) {
            self.continuation = continuation
        }

        func resume(returning result: UIBackgroundFetchResult) {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return }
            didResume = true
            continuation.resume(returning: result)
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
            if let coordinator {
                let result = await coordinator.performRemoteNotificationSync()
                return result.backgroundFetchResult
            }

            logger.info("Handling remote sync notification with headless background sync")
            let result = await iOSBackgroundSyncRunner.shared.performRemoteNotificationSync()
            if result == .failed {
                pendingRemoteNotification = true
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

    final class iOSAppDelegate: NSObject, UIApplicationDelegate {
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
