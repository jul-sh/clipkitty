import Foundation
import AppKit
import Observation
import GRDB
import ClipKittyCore

/// Search result state - makes loading/results states explicit
enum SearchResultState: Equatable {
    case loading(previousResults: [ClipboardItem])
    case results([ClipboardItem])
}

/// Combined state for data display
enum DisplayState: Equatable {
    case loading
    case loaded(items: [ClipboardItem], hasMore: Bool)
    case searching(query: String, state: SearchResultState)
    case error(String)
}

@MainActor
@Observable
final class ClipboardStore {
    // MARK: - State (Single Source of Truth)

    private(set) var state: DisplayState = .loading

    // MARK: - Derived Properties

    // MARK: - Private State

    private var dbQueue: DatabaseQueue?
    private var lastChangeCount: Int = 0
    private var pollingTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var currentOffset = 0
    private let pageSize = 50

    /// Increments each time the display is reset - views observe this to reset local state
    private(set) var displayVersion: Int = 0
    
    /// Callback when a new item is added locally (set by AppDelegate to trigger sync)
    var onItemAdded: (@Sendable (Int64, Int) -> Void)?

    // MARK: - Initialization

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
        setupDatabase()
        loadItems(reset: true)
        pruneIfNeeded()
        verifyFTSIntegrityAsync()
    }

    /// Check FTS index integrity in background and rebuild if needed
    private func verifyFTSIntegrityAsync() {
        guard let dbQueue else { return }
        Task.detached {
            do {
                let needsRebuild = try dbQueue.read { db -> Bool in
                    let itemCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items") ?? 0
                    let ftsCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items_fts") ?? 0
                    return itemCount != ftsCount
                }
                if needsRebuild {
                    try dbQueue.write { db in
                        try db.execute(sql: "INSERT INTO items_fts(items_fts) VALUES('rebuild')")
                    }
                }
            } catch {
                logError("FTS integrity check failed: \(error)")
            }
        }
    }

    /// Current database size in bytes (cached, updated async)
    private(set) var databaseSizeBytes: Int64 = 0

    /// Refresh database size asynchronously
    func refreshDatabaseSize() {
        guard let dbQueue else { return }
        Task.detached {
            let size = Self.fetchDatabaseSize(dbQueue: dbQueue)
            await MainActor.run { [weak self] in
                self?.databaseSizeBytes = size
            }
        }
    }

    private nonisolated static func fetchDatabaseSize(dbQueue: DatabaseQueue) -> Int64 {
        do {
            return try dbQueue.read { db -> Int64 in
                let pageCount = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
                let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
                return pageCount * pageSize
            }
        } catch {
            return 0
        }
    }

    // MARK: - Database Setup

    private func setupDatabase() {
        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDir = appSupport.appendingPathComponent("ClipKitty", isDirectory: true)
            let legacyDir = appSupport.appendingPathComponent("PaperTrail", isDirectory: true)

            if FileManager.default.fileExists(atPath: legacyDir.path),
               !FileManager.default.fileExists(atPath: appDir.path) {
                try FileManager.default.moveItem(at: legacyDir, to: appDir)
            } else {
                try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            }

            let dbPath = appDir.appendingPathComponent("clipboard.sqlite").path
            dbQueue = try DatabaseQueue(path: dbPath, configuration: Configuration())

            try dbQueue?.write { db in
                try db.create(table: "items", ifNotExists: true) { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("content", .text).notNull()
                    t.column("contentHash", .text).notNull()
                    t.column("timestamp", .datetime).notNull()
                    t.column("sourceApp", .text)
                    t.column("contentType", .text).defaults(to: "text")
                    t.column("imageData", .blob)
                    t.column("linkTitle", .text)
                    t.column("linkImageData", .blob)
                }

                // Migration: Add new columns if they don't exist
                let columns = try db.columns(in: "items").map { $0.name }
                if !columns.contains("contentType") {
                    try db.execute(sql: "ALTER TABLE items ADD COLUMN contentType TEXT DEFAULT 'text'")
                }
                if !columns.contains("imageData") {
                    try db.execute(sql: "ALTER TABLE items ADD COLUMN imageData BLOB")
                }
                if !columns.contains("linkTitle") {
                    try db.execute(sql: "ALTER TABLE items ADD COLUMN linkTitle TEXT")
                }
                if !columns.contains("linkImageData") {
                    try db.execute(sql: "ALTER TABLE items ADD COLUMN linkImageData BLOB")
                }
                
                // Sync columns
                if !columns.contains("syncRecordID") {
                    try db.execute(sql: "ALTER TABLE items ADD COLUMN syncRecordID TEXT")
                }
                if !columns.contains("syncStatus") {
                    try db.execute(sql: "ALTER TABLE items ADD COLUMN syncStatus TEXT DEFAULT 'local'")
                }
                if !columns.contains("modifiedAt") {
                    try db.execute(sql: "ALTER TABLE items ADD COLUMN modifiedAt REAL")
                }
                if !columns.contains("deviceID") {
                    try db.execute(sql: "ALTER TABLE items ADD COLUMN deviceID TEXT")
                }

                try db.create(index: "idx_items_hash", on: "items", columns: ["contentHash"], ifNotExists: true)
                try db.create(index: "idx_items_timestamp", on: "items", columns: ["timestamp"], ifNotExists: true)
                try db.create(index: "idx_items_sync", on: "items", columns: ["syncStatus"], ifNotExists: true)
                try db.create(index: "idx_items_syncRecordID", on: "items", columns: ["syncRecordID"], ifNotExists: true)

                // Use trigram tokenizer for fast substring matching
                // Just ensure table exists - integrity check runs async after startup
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
                        content, content=items, content_rowid=id, tokenize='trigram'
                    )
                """)

                try db.execute(sql: """
                    CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
                        INSERT INTO items_fts(rowid, content) VALUES (new.id, new.content);
                    END
                """)
                try db.execute(sql: """
                    CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
                        INSERT INTO items_fts(items_fts, rowid, content) VALUES('delete', old.id, old.content);
                    END
                """)
                try db.execute(sql: """
                    CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE ON items BEGIN
                        INSERT INTO items_fts(items_fts, rowid, content) VALUES('delete', old.id, old.content);
                        INSERT INTO items_fts(rowid, content) VALUES (new.id, new.content);
                    END
                """)
            }
        } catch {
            state = .error("Database setup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Public API

    func setSearchQuery(_ newQuery: String) {
        let query = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        searchTask?.cancel()

        if query.isEmpty {
            loadItems(reset: true)
            return
        }

        // Preserve previous results while loading new ones
        let previousResults: [ClipboardItem] = {
            switch state {
            case .loaded(let items, _):
                return items
            case .searching(_, let searchState):
                switch searchState {
                case .loading(let previous):
                    return previous
                case .results(let results):
                    return results
                }
            default:
                return []
            }
        }()

        state = .searching(query: query, state: .loading(previousResults: previousResults))

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await performSearch(query: query)
        }
    }

    func loadMoreItems() {
        guard case .loaded(_, true) = state else { return }
        loadItems(reset: false)
    }

    func resetForDisplay() {
        searchTask?.cancel()
        displayVersion += 1
        loadItems(reset: true)
    }

    /// Reset selection state for a new display session (called on show)
    func prepareForDisplay() {
        searchTask?.cancel()
        displayVersion += 1
    }

    /// Fetch link metadata on-demand if not already loaded
    func fetchLinkMetadataIfNeeded(for item: ClipboardItem) {
        // Only fetch for links with pending metadata
        guard case .link(let url, let metadataState) = item.content,
              case .pending = metadataState,
              let id = item.id else { return }

        Task {
            await fetchAndUpdateLinkMetadata(for: id, url: url)
        }
    }

    // MARK: - Loading

    private func loadItems(reset: Bool) {
        let offset: Int
        let existingItems: [ClipboardItem]

        // Extract current items from any state to preserve during refresh
        let currentItems: [ClipboardItem] = {
            switch state {
            case .loaded(let items, _):
                return items
            case .searching(_, let searchState):
                switch searchState {
                case .loading(let previous):
                    return previous
                case .results(let results):
                    return results
                }
            default:
                return []
            }
        }()

        if reset {
            currentOffset = 0
            offset = 0
            existingItems = []
            // Only show loading spinner if we have no cached items to display
            if currentItems.isEmpty {
                state = .loading
            }
            // Otherwise keep showing current items - they'll be replaced when load completes
        } else {
            offset = currentOffset
            if case .loaded(let items, _) = state {
                existingItems = items
            } else {
                existingItems = []
            }
        }

        guard let dbQueue else { return }
        let pageSizeCopy = pageSize
        Task.detached {
            let result = Self.fetchItems(dbQueue: dbQueue, pageSize: pageSizeCopy, offset: offset)

            await MainActor.run { [weak self] in
                switch result {
                case .success(let (newItems, hasMore)):
                    self?.currentOffset = offset + newItems.count
                    if reset {
                        self?.state = .loaded(items: newItems, hasMore: hasMore)
                    } else {
                        self?.state = .loaded(items: existingItems + newItems, hasMore: hasMore)
                    }
                case .failure(let error):
                    self?.state = .error("Failed to load items: \(error.localizedDescription)")
                }
            }
        }
    }

    private nonisolated static func fetchItems(dbQueue: DatabaseQueue, pageSize: Int, offset: Int) -> Result<([ClipboardItem], Bool), Error> {
        do {
            let newItems = try dbQueue.read { db in
                try ClipboardItem
                    .order(Column("timestamp").desc)
                    .limit(pageSize, offset: offset)
                    .fetchAll(db)
            }
            let hasMore = newItems.count == pageSize
            return .success((newItems, hasMore))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Search

    private func performSearch(query: String) async {
        guard let dbQueue else {
            state = .error("Database not available")
            return
        }

        let searchResults = await Task.detached { [query] () -> [ClipboardItem] in
            // FTS5 trigram tokenizer requires at least 3 characters
            // For shorter queries, use LIKE search directly
            if query.count < 3 {
                do {
                    return try dbQueue.read { db in
                        try ClipboardItem
                            .filter(Column("content").like("%\(query)%"))
                            .order(Column("timestamp").desc)
                            .limit(200)
                            .fetchAll(db)
                    }
                } catch {
                    return []
                }
            }

            do {
                return try dbQueue.read { db in
                    // Use FTS5 trigram MATCH for fast substring search
                    // Escape special FTS5 characters and wrap in quotes for literal matching
                    let escapedQuery = query.replacingOccurrences(of: "\"", with: "\"\"")

                    // Use raw SQL to join with FTS5 virtual table
                    let sql = """
                        SELECT items.* FROM items
                        INNER JOIN items_fts ON items.id = items_fts.rowid
                        WHERE items_fts MATCH ?
                        ORDER BY items.timestamp DESC
                        LIMIT 200
                    """
                    return try ClipboardItem.fetchAll(db, sql: sql, arguments: ["\"\(escapedQuery)\""])
                }
            } catch {
                // Fallback to LIKE if FTS fails for any other reason
                do {
                    return try dbQueue.read { db in
                        try ClipboardItem
                            .filter(Column("content").like("%\(query)%"))
                            .order(Column("timestamp").desc)
                            .limit(200)
                            .fetchAll(db)
                    }
                } catch {
                    return []
                }
            }
        }.value

        // Only update if still searching for this query
        guard case .searching(let currentQuery, _) = state, currentQuery == query else { return }

        state = .searching(query: query, state: .results(searchResults))
    }

    // MARK: - Clipboard Monitoring

    func startMonitoring() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkForChanges()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stopMonitoring() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func checkForChanges() {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // Skip concealed/sensitive content (e.g. passwords from 1Password, Bitwarden)
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        if pasteboard.data(forType: concealedType) != nil {
            return
        }

        // Check for image data first - get raw data only, defer compression
        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]
        for type in imageTypes {
            if let rawData = pasteboard.data(forType: type) {
                saveImageItem(rawImageData: rawData)
                return
            }
        }

        // Otherwise check for text
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }

        let hash = hashContent(text)
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName

        // Move all DB operations to background
        guard let dbQueue else { return }
        Task.detached { [weak self] in
            let newItemId = Self.saveTextItem(dbQueue: dbQueue, text: text, hash: hash, sourceApp: sourceApp)

            if let id = newItemId {
                // Trigger sync if enabled
                let size = text.utf8.count
                await self?.onItemAdded?(id, size)
                
                // If it's a URL, fetch metadata asynchronously
                if ClipboardItem.isURL(text) {
                    await self?.fetchAndUpdateLinkMetadata(for: id, url: text)
                }
            }

            // Reload on main actor if browsing
            guard let self else { return }
            await MainActor.run { [weak self] in
                if case .loaded = self?.state {
                    self?.loadItems(reset: true)
                }
            }
        }
    }

    private nonisolated static func saveTextItem(dbQueue: DatabaseQueue, text: String, hash: String, sourceApp: String?) -> Int64? {
        do {
            return try dbQueue.write { db -> Int64? in
                if let existing = try ClipboardItem.filter(Column("contentHash") == hash).fetchOne(db) {
                    try db.execute(sql: "UPDATE items SET timestamp = ? WHERE id = ?", arguments: [Date(), existing.id])
                    return nil
                } else {
                    let item = ClipboardItem(text: text, sourceApp: sourceApp)
                    try item.insert(db)
                    return db.lastInsertedRowID
                }
            }
        } catch {
            logError("Clipboard save failed: \(error)")
            return nil
        }
    }

    private func fetchAndUpdateLinkMetadata(for itemId: Int64, url: String) async {
        guard let dbQueue else { return }

        let metadata = await LinkMetadataFetcher.shared.fetch(url: url)

        // Store in local vars for nonisolated access
        // If metadata is nil, we still need to update DB to mark as "failed" (empty title/image)
        let (title, imageData) = metadata?.databaseFields ?? ("", nil)

        // Database write needs to escape MainActor
        await Task.detached { [dbQueue] in
            do {
                try dbQueue.write { db in
                    // Use empty string for title to distinguish "failed" from "pending" (NULL)
                    // NULL = pending, empty string = failed/no metadata, non-empty = loaded
                    try db.execute(
                        sql: "UPDATE items SET linkTitle = ?, linkImageData = ? WHERE id = ?",
                        arguments: [title, imageData, itemId]
                    )
                }
            } catch {
                logError("Failed to update link metadata: \(error)")
            }
        }.value

        // Reload items to show updated metadata (already on MainActor)
        if case .loaded = state {
            loadItems(reset: true)
        }
    }

    private func saveImageItem(rawImageData: Data) {
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName

        // Move compression and DB write to background
        guard let dbQueue else { return }
        Task.detached { [weak self] in
            if let result = Self.saveImageItemToDB(dbQueue: dbQueue, rawImageData: rawImageData, sourceApp: sourceApp) {
                await self?.onItemAdded?(result.id, result.size)
            }

            guard let self else { return }
            await MainActor.run { [weak self] in
                if case .loaded = self?.state {
                    self?.loadItems(reset: true)
                }
            }
        }
    }

    private nonisolated static func saveImageItemToDB(dbQueue: DatabaseQueue, rawImageData: Data, sourceApp: String?) -> (id: Int64, size: Int)? {
        // Compress image
        let compressedData: Data
        if let image = NSImage(data: rawImageData),
           let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
            compressedData = jpegData
        } else {
            compressedData = rawImageData
        }

        do {
            return try dbQueue.write { db -> (id: Int64, size: Int) in
                let item = ClipboardItem(imageData: compressedData, sourceApp: sourceApp)
                try item.insert(db)
                return (db.lastInsertedRowID, compressedData.count)
            }
        } catch {
            logError("Image save failed: \(error)")
            return nil
        }
    }

    private func hashContent(_ string: String) -> String {
        var hasher = Hasher()
        hasher.combine(string)
        return String(hasher.finalize())
    }

    // MARK: - Actions

    func paste(item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.textContent, forType: .string)
        lastChangeCount = pasteboard.changeCount

        guard let id = item.id else { return }

        // Defer database operations to avoid blocking clipboard availability
        Task.detached { [dbQueue] in
            do {
                try dbQueue?.write { db in
                    try db.execute(sql: "UPDATE items SET timestamp = ? WHERE id = ?", arguments: [Date(), id])
                }
            } catch {
                logError("Failed to update timestamp: \(error)")
            }
        }

        if case .loaded = state {
            loadItems(reset: true)
        }
    }

    func delete(item: ClipboardItem) {
        guard let id = item.id else { return }

        // Update UI immediately
        switch state {
        case .loaded(let items, let hasMore):
            state = .loaded(items: items.filter { $0.id != id }, hasMore: hasMore)
        case .searching(let query, let searchState):
            let newState: SearchResultState
            switch searchState {
            case .loading(let previous):
                newState = .loading(previousResults: previous.filter { $0.id != id })
            case .results(let results):
                newState = .results(results.filter { $0.id != id })
            }
            state = .searching(query: query, state: newState)
        default:
            break
        }

        // Perform DB delete in background
        Task.detached { [dbQueue] in
            do {
                try dbQueue?.write { db in
                    try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [id])
                }
            } catch {
                logError("Failed to delete: \(error)")
            }
        }
    }

    func clear() {
        // Update UI immediately
        state = .loaded(items: [], hasMore: false)

        // Perform expensive DB operations in background
        Task.detached { [dbQueue] in
            do {
                try dbQueue?.write { db in
                    try db.execute(sql: "DELETE FROM items")
                    try db.execute(sql: "INSERT INTO items_fts(items_fts) VALUES('rebuild')")
                }
            } catch {
                logError("Failed to clear: \(error)")
            }
        }
    }

    // MARK: - Pruning

    func pruneIfNeeded() {
        let maxSizeMB = AppSettings.shared.maxDatabaseSizeMB
        guard maxSizeMB > 0, let dbQueue else { return }

        let maxBytes = Int64(maxSizeMB) * 1024 * 1024

        Task.detached {
            self.performPruning(maxBytes: maxBytes, dbQueue: dbQueue)
        }
    }

    private nonisolated func performPruning(maxBytes: Int64, dbQueue: DatabaseQueue) {
        do {
            let currentSize = try dbQueue.read { db -> Int64 in
                let pageCount = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
                let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
                return pageCount * pageSize
            }

            guard currentSize > maxBytes else { return }

            let count = try dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items") ?? 0
            }
            guard count > 0 else { return }

            let avgItemSize = currentSize / Int64(count)
            let targetSize = Int64(Double(maxBytes) * 0.8)
            let itemsToDelete = max(100, Int((currentSize - targetSize) / avgItemSize))

            try dbQueue.write { db in
                try db.execute(sql: """
                    DELETE FROM items WHERE id IN (
                        SELECT id FROM items ORDER BY timestamp ASC LIMIT ?
                    )
                """, arguments: [itemsToDelete])
                try db.execute(sql: "INSERT INTO items_fts(items_fts) VALUES('rebuild')")
            }

            try dbQueue.vacuum()
        } catch {
            logError("Pruning failed: \(error)")
        }
    }
    
    // MARK: - Sync Operations
    
    /// Get items pending sync that are under the size limit
    func getPendingSyncItems(maxSize: Int) async -> [SyncableClipboardItem] {
        guard let dbQueue else { return [] }
        
        do {
            return try await dbQueue.read { db -> [SyncableClipboardItem] in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM items 
                    WHERE syncStatus = 'pending'
                    ORDER BY timestamp DESC
                    LIMIT 100
                """)
                    
                    return rows.compactMap { row -> SyncableClipboardItem? in
                        guard let item = try? ClipboardItem(row: row) else { return nil }
                        
                        // Estimate size and skip large items
                        var size = item.textContent.utf8.count
                        if case .image(let data, _) = item.content {
                            size += data.count
                        }
                        if case .link(_, let metadata) = item.content {
                            if let imageData = metadata.imageData {
                                size += imageData.count
                            }
                        }
                        guard size <= maxSize else { return nil }
                        
                        return SyncableClipboardItem(
                            item: item,
                            syncRecordID: row["syncRecordID"],
                            syncStatus: SyncStatus.from(databaseValue: row["syncStatus"]),
                            modifiedAt: row["modifiedAt"] ?? item.timestamp,
                            deviceID: row["deviceID"]
                        )
                }
            }
        } catch {
            logError("Failed to get pending sync items: \(error)")
            return []
        }
    }
    
    /// Mark an item as synced after successful push to CloudKit
    /// Note: recordID is derived from contentHash in this implementation
    func markItemAsSynced(recordID: String) async {
        guard let dbQueue else { return }

        let deviceID = SyncableClipboardItem.currentDeviceID
        let now = Date()

        await Task.detached {
            do {
                try dbQueue.write { db in
                    // recordID equals contentHash in our implementation (see toCKRecord)
                    try db.execute(
                        sql: """
                            UPDATE items
                            SET syncStatus = 'synced', syncRecordID = ?, modifiedAt = ?, deviceID = ?
                            WHERE contentHash = ?
                        """,
                        arguments: [recordID, now, deviceID, recordID]
                    )
                }
            } catch {
                logError("Failed to mark item as synced: \(error)")
            }
        }.value
    }
    
    /// Insert or update an item from CloudKit
    /// Uses last-writer-wins conflict resolution based on modifiedAt timestamp
    func upsertFromCloud(syncableItem: SyncableClipboardItem) async {
        guard let dbQueue else { return }

        let item = syncableItem.item
        let recordID = syncableItem.syncRecordID
        let remoteModifiedAt = syncableItem.modifiedAt
        let remoteDeviceID = syncableItem.deviceID

        await Task.detached {
            do {
                try dbQueue.write { db in
                    // Check if item exists by contentHash
                    let existing = try Row.fetchOne(
                        db,
                        sql: "SELECT id, modifiedAt, deviceID, syncStatus FROM items WHERE contentHash = ?",
                        arguments: [item.contentHash]
                    )

                    if let existing = existing {
                        // Item exists - apply last-writer-wins based on timestamp only
                        let localModifiedAt = existing["modifiedAt"] as? Date ?? Date.distantPast
                        let localStatus = existing["syncStatus"] as? String

                        // Only update if remote is strictly newer
                        // If local is pending (has local changes), prefer local unless remote is newer
                        let shouldUpdate: Bool
                        if localStatus == "pending" {
                            // Local has uncommitted changes - only overwrite if remote is newer
                            shouldUpdate = remoteModifiedAt > localModifiedAt
                        } else {
                            // Local is synced or local-only - update if remote is newer or equal
                            // (equal handles the case where this is our own upload coming back)
                            shouldUpdate = remoteModifiedAt >= localModifiedAt
                        }

                        if shouldUpdate {
                            try db.execute(
                                sql: """
                                    UPDATE items SET
                                        timestamp = ?,
                                        modifiedAt = ?,
                                        syncRecordID = ?,
                                        syncStatus = 'synced',
                                        deviceID = ?
                                    WHERE contentHash = ?
                                """,
                                arguments: [item.timestamp, remoteModifiedAt, recordID, remoteDeviceID, item.contentHash]
                            )
                        }
                    } else {
                        // New item from cloud - insert it
                        var newItem = item
                        try newItem.insert(db)

                        // Update sync fields
                        if let id = newItem.id {
                            try db.execute(
                                sql: "UPDATE items SET syncRecordID = ?, syncStatus = 'synced', modifiedAt = ?, deviceID = ? WHERE id = ?",
                                arguments: [recordID, remoteModifiedAt, remoteDeviceID, id]
                            )
                        }
                    }
                }
            } catch {
                logError("Failed to upsert from cloud: \(error)")
            }
        }.value

        // Reload items on main thread
        if case .loaded = state {
            loadItems(reset: true)
        }
    }
    
    /// Delete an item that was deleted from CloudKit
    func deleteFromCloud(syncRecordID: String) async {
        guard let dbQueue else { return }
        
        await Task.detached {
            do {
                try dbQueue.write { db in
                    try db.execute(
                        sql: "DELETE FROM items WHERE syncRecordID = ?",
                        arguments: [syncRecordID]
                    )
                }
            } catch {
                logError("Failed to delete from cloud: \(error)")
            }
        }.value
        
        // Reload items on main thread
        if case .loaded = state {
            loadItems(reset: true)
        }
    }
    
    /// Mark new items as pending sync when sync is enabled
    func markNewItemForSync(id: Int64, sizeBytes: Int) {
        let maxItemSize = Int(AppSettings.shared.maxSyncItemSizeMB * 1024 * 1024)
        guard AppSettings.shared.iCloudSyncEnabled,
              sizeBytes <= maxItemSize,
              let dbQueue else { return }
        
        let deviceID = SyncableClipboardItem.currentDeviceID
        
        Task.detached {
            do {
                try dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE items SET syncStatus = 'pending', modifiedAt = ?, deviceID = ? WHERE id = ?",
                        arguments: [Date(), deviceID, id]
                    )
                }
            } catch {
                logError("Failed to mark item for sync: \(error)")
            }
        }
    }
    
    /// Get the total size of all synced items in bytes
    func getSyncedLibrarySize() async -> Int64 {
        guard let dbQueue else { return 0 }
        
        return await Task.detached {
            do {
                return try dbQueue.read { db -> Int64 in
                    let rows = try Row.fetchAll(db, sql: "SELECT * FROM items WHERE syncStatus = 'synced'")
                    return rows.reduce(0) { total, row in
                        guard let item = try? ClipboardItem(row: row) else { return total }
                        var size = item.textContent.utf8.count
                        if case .image(let data, _) = item.content {
                            size += data.count
                        }
                        if case .link(_, let metadata) = item.content {
                            if let imageData = metadata.imageData {
                                size += imageData.count
                            }
                        }
                        return total + Int64(size)
                    }
                }
            } catch {
                logError("Failed to calculate synced library size: \(error)")
                return 0
            }
        }.value
    }
    
    /// Delete oldest synced items until total size is within limit
    func pruneSyncedLibrary(maxSizeBytes: Int64) async {
        guard let dbQueue else { return }
        
        await Task.detached {
            do {
                try dbQueue.write { db in
                    // This is a bit complex without a dedicated size column, 
                    // so we'll fetch all synced items ordered by timestamp
                    let rows = try Row.fetchAll(db, sql: "SELECT * FROM items WHERE syncStatus = 'synced' ORDER BY timestamp ASC")
                    
                    var currentTotalSize: Int64 = 0
                    var itemsToKeep: [Int64] = []
                    
                    // We go backwards (newest first) to see what to keep
                    let reversedRows = rows.reversed()
                    for row in reversedRows {
                        guard let item = try? ClipboardItem(row: row) else { continue }
                        var size = item.textContent.utf8.count
                        if case .image(let data, _) = item.content {
                            size += data.count
                        }
                        if case .link(_, let metadata) = item.content {
                            if let imageData = metadata.imageData {
                                size += imageData.count
                            }
                        }
                        
                        if currentTotalSize + Int64(size) <= maxSizeBytes {
                            currentTotalSize += Int64(size)
                            if let id = row["id"] as? Int64 {
                                itemsToKeep.append(id)
                            }
                        } else {
                            // This item and all older items should be deleted (or marked as local-only)
                            // For simplicity, we delete them from cloud (remote deletion handled by engine)
                            if row["syncRecordID"] is String {
                                // We store recordIDs to be deleted from cloud by the engine
                                // but for now we just delete locally or mark as local
                                try db.execute(sql: "UPDATE items SET syncStatus = 'local', syncRecordID = NULL WHERE id = ?", arguments: [row["id"]])
                            }
                        }
                    }
                }
            } catch {
                logError("Synced library pruning failed: \(error)")
            }
        }.value
    }
}
