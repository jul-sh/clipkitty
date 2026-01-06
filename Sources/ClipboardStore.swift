import Foundation
import AppKit
import Observation
import GRDB

@MainActor
@Observable
final class ClipboardStore {
    private(set) var items: [ClipboardItem] = []
    private(set) var isSearching: Bool = false
    private(set) var hasMore: Bool = true
    var panelRevision: Int = 0  // Incremented when panel opens to reset selection

    private var dbQueue: DatabaseQueue?
    private var lastChangeCount: Int = 0
    private var pollingTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    private let pageSize = 50
    private var currentOffset = 0

    var searchQuery: String = "" {
        didSet {
            if searchQuery != oldValue {
                debounceSearch()
            }
        }
    }

    var filteredItems: [ClipboardItem] {
        items
    }

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
        setupDatabase()
        loadInitialItems()
    }

    private func setupDatabase() {
        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDir = appSupport.appendingPathComponent("ClippySwift", isDirectory: true)

            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

            let dbPath = appDir.appendingPathComponent("clipboard.sqlite").path
            let config = Configuration()

            dbQueue = try DatabaseQueue(path: dbPath, configuration: config)

            try dbQueue?.write { db in
                // Main table for clipboard items
                try db.create(table: "items", ifNotExists: true) { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("content", .text).notNull()
                    t.column("contentHash", .text).notNull()
                    t.column("timestamp", .datetime).notNull()
                    t.column("sourceApp", .text)
                }

                // Index for fast duplicate checking and ordering
                try db.create(
                    index: "idx_items_hash",
                    on: "items",
                    columns: ["contentHash"],
                    ifNotExists: true
                )
                try db.create(
                    index: "idx_items_timestamp",
                    on: "items",
                    columns: ["timestamp"],
                    ifNotExists: true
                )

                // FTS5 virtual table for full-text search
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
                        content,
                        content=items,
                        content_rowid=id,
                        tokenize='porter unicode61'
                    )
                """)

                // Triggers to keep FTS in sync
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

            print("Database initialized at: \(dbPath)")
        } catch {
            print("Database setup failed: \(error)")
        }
    }

    private func loadInitialItems() {
        currentOffset = 0
        hasMore = true
        items = []
        loadMoreItems()
    }

    func loadMoreItems() {
        guard hasMore, !isSearching, searchQuery.isEmpty else { return }

        do {
            let newItems = try dbQueue?.read { db in
                try ClipboardItem
                    .order(Column("timestamp").desc)
                    .limit(pageSize, offset: currentOffset)
                    .fetchAll(db)
            } ?? []

            if newItems.count < pageSize {
                hasMore = false
            }

            items.append(contentsOf: newItems)
            currentOffset += newItems.count
        } catch {
            print("Failed to load items: \(error)")
        }
    }

    private func debounceSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            performSearch()
        }
    }

    private func performSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        if query.isEmpty {
            loadInitialItems()
            return
        }

        isSearching = true

        do {
            // Use FTS5 for fast full-text search
            let searchResults = try dbQueue?.read { db -> [ClipboardItem] in
                let pattern = query
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                    .map { "\($0)*" }
                    .joined(separator: " ")

                let sql = """
                    SELECT items.*
                    FROM items
                    JOIN items_fts ON items.id = items_fts.rowid
                    WHERE items_fts MATCH ?
                    ORDER BY bm25(items_fts), items.timestamp DESC
                    LIMIT 100
                """

                return try ClipboardItem.fetchAll(db, sql: sql, arguments: [pattern])
            } ?? []

            items = searchResults
            hasMore = false
        } catch {
            print("Search failed: \(error)")
            fallbackSearch(query: query)
        }

        isSearching = false
    }

    private func fallbackSearch(query: String) {
        do {
            let results = try dbQueue?.read { db in
                try ClipboardItem
                    .filter(Column("content").like("%\(query)%"))
                    .order(Column("timestamp").desc)
                    .limit(100)
                    .fetchAll(db)
            } ?? []

            items = results
        } catch {
            print("Fallback search failed: \(error)")
        }
    }

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

        guard let content = pasteboard.string(forType: .string),
              !content.isEmpty else { return }

        let hash = hashContent(content)

        // Check for duplicate
        do {
            let exists = try dbQueue?.read { db in
                try ClipboardItem
                    .filter(Column("contentHash") == hash)
                    .fetchOne(db)
            }

            if let existing = exists {
                // Move existing item to top by updating timestamp
                try dbQueue?.write { db in
                    try db.execute(
                        sql: "UPDATE items SET timestamp = ? WHERE id = ?",
                        arguments: [Date(), existing.id]
                    )
                }

                if searchQuery.isEmpty {
                    loadInitialItems()
                }
                return
            }
        } catch {
            print("Duplicate check failed: \(error)")
        }

        // Insert new item
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let item = ClipboardItem(content: content, sourceApp: sourceApp)

        do {
            try dbQueue?.write { db in
                try item.insert(db)
            }

            if searchQuery.isEmpty {
                items.insert(item, at: 0)
            }
        } catch {
            print("Failed to save clipboard item: \(error)")
        }
    }

    private func hashContent(_ string: String) -> String {
        var hasher = Hasher()
        hasher.combine(string)
        return String(hasher.finalize())
    }

    func paste(item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.content, forType: .string)
        lastChangeCount = pasteboard.changeCount

        if let id = item.id {
            do {
                try dbQueue?.write { db in
                    try db.execute(
                        sql: "UPDATE items SET timestamp = ? WHERE id = ?",
                        arguments: [Date(), id]
                    )
                }

                if searchQuery.isEmpty {
                    loadInitialItems()
                }
            } catch {
                print("Failed to update item timestamp: \(error)")
            }
        }
    }

    func delete(item: ClipboardItem) {
        guard let id = item.id else { return }

        do {
            try dbQueue?.write { db in
                try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [id])
            }

            items.removeAll { $0.id == id }
        } catch {
            print("Failed to delete item: \(error)")
        }
    }

    func clear() {
        do {
            try dbQueue?.write { db in
                try db.execute(sql: "DELETE FROM items")
                try db.execute(sql: "INSERT INTO items_fts(items_fts) VALUES('rebuild')")
            }

            items.removeAll()
            hasMore = false
        } catch {
            print("Failed to clear history: \(error)")
        }
    }

    func itemCount() -> Int {
        do {
            return try dbQueue?.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items") ?? 0
            } ?? 0
        } catch {
            return 0
        }
    }
}
