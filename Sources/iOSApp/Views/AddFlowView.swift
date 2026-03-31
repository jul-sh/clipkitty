import ClipKittyShared
import PhotosUI
import SwiftUI
import UIKit

struct AddFlowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var mode: AddMode = .menu
    @State private var composedText: String = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .menu:
                    menuView
                case .composeText:
                    composeTextView
                }
            }
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .onChange(of: selectedPhoto) { _, newItem in
            guard let newItem else { return }
            Task {
                await importPhoto(from: newItem)
            }
        }
    }

    private var menuView: some View {
        List {
            Button {
                mode = .composeText
            } label: {
                Label("New Text", systemImage: "doc.text")
            }

            Button {
                Task { await pasteClipboard() }
            } label: {
                Label("Paste Current Clipboard", systemImage: "doc.on.clipboard")
            }

            PhotosPicker(
                selection: $selectedPhoto,
                matching: .images
            ) {
                Label("Import Photo", systemImage: "photo.badge.plus")
            }
        }
    }

    private var composeTextView: some View {
        TextEditor(text: $composedText)
            .padding()
            .navigationTitle("New Text")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        mode = .menu
                        composedText = ""
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveComposedText() }
                    }
                    .disabled(composedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
    }

    private func saveComposedText() async {
        let trimmed = composedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        let result = await appState.repository.saveText(
            text: trimmed,
            sourceApp: "ClipKitty",
            sourceAppBundleId: Bundle.main.bundleIdentifier
        )
        isSaving = false
        switch result {
        case .success:
            HapticFeedback.success()
            appState.showToast(.addSucceeded)
            appState.refreshFeed()
            dismiss()
        case let .failure(error):
            HapticFeedback.destructive()
            appState.showToast(.addFailed(error.localizedDescription))
        }
    }

    private func pasteClipboard() async {
        guard let clipboard = appState.clipboardService.readCurrentClipboard() else {
            appState.showToast(.addFailed("Clipboard is empty"))
            dismiss()
            return
        }

        isSaving = true
        let result: Result<String, ClipboardError>

        switch clipboard.type {
        case "image":
            guard let image = clipboard.content as? UIImage,
                  let data = image.pngData()
            else {
                isSaving = false
                appState.showToast(.addFailed("Could not read image data"))
                dismiss()
                return
            }
            let thumbnail = image.preparingThumbnail(of: CGSize(width: 200, height: 200))?.jpegData(
                compressionQuality: 0.7
            )
            result = await appState.repository.saveImage(
                imageData: data,
                thumbnail: thumbnail,
                sourceApp: "Pasteboard",
                sourceAppBundleId: nil,
                isAnimated: false
            )
        case "link":
            let urlString = (clipboard.content as? URL)?.absoluteString ?? "\(clipboard.content)"
            result = await appState.repository.saveText(
                text: urlString,
                sourceApp: "Pasteboard",
                sourceAppBundleId: nil
            )
        default:
            let text = "\(clipboard.content)"
            result = await appState.repository.saveText(
                text: text,
                sourceApp: "Pasteboard",
                sourceAppBundleId: nil
            )
        }

        isSaving = false
        switch result {
        case .success:
            HapticFeedback.success()
            appState.showToast(.addSucceeded)
            appState.refreshFeed()
        case let .failure(error):
            HapticFeedback.destructive()
            appState.showToast(.addFailed(error.localizedDescription))
        }
        dismiss()
    }

    private func importPhoto(from item: PhotosPickerItem) async {
        isSaving = true
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            isSaving = false
            appState.showToast(.addFailed("Could not load photo"))
            dismiss()
            return
        }

        let thumbnail: Data? = {
            guard let image = UIImage(data: data) else { return nil }
            return image.preparingThumbnail(of: CGSize(width: 200, height: 200))?.jpegData(
                compressionQuality: 0.7
            )
        }()

        let result = await appState.repository.saveImage(
            imageData: data,
            thumbnail: thumbnail,
            sourceApp: "Photos",
            sourceAppBundleId: nil,
            isAnimated: false
        )

        isSaving = false
        switch result {
        case .success:
            HapticFeedback.success()
            appState.showToast(.addSucceeded)
            appState.refreshFeed()
        case let .failure(error):
            HapticFeedback.destructive()
            appState.showToast(.addFailed(error.localizedDescription))
        }
        dismiss()
    }
}

private enum AddMode {
    case menu
    case composeText
}
