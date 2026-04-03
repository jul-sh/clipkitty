import ClipKittyRust
import ClipKittyShared
import SwiftUI

struct EditView: View {
    let itemId: String

    @Environment(AppContainer.self) private var container
    @Environment(BrowserViewModel.self) private var viewModel
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var originalText: String?
    @State private var isLoading = true

    private var hasChanges: Bool {
        guard let originalText else { return false }
        return text != originalText
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(String(localized: "Loading..."))
                } else {
                    TextEditor(text: $text)
                        .font(.body)
                        .padding()
                }
            }
            .navigationTitle(String(localized: "Edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        viewModel.discardCurrentEdit()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        viewModel.commitCurrentEdit()
                        appState.showToast(.saved)
                        dismiss()
                    }
                    .disabled(!hasChanges)
                }
            }
            .onChange(of: text) { _, newValue in
                if let originalText {
                    viewModel.onTextEdit(newValue, for: itemId, originalText: originalText)
                }
            }
            .task {
                await loadFullText()
            }
        }
    }

    private func loadFullText() async {
        if let item = await container.storeClient.fetchItem(id: itemId),
           case let .text(value) = item.content
        {
            originalText = value
            text = value
            viewModel.onEditingStateChange(true, for: itemId)
        } else {
            appState.showToast(.addFailed(String(localized: "Item not found")))
            dismiss()
        }
        isLoading = false
    }
}
