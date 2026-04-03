import SwiftUI

/// Per-scene boundary view. Each iPad window gets its own SceneRoot,
/// which creates a scene-local SceneState while sharing the app-level AppContainer.
struct SceneRoot: View {
    let container: AppContainer

    #if ENABLE_SYNC
        let syncCoordinator: iOSSyncCoordinator?
    #endif

    @State private var sceneState: SceneState?
    @State private var sceneId = UUID()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let sceneState {
                rootContent(sceneState: sceneState)
            } else {
                Color.clear.onAppear {
                    sceneState = SceneState(container: container)
                }
            }
        }
        #if ENABLE_SYNC
            .onAppear {
                syncCoordinator?.handleScenePhaseChange(scenePhase, sceneId: sceneId)
            }
            .onChange(of: scenePhase) { _, newPhase in
                syncCoordinator?.handleScenePhaseChange(newPhase, sceneId: sceneId)
            }
        #endif
    }

    @ViewBuilder
    private func rootContent(sceneState: SceneState) -> some View {
        let base = WindowSceneReader { RootView() }
            .environment(container)
            .environment(sceneState)
            .environment(sceneState.viewModel)
            .environment(sceneState.router)
            .environment(container.settings)
            .environment(container.haptics)
            .onOpenURL { sceneState.router.handleURL($0) }

        #if ENABLE_SYNC
            if let syncCoordinator {
                base
                    .environment(syncCoordinator)
                    .onChange(of: syncCoordinator.contentChangeRevision) { _, _ in
                        sceneState.refreshFeed()
                    }
            } else {
                base
            }
        #else
            base
        #endif
    }
}
