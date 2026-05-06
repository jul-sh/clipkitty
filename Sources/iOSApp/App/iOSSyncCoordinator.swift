#if ENABLE_ICLOUD_SYNC

    import ClipKittyAppleServices
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
        func handleRemoteNotification()
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
            coordinator.handleRemoteNotification()
        }

        func registerForRemoteNotifications() {
            UIApplication.shared.registerForRemoteNotifications()
        }

        func handleRemoteNotification() -> Bool {
            guard let coordinator else {
                pendingRemoteNotification = true
                logger.info("Queued remote sync notification until bootstrap completes")
                return false
            }
            coordinator.handleRemoteNotification()
            return true
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
                let handled = iOSRemoteNotificationBridge.shared.handleRemoteNotification()
                completionHandler(handled ? .newData : .noData)
            }
        }
    }

#endif
