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
    /// Uses scene-ID tracking so that multiple iPad windows can independently
    /// transition between active/inactive without incorrectly stopping sync.
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
        private let engineFactory: (ClipKittyRust.ClipboardStore) -> any SyncEngineProtocol

        @ObservationIgnored
        private let onContentChangedCallback: () -> Void

        /// Tracks which scenes are currently active. Sync runs while at least one is active.
        @ObservationIgnored
        private var activeSceneIds: Set<UUID> = []

        /// Incremented when the sync engine reports content changes.
        /// Each scene observes this to trigger a feed refresh.
        var contentChangeRevision: Int = 0

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
            self.engineFactory = engineFactory
            self.onContentChangedCallback = onContentChanged

            if enabled {
                let engine = engineFactory(store)
                runtime = .enabled(store: store, engine: engine)
                // Wire after all stored properties are initialized so [weak self] is valid
                engine.onContentChanged = { [weak self] in
                    self?.contentChangeRevision += 1
                    onContentChanged()
                }
            } else {
                runtime = .disabled(store: store)
            }
        }

        func setSyncEnabled(_ enabled: Bool) {
            switch runtime {
            case let .disabled(store):
                guard enabled else { return }
                let engine = engineFactory(store)
                let callback = onContentChangedCallback
                engine.onContentChanged = { [weak self] in
                    self?.contentChangeRevision += 1
                    callback()
                }
                runtime = .enabled(store: store, engine: engine)
                if !activeSceneIds.isEmpty {
                    engine.start()
                }

            case let .enabled(store, engine):
                guard !enabled else { return }
                engine.stop()
                runtime = .disabled(store: store)
            }
        }

        /// Called by each `SceneRoot` with its stable scene ID when scene phase changes.
        func handleScenePhaseChange(_ phase: ScenePhase, sceneId: UUID) {
            switch phase {
            case .active:
                let wasEmpty = activeSceneIds.isEmpty
                activeSceneIds.insert(sceneId)
                if wasEmpty {
                    startEngineIfEnabled()
                }
            case .background, .inactive:
                let wasPresent = activeSceneIds.remove(sceneId) != nil
                if wasPresent && activeSceneIds.isEmpty {
                    stopEngineIfRunning()
                }
            @unknown default:
                break
            }
        }

        /// Legacy single-scene API — used by existing tests.
        /// Forwards to the scene-ID variant with a fixed UUID.
        func handleScenePhaseChange(_ phase: ScenePhase) {
            handleScenePhaseChange(phase, sceneId: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        }

        func handleRemoteNotification() {
            switch runtime {
            case .disabled:
                break
            case let .enabled(_, engine):
                engine.handleRemoteNotification()
            }
        }

        // MARK: - Private

        private func startEngineIfEnabled() {
            if case let .enabled(_, engine) = runtime {
                engine.start()
            }
        }

        private func stopEngineIfRunning() {
            if case let .enabled(_, engine) = runtime {
                engine.stop()
            }
        }
    }

#endif
