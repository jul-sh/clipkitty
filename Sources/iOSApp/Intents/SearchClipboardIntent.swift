import AppIntents
import ClipKittyRust
import ClipKittyShared

struct SearchClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Clipboard History"
    static var description: IntentDescription = "Search your ClipKitty clipboard history"

    @Parameter(title: "Search Query")
    var query: String

    @Parameter(title: "Filter", default: .all)
    var filter: ClipboardSearchFilter

    static var parameterSummary: some ParameterSummary {
        Summary("Search clipboard for \(\.$query)") {
            \.$filter
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let repository = try IntentAppContainer.repository

        let itemFilter: ItemQueryFilter = switch filter {
        case .all: .all
        case .bookmarks: .tagged(tag: .bookmark)
        case .text: .contentType(contentType: .text)
        case .images: .contentType(contentType: .images)
        case .links: .contentType(contentType: .links)
        case .colors: .contentType(contentType: .colors)
        }

        let outcome = await repository.search(
            query: query,
            filter: itemFilter,
            presentation: .card
        )

        switch outcome {
        case let .success(result):
            let count = result.totalCount
            let summary: String
            if count == 0 {
                summary = "No items found for \"\(query)\""
            } else {
                let topSnippets = result.matches.prefix(3)
                    .map { String($0.itemMetadata.snippet.prefix(80)) }
                    .joined(separator: "\n")
                summary = "Found \(count) item\(count == 1 ? "" : "s"):\n\(topSnippets)"
            }
            return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))

        case .cancelled:
            return .result(value: "Search was cancelled", dialog: "Search was cancelled")

        case let .failure(error):
            throw error
        }
    }
}
