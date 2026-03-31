import ClipKittyRust
import Foundation

// MARK: - ClipboardError

enum ClipboardError: LocalizedError {
    case databaseInitFailed(underlying: Error)
    case databaseOperationFailed(operation: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .databaseInitFailed:
            return "Failed to initialize clipboard database"
        case let .databaseOperationFailed(operation, _):
            return "Database operation failed: \(operation)"
        }
    }
}

// MARK: - Search Operation

enum RepositorySearchOutcome {
    case success(SearchResult)
    case cancelled
    case failure(ClipboardError)
}

protocol ClipboardSearchOperation: AnyObject {
    func cancel()
    func awaitOutcome() async -> RepositorySearchOutcome
}

private final class RustClipboardSearchOperation: ClipboardSearchOperation {
    private let operation: ClipKittyRust.SearchOperation

    init(operation: ClipKittyRust.SearchOperation) {
        self.operation = operation
    }

    func cancel() {
        operation.cancel()
    }

    func awaitOutcome() async -> RepositorySearchOutcome {
        do {
            let outcome = try await operation.awaitResult()
            switch outcome {
            case let .success(result):
                return .success(result)
            case .cancelled:
                return .cancelled
            }
        } catch {
            return .failure(
                .databaseOperationFailed(operation: "search", underlying: error)
            )
        }
    }
}

// MARK: - Repository

func runRepositoryOperation<T: Sendable>(
    _ operation: String,
    on store: ClipKittyRust.ClipboardStore,
    body: @escaping @Sendable (ClipKittyRust.ClipboardStore) throws -> T
) async -> Result<T, ClipboardError> {
    do {
        let result = try await Task.detached(priority: .userInitiated) {
            try body(store)
        }.value
        return .success(result)
    } catch {
        return .failure(
            .databaseOperationFailed(operation: operation, underlying: error)
        )
    }
}

final class ClipboardRepository {
    let store: ClipKittyRust.ClipboardStore

    init(store: ClipKittyRust.ClipboardStore) {
        self.store = store
    }

    func databaseSize() async -> Result<Int64, ClipboardError> {
        await runRepositoryOperation("databaseSize", on: store) {
            $0.databaseSize()
        }
    }

    func startSearch(
        query: String,
        filter: ItemQueryFilter
    ) -> ClipboardSearchOperation {
        let operation = store.startSearch(query: query, filter: filter)
        return RustClipboardSearchOperation(operation: operation)
    }

    func fetchItem(id: String) async -> ClipboardItem? {
        let result = await runRepositoryOperation("fetchItem", on: store) {
            store in
            try store.fetchByIds(itemIds: [id])
        }
        if case let .success(items) = result {
            return items.first
        }
        return nil
    }

    func computeRowDecorations(
        itemIds: [String],
        query: String
    ) async -> [RowDecorationResult] {
        let result = await runRepositoryOperation(
            "computeRowDecorations",
            on: store
        ) { store in
            try store.computeRowDecorations(itemIds: itemIds, query: query)
        }
        if case let .success(decorations) = result {
            return decorations
        }
        return []
    }

    func loadPreviewPayload(
        itemId: String,
        query: String
    ) async -> PreviewPayload? {
        let result = await runRepositoryOperation(
            "loadPreviewPayload",
            on: store
        ) { store in
            try store.loadPreviewPayload(itemId: itemId, query: query)
        }
        if case let .success(payload) = result {
            return payload
        }
        return nil
    }

    func saveText(text: String) async -> Result<String, ClipboardError> {
        await runRepositoryOperation("saveText", on: store) { store in
            try store.saveText(
                text: text,
                sourceApp: nil,
                sourceAppBundleId: nil
            )
        }
    }

    func saveImage(imageData: Data) async -> Result<String, ClipboardError> {
        await runRepositoryOperation("saveImage", on: store) { store in
            try store.saveImage(
                imageData: imageData,
                thumbnail: nil,
                sourceApp: nil,
                sourceAppBundleId: nil,
                isAnimated: false
            )
        }
    }

    func addTag(
        itemId: String,
        tag: ItemTag
    ) async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("addTag", on: store) { store in
            try store.addTag(itemId: itemId, tag: tag)
        }
    }

    func removeTag(
        itemId: String,
        tag: ItemTag
    ) async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("removeTag", on: store) { store in
            try store.removeTag(itemId: itemId, tag: tag)
        }
    }

    func delete(itemId: String) async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("deleteItem", on: store) { store in
            try store.deleteItem(itemId: itemId)
        }
    }

    func clear() async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("clear", on: store) { store in
            try store.clear()
        }
    }
}
