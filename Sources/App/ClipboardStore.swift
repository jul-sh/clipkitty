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

    // MARK: - Initialization

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
        setupDatabase()
        loadItems(reset: true)
        pruneIfNeeded()
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

                try db.create(index: "idx_items_hash", on: "items", columns: ["contentHash"], ifNotExists: true)
                try db.create(index: "idx_items_timestamp", on: "items", columns: ["timestamp"], ifNotExists: true)

                // Use trigram tokenizer for fast substring matching
                // Drop old FTS table if it exists with different tokenizer
                try db.execute(sql: "DROP TABLE IF EXISTS items_fts")

                try db.execute(sql: """
                    CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
                        content, content=items, content_rowid=id, tokenize='trigram'
                    )
                """)

                // Rebuild FTS index with existing data
                try db.execute(sql: "INSERT INTO items_fts(items_fts) VALUES('rebuild')")

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

            // If it's a URL, fetch metadata asynchronously
            if ClipboardItem.isURL(text), let id = newItemId {
                await self?.fetchAndUpdateLinkMetadata(for: id, url: text)
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
            if let existing = try dbQueue.read({ db in
                try ClipboardItem.filter(Column("contentHash") == hash).fetchOne(db)
            }) {
                try dbQueue.write { db in
                    try db.execute(sql: "UPDATE items SET timestamp = ? WHERE id = ?", arguments: [Date(), existing.id])
                }
                return nil
            } else {
                return try dbQueue.write { db -> Int64 in
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
            Self.saveImageItemToDB(dbQueue: dbQueue, rawImageData: rawImageData, sourceApp: sourceApp)

            guard let self else { return }
            await MainActor.run { [weak self] in
                if case .loaded = self?.state {
                    self?.loadItems(reset: true)
                }
            }
        }
    }

    private nonisolated static func saveImageItemToDB(dbQueue: DatabaseQueue, rawImageData: Data, sourceApp: String?) {
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
            try dbQueue.write { db in
                let item = ClipboardItem(imageData: compressedData, sourceApp: sourceApp)
                try item.insert(db)
            }
        } catch {
            logError("Image save failed: \(error)")
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
}
