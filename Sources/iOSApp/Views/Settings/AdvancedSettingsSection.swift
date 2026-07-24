import ClipKittyCore
import SwiftUI

struct AdvancedSettingsSection: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var appState

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? String(localized: "Unknown")
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? String(localized: "Unknown")
    }

    var body: some View {
        @Bindable var settings = container.settings

        SettingsAdvancedSection(
            limitGB: $settings.maxDatabaseSizeGB,
            loadUsedBytes: {
                switch await container.repository.databaseSize() {
                case let .success(usedBytes):
                    return .loaded(usedBytes: usedBytes)
                case let .failure(error):
                    return .failed(message: error.localizedDescription)
                }
            },
            pruneToLimit: {
                let result = await container.pruneToStorageLimit()
                appState.refreshFeed()
                switch result {
                case .success:
                    return .succeeded
                case let .failure(error):
                    return .failed(message: error.localizedDescription)
                }
            },
            clearHistory: {
                let result = await container.storeClient.clear()
                appState.refreshFeed()
                switch result {
                case .success:
                    return .succeeded
                case let .failure(error):
                    return .failed(message: error.localizedDescription)
                }
            },
            appVersion: appVersion,
            buildNumber: buildNumber,
            additionalContent: { EmptyView() },
            aboutAdditionalContent: { EmptyView() }
        )
    }
}
