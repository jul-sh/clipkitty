import CloudKit
import SwiftUI

@main
struct ClipKittyiOSApp: App {
    @StateObject private var store = iOSClipboardStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                store.handleBecameActive()
            case .background:
                store.handleEnteredBackground()
            default:
                break
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: iOSClipboardStore

    var body: some View {
        switch store.lifecycle {
        case .initializing:
            ProgressView("Loading...")
        case .rebuildingIndex:
            VStack(spacing: 12) {
                ProgressView()
                Text("Rebuilding search index...")
                    .foregroundStyle(.secondary)
            }
        case .ready:
            ClipboardListView()
        case let .failed(message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Failed to load")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}
