import ClipKittyStore
import SwiftUI

struct TextComposerView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var appState
    @Environment(HapticsClient.self) private var haptics
    @Environment(\.dockedKeyboardInset) private var dockedKeyboardInset
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var saveRequestID: UUID?

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body)
                .padding()
                .padding(.bottom, dockedKeyboardInset)
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
                            startSavingText()
                        }
                        .disabled(!canSave || saveRequestID != nil)
                    }
                }
        }
        // Sheets are hosted separately from RootView, so they need their own
        // docked-only keyboard policy.
        .avoidsOnlyDockedKeyboard()
        .onDisappear {
            cancelSavingText()
        }
    }

    private func startSavingText() {
        guard saveRequestID == nil else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let requestID = UUID()
        saveRequestID = requestID
        let task = Task { @MainActor in
            await saveText(trimmed, requestID: requestID)
        }
        saveTask = task
        guard appState.registerForegroundTask(id: requestID, task: task) else {
            cancelSavingText()
            return
        }
    }

    private func saveText(_ text: String, requestID: UUID) async {
        defer { finishSavingText(requestID: requestID) }
        guard isCurrentSaveRequest(requestID) else { return }

        let result = await container.repository.saveText(
            text: text,
            sourceApp: "Manual",
            sourceAppBundleId: nil
        )
        if case .success = result {
            appState.refreshFeed()
        }
        guard isCurrentSaveRequest(requestID) else { return }

        switch result {
        case .success:
            haptics.fire(.success)
            appState.showToast(.addSucceeded)
            dismiss()
        case let .failure(error):
            haptics.fire(.destructive)
            appState.showToast(.addFailed(error.localizedDescription))
        }
    }

    private func isCurrentSaveRequest(_ requestID: UUID) -> Bool {
        !Task.isCancelled && saveRequestID == requestID
    }

    private func cancelSavingText() {
        saveRequestID = nil
        saveTask?.cancel()
        saveTask = nil
    }

    private func finishSavingText(requestID: UUID) {
        appState.finishForegroundTask(id: requestID)
        guard saveRequestID == requestID else { return }
        saveRequestID = nil
        saveTask = nil
    }
}
