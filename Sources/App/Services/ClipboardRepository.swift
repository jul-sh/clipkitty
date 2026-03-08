import Foundation
import ClipKittyRust

// MARK: - Clipboard Repository

/// Repository for clipboard data access wrapping the Rust store.
/// Pure data access layer with no UI state.
///
/// NOTE: This is the target architecture for service extraction.
/// Currently the ClipboardStore.swift contains this logic inline.
/// This file serves as documentation of the intended boundary.
actor ClipboardRepository {
    private let store: ClipKittyRust.ClipboardStore

    init(store: ClipKittyRust.ClipboardStore) {
        self.store = store
    }

    // MARK: - Fetch Operations

    func fetchItem(id: Int64) async throws -> ClipboardItem? {
        let items = try store.fetchByIds(itemIds: [id])
        return items.first
    }

    func fetchItems(ids: [Int64]) async throws -> [ClipboardItem] {
        try store.fetchByIds(itemIds: ids)
    }

    func search(query: String) async throws -> SearchResult {
        try await store.search(query: query)
    }

    func searchFiltered(query: String, filter: ContentTypeFilter) async throws -> SearchResult {
        try await store.searchFiltered(query: query, filter: filter)
    }

    // MARK: - Save Operations

    func saveText(text: String, sourceApp: String?, sourceAppBundleId: String?) throws -> Int64 {
        try store.saveText(text: text, sourceApp: sourceApp, sourceAppBundleId: sourceAppBundleId)
    }

    func saveImage(
        imageData: Data,
        thumbnail: Data?,
        sourceApp: String?,
        sourceAppBundleId: String?,
        isAnimated: Bool
    ) throws -> Int64 {
        try store.saveImage(
            imageData: imageData,
            thumbnail: thumbnail,
            sourceApp: sourceApp,
            sourceAppBundleId: sourceAppBundleId,
            isAnimated: isAnimated
        )
    }

    func saveFile(
        path: String,
        filename: String,
        fileSize: UInt64,
        uti: String,
        bookmarkData: Data,
        thumbnail: Data?,
        sourceApp: String?,
        sourceAppBundleId: String?
    ) throws -> Int64 {
        try store.saveFile(
            path: path,
            filename: filename,
            fileSize: fileSize,
            uti: uti,
            bookmarkData: bookmarkData,
            thumbnail: thumbnail,
            sourceApp: sourceApp,
            sourceAppBundleId: sourceAppBundleId
        )
    }

    // MARK: - Delete Operations

    func deleteItem(id: Int64) throws {
        try store.deleteItem(itemId: id)
    }

    func clear() throws {
        try store.clear()
    }

    // MARK: - Update Operations

    func updateTimestamp(itemId: Int64) throws {
        try store.updateTimestamp(itemId: itemId)
    }

    func updateLinkMetadata(itemId: Int64, title: String?, description: String?, imageData: Data?) throws {
        try store.updateLinkMetadata(itemId: itemId, title: title, description: description, imageData: imageData)
    }

    // MARK: - Store Statistics

    func databaseSize() -> Int64 {
        store.databaseSize()
    }
}
