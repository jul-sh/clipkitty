import ClipKittyRust
import Foundation

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
            return .failure(.databaseOperationFailed(operation: "search", underlying: error))
        }
    }
}

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
        return .failure(.databaseOperationFailed(operation: operation, underlying: error))
    }
}

final class ClipboardRepository {
    let store: ClipKittyRust.ClipboardStore

    init(store: ClipKittyRust.ClipboardStore) {
        self.store = store
    }

    func databaseSize() async -> Result<Int64, ClipboardError> {
        await runRepositoryOperation("databaseSize", on: store) { $0.databaseSize() }
    }

    func startSearch(query: String, filter: ItemQueryFilter) -> ClipboardSearchOperation {
        let operation = store.startSearch(query: query, filter: filter)
        return RustClipboardSearchOperation(operation: operation)
    }

    func search(query: String, filter: ItemQueryFilter) async -> RepositorySearchOutcome {
        await startSearch(query: query, filter: filter).awaitOutcome()
    }

    func fetchItem(id: String) async -> ClipboardItem? {
        let result = await runRepositoryOperation("fetchItem", on: store) { store in
            try store.fetchByIds(itemIds: [id])
        }
        if case let .success(items) = result {
            return items.first
        }
        return nil
    }

    func computeRowDecorations(itemIds: [String], query: String) async -> [RowDecorationResult] {
        let result = await runRepositoryOperation("computeRowDecorations", on: store) { store in
            try store.computeRowDecorations(itemIds: itemIds, query: query)
        }
        if case let .success(decorations) = result {
            return decorations
        }
        return []
    }

    func loadPreviewPayload(itemId: String, query: String) async -> PreviewPayload? {
        let result = await runRepositoryOperation("loadPreviewPayload", on: store) { store in
            try store.loadPreviewPayload(itemId: itemId, query: query)
        }
        if case let .success(payload) = result {
            return payload
        }
        return nil
    }

    func saveText(
        text: String,
        sourceApp: String?,
        sourceAppBundleId: String?
    ) async -> Result<String, ClipboardError> {
        await runRepositoryOperation("saveText", on: store) { store in
            try store.saveText(
                text: text,
                sourceApp: sourceApp,
                sourceAppBundleId: sourceAppBundleId
            )
        }
    }

    func saveImage(
        imageData: Data,
        thumbnail: Data?,
        sourceApp: String?,
        sourceAppBundleId: String?,
        isAnimated: Bool
    ) async -> Result<String, ClipboardError> {
        await runRepositoryOperation("saveImage", on: store) { store in
            try store.saveImage(
                imageData: imageData,
                thumbnail: thumbnail,
                sourceApp: sourceApp,
                sourceAppBundleId: sourceAppBundleId,
                isAnimated: isAnimated
            )
        }
    }

    func saveFiles(
        paths: [String],
        filenames: [String],
        fileSizes: [UInt64],
        utis: [String],
        bookmarkDataList: [Data],
        thumbnail: Data?,
        sourceApp: String?,
        sourceAppBundleId: String?
    ) async -> Result<String, ClipboardError> {
        await runRepositoryOperation("saveFiles", on: store) { store in
            try store.saveFiles(
                paths: paths,
                filenames: filenames,
                fileSizes: fileSizes,
                utis: utis,
                bookmarkDataList: bookmarkDataList,
                thumbnail: thumbnail,
                sourceApp: sourceApp,
                sourceAppBundleId: sourceAppBundleId
            )
        }
    }

    func updateTextItem(itemId: String, text: String) async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("updateTextItem", on: store) { store in
            try store.updateTextItem(itemId: itemId, text: text)
        }
    }

    func updateLinkMetadata(
        itemId: String,
        title: String?,
        description: String?,
        imageData: Data?
    ) async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("updateLinkMetadata", on: store) { store in
            try store.updateLinkMetadata(
                itemId: itemId,
                title: title,
                description: description,
                imageData: imageData
            )
        }
    }

    func updateImageDescription(itemId: String, description: String) async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("updateImageDescription", on: store) { store in
            try store.updateImageDescription(itemId: itemId, description: description)
        }
    }

    func updateTimestamp(itemId: String) async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("updateTimestamp", on: store) { store in
            try store.updateTimestamp(itemId: itemId)
        }
    }

    func addTag(itemId: String, tag: ItemTag) async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("addTag", on: store) { store in
            try store.addTag(itemId: itemId, tag: tag)
        }
    }

    func removeTag(itemId: String, tag: ItemTag) async -> Result<Void, ClipboardError> {
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

    func pruneToSize(maxBytes: Int64, keepRatio: Double) async -> Result<UInt64, ClipboardError> {
        await runRepositoryOperation("pruneToSize", on: store) { store in
            try store.pruneToSize(maxBytes: maxBytes, keepRatio: keepRatio)
        }
    }
}
