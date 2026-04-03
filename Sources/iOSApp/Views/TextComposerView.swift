import ClipKittyShared
import SwiftUI

struct TextComposerView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var appState
    @Environment(HapticsClient.self) private var haptics
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body)
                .padding()
                .navigationTitle(String(localized: "New Text"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Save")) {
                            Task { await saveText() }
                        }
                        .disabled(!canSave)
                    }
                }
        }
    }

    private func saveText() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let result = await container.repository.saveText(
            text: trimmed,
            sourceApp: "Manual",
            sourceAppBundleId: nil
        )

        switch result {
        case .success:
            haptics.fire(.success)
            appState.showToast(.addSucceeded)
            appState.refreshFeed()
            dismiss()
        case let .failure(error):
            haptics.fire(.destructive)
            appState.showToast(.addFailed(error.localizedDescription))
        }
    }
}
