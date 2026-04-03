#if ENABLE_SYNC

    import ClipKittyAppleServices
    import ClipKittyRust
    import SwiftUI

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
                engineFactory: { SyncEngine(store: $0) }
            )
        }

        init(
            store: ClipKittyRust.ClipboardStore,
            enabled: Bool,
            onContentChanged: @escaping () -> Void,
            engineFactory: @escaping (ClipKittyRust.ClipboardStore) -> any SyncEngineProtocol
        ) {
            self.onContentChanged = onContentChanged
            self.engineFactory = engineFactory
            if enabled {
                let engine = engineFactory(store)
                engine.onContentChanged = onContentChanged
                runtime = .enabled(store: store, engine: engine)
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
                engine.handleRemoteNotification()
            }
        }
    }

#endif
