import SwiftUI

struct HistorySettingsSection: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var appState

    @State private var historyAction: HistoryAction = .idle

    enum HistoryAction {
        case idle
        case confirmingClear
        case clearing
        case failed(String)
    }

    var body: some View {
        Section("History") {
            switch historyAction {
            case .idle:
                Button("Clear History", role: .destructive) {
                    historyAction = .confirmingClear
                }
            case .confirmingClear:
                Button("Tap Again to Confirm", role: .destructive) {
                    Task { await clearHistory() }
                }
            case .clearing:
                HStack {
                    Text("Clearing...")
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            case let .failed(message):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Clear failed")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry", role: .destructive) {
                        Task { await clearHistory() }
                    }
                }
            }
        }
    }

    private func clearHistory() async {
        historyAction = .clearing
        let result = await container.storeClient.clear()
        switch result {
        case .success:
            historyAction = .idle
            appState.refreshFeed()
        case let .failure(error):
            historyAction = .failed(error.localizedDescription)
        }
    }
}
