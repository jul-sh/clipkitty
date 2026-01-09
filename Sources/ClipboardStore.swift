import Foundation
import AppKit
import Observation
import GRDB

/// Combined state for data display
enum DisplayState: Equatable {
    case loading
    case loaded(items: [ClipboardItem], hasMore: Bool)
    case searching(query: String, results: [ClipboardItem]?, isLoading: Bool)
    case error(String)

    var items: [ClipboardItem] {
        switch self {
        case .loaded(let items, _):
            return items
        case .searching(_, let results, _):
            return results ?? []
        default:
            return []
        }
    }

    var hasMore: Bool {
        if case .loaded(_, let more) = self { return more }
        return false
    }

    var isSearchLoading: Bool {
        if case .searching(_, _, let loading) = self { return loading }
        return false
    }

    var searchQuery: String {
        if case .searching(let query, _, _) = self { return query }
        return ""
    }
}

@MainActor
@Observable
final class ClipboardStore {
    // MARK: - State (Single Source of Truth)

    private(set) var state: DisplayState = .loading

    // MARK: - Derived Properties

    var items: [ClipboardItem] { state.items }
    var hasMore: Bool { state.hasMore }
    var isSearching: Bool { state.isSearchLoading }
    var searchQuery: String { state.searchQuery }

    // MARK: - Private State

    private var dbQueue: DatabaseQueue?
    private var lastChangeCount: Int = 0
    private var pollingTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var currentOffset = 0
    private let pageSize = 50

    // MARK: - Initialization

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
        setupDatabase()
        loadItems(reset: true)
        pruneIfNeeded()
    }

    // MARK: - Database Setup

    private func setupDatabase() {
        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDir = appSupport.appendingPathComponent("PaperTrail", isDirectory: true)
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

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
        let previousResults: [ClipboardItem]?
        if case .searching(_, let results, _) = state {
            previousResults = results
        } else {
            previousResults = state.items.isEmpty ? nil : state.items
        }

        state = .searching(query: query, results: previousResults, isLoading: true)

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
        loadItems(reset: true)
    }

    /// Fetch link metadata on-demand if not already loaded
    func fetchLinkMetadataIfNeeded(for item: ClipboardItem) {
        // Only fetch for links that don't have metadata yet
        guard item.contentType == .link,
              item.linkTitle == nil,
              item.linkImageData == nil,
              let id = item.id else { return }

        Task {
            await fetchAndUpdateLinkMetadata(for: id, url: item.content)
        }
    }

    // MARK: - Loading

    private func loadItems(reset: Bool) {
        if reset {
            currentOffset = 0
            state = .loading
        }

        do {
            let newItems = try dbQueue?.read { db in
                try ClipboardItem
                    .order(Column("timestamp").desc)
                    .limit(pageSize, offset: currentOffset)
                    .fetchAll(db)
            } ?? []

            let hasMore = newItems.count == pageSize
            currentOffset += newItems.count

            if reset {
                state = .loaded(items: newItems, hasMore: hasMore)
            } else if case .loaded(let existing, _) = state {
                state = .loaded(items: existing + newItems, hasMore: hasMore)
            }
        } catch {
            state = .error("Failed to load items: \(error.localizedDescription)")
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
        guard case .searching(let currentQuery, _, _) = state, currentQuery == query else { return }

        state = .searching(query: query, results: searchResults, isLoading: false)
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

        // Check for image data first
        if let imageData = getImageData(from: pasteboard) {
            saveImageItem(imageData: imageData)
            return
        }

        // Otherwise check for text
        guard let content = pasteboard.string(forType: .string), !content.isEmpty else { return }

        let hash = hashContent(content)

        do {
            if let existing = try dbQueue?.read({ db in
                try ClipboardItem.filter(Column("contentHash") == hash).fetchOne(db)
            }) {
                try dbQueue?.write { db in
                    try db.execute(sql: "UPDATE items SET timestamp = ? WHERE id = ?", arguments: [Date(), existing.id])
                }
            } else {
                let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
                var itemId: Int64?
                try dbQueue?.write { db in
                    let item = ClipboardItem(content: content, sourceApp: sourceApp)
                    try item.insert(db)
                    itemId = db.lastInsertedRowID
                }

                // If it's a URL, fetch metadata asynchronously
                if ClipboardItem.isURL(content), let id = itemId {
                    Task {
                        await fetchAndUpdateLinkMetadata(for: id, url: content)
                    }
                }
            }

            // Only reload if browsing (not searching)
            if case .loaded = state {
                loadItems(reset: true)
            }
        } catch {
            print("Clipboard save failed: \(error)")
        }
    }

    private func fetchAndUpdateLinkMetadata(for itemId: Int64, url: String) async {
        guard let metadata = await LinkMetadataFetcher.shared.fetch(url: url) else { return }
        guard let dbQueue else { return }

        // Store in local vars for nonisolated access
        let title = metadata.title
        let imageData = metadata.imageData

        // Database write needs to escape MainActor
        await Task.detached { [dbQueue] in
            do {
                try dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE items SET linkTitle = ?, linkImageData = ? WHERE id = ?",
                        arguments: [title, imageData, itemId]
                    )
                }
            } catch {
                print("Failed to update link metadata: \(error)")
            }
        }.value

        // Reload items to show updated metadata (already on MainActor)
        if case .loaded = state {
            loadItems(reset: true)
        }
    }

    private func getImageData(from pasteboard: NSPasteboard) -> Data? {
        // Check for image types
        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]

        for type in imageTypes {
            if let data = pasteboard.data(forType: type) {
                // Convert to compressed JPEG to save space
                if let image = NSImage(data: data),
                   let tiffData = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffData),
                   let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
                    return jpegData
                }
                return data
            }
        }
        return nil
    }

    private func saveImageItem(imageData: Data) {
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName

        // Create description for the image
        let description = "Image (\(imageData.count / 1024) KB)"

        do {
            try dbQueue?.write { db in
                let item = ClipboardItem(
                    content: description,
                    sourceApp: sourceApp,
                    contentType: .image,
                    imageData: imageData
                )
                try item.insert(db)
            }

            if case .loaded = state {
                loadItems(reset: true)
            }
        } catch {
            print("Image save failed: \(error)")
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
        pasteboard.setString(item.content, forType: .string)
        lastChangeCount = pasteboard.changeCount

        guard let id = item.id else { return }

        do {
            try dbQueue?.write { db in
                try db.execute(sql: "UPDATE items SET timestamp = ? WHERE id = ?", arguments: [Date(), id])
            }
            if case .loaded = state {
                loadItems(reset: true)
            }
        } catch {
            print("Failed to update timestamp: \(error)")
        }
    }

    func delete(item: ClipboardItem) {
        guard let id = item.id else { return }

        do {
            try dbQueue?.write { db in
                try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [id])
            }

            // Update state by filtering out deleted item
            switch state {
            case .loaded(let items, let hasMore):
                state = .loaded(items: items.filter { $0.id != id }, hasMore: hasMore)
            case .searching(let query, let results, let isLoading):
                state = .searching(query: query, results: results?.filter { $0.id != id }, isLoading: isLoading)
            default:
                break
            }
        } catch {
            print("Failed to delete: \(error)")
        }
    }

    func clear() {
        do {
            try dbQueue?.write { db in
                try db.execute(sql: "DELETE FROM items")
                try db.execute(sql: "INSERT INTO items_fts(items_fts) VALUES('rebuild')")
            }
            state = .loaded(items: [], hasMore: false)
        } catch {
            print("Failed to clear: \(error)")
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
            print("Pruning failed: \(error)")
        }
    }
}
