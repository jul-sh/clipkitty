import AppIntents
import ClipKittyShared

struct AddClipboardItemIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Clipboard History"
    static var description: IntentDescription = "Add text to your ClipKitty clipboard history"

    @Parameter(title: "Text")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to clipboard history")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let repository = try IntentAppContainer.repository

        let result = await repository.saveText(
            text: text,
            sourceApp: "Shortcuts",
            sourceAppBundleId: nil
        )

        switch result {
        case .success:
            return .result(dialog: "Added to ClipKitty")
        case let .failure(error):
            throw error
        }
    }
}
