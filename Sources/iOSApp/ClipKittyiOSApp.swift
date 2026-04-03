import ClipKittyAppleServices
import ClipKittyRust
import ClipKittyShared
import SwiftUI

// MARK: - App Launch State

enum AppLaunchState {
    case launching
    case ready(AppContainer)
    case failed(String)
}

// MARK: - App Entry Point

@main
struct ClipKittyiOSApp: App {
    @State private var launchState: AppLaunchState = .launching

    #if ENABLE_SYNC
        @State private var syncCoordinator: iOSSyncCoordinator?
    #endif

    init() {
        FontManager.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            switch launchState {
            case .launching:
                ProgressView("Loading ClipKitty...")
                    .onAppear { performBootstrap() }

            case let .ready(container):
                sceneRoot(container: container)

            case let .failed(message):
                bootstrapFailureView(message: message)
            }
        }
    }

    @ViewBuilder
    private func sceneRoot(container: AppContainer) -> some View {
        #if ENABLE_SYNC
            SceneRoot(container: container, syncCoordinator: syncCoordinator)
        #else
            SceneRoot(container: container)
        #endif
    }

    private func performBootstrap() {
        switch AppContainer.bootstrap() {
        case let .success(container):
            #if ENABLE_SYNC
                let coordinator = iOSSyncCoordinator(
                    store: container.store,
                    enabled: container.settings.syncEnabled,
                    onContentChanged: {}
                )
                syncCoordinator = coordinator
            #endif

            launchState = .ready(container)
        case let .failure(error):
            launchState = .failed(error.localizedDescription)
        }
    }

    private func bootstrapFailureView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("ClipKitty couldn't start")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
