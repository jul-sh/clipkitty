import Foundation
import ClipKittyRust

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

    func search(query: String, filter: ItemQueryFilter) async -> Result<SearchResult, ClipboardError> {
        do {
            if filter == .all {
                return .success(try await store.search(query: query))
            }
            return .success(try await store.searchFiltered(query: query, filter: filter))
        } catch {
            return .failure(.databaseOperationFailed(operation: "search", underlying: error))
        }
    }

    func fetchItem(id: Int64) async -> ClipboardItem? {
        let result = await runRepositoryOperation("fetchItem", on: store) { store in
            try store.fetchByIds(itemIds: [id])
        }
        if case .success(let items) = result {
            return items.first
        }
        return nil
    }

    func computeHighlights(itemIds: [Int64], query: String) -> [MatchData] {
        (try? store.computeHighlights(itemIds: itemIds, query: query)) ?? []
    }

    func saveText(
        text: String,
        sourceApp: String?,
        sourceAppBundleId: String?
    ) async -> Result<Int64, ClipboardError> {
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
    ) async -> Result<Int64, ClipboardError> {
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
    ) async -> Result<Int64, ClipboardError> {
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

    func saveEditedText(text: String) async -> Result<Int64, ClipboardError> {
        await runRepositoryOperation("saveEditedText", on: store) { store in
            try store.saveText(
                text: text,
                sourceApp: "ClipKitty",
                sourceAppBundleId: Bundle.main.bundleIdentifier
            )
        }
    }

    func updateLinkMetadata(
        itemId: Int64,
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

    func updateImageDescription(itemId: Int64, description: String) async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("updateImageDescription", on: store) { store in
            try store.updateImageDescription(itemId: itemId, description: description)
        }
    }

    func updateTimestamp(itemId: Int64) async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("updateTimestamp", on: store) { store in
            try store.updateTimestamp(itemId: itemId)
        }
    }

    func addTag(itemId: Int64, tag: ItemTag) async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("addTag", on: store) { store in
            try store.addTag(itemId: itemId, tag: tag)
        }
    }

    func removeTag(itemId: Int64, tag: ItemTag) async -> Result<Void, ClipboardError> {
        await runRepositoryOperation("removeTag", on: store) { store in
            try store.removeTag(itemId: itemId, tag: tag)
        }
    }

    func delete(itemId: Int64) async -> Result<Void, ClipboardError> {
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
