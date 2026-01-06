import Foundation
import AppKit
import Observation
import GRDB

/// Represents the current state of clipboard items display
enum ClipboardState: Equatable {
    case idle
    case loading
    case searching
    case loaded(items: [ClipboardItem], hasMore: Bool)
    case searchResults(items: [ClipboardItem], query: String)
    case error(String)

    var items: [ClipboardItem] {
        switch self {
        case .loaded(let items, _), .searchResults(let items, _):
            return items
        default:
            return []
        }
    }

    var isLoading: Bool {
        switch self {
        case .loading, .searching:
            return true
        default:
            return false
        }
    }

    var hasMore: Bool {
        if case .loaded(_, let hasMore) = self {
            return hasMore
        }
        return false
    }
}

@MainActor
@Observable
final class ClipboardStore {
    // MARK: - Public State (Single Source of Truth)

    private(set) var state: ClipboardState = .idle
    var searchQuery: String = "" {
        didSet {
            if searchQuery != oldValue {
                handleSearchQueryChange()
            }
        }
    }

    // MARK: - Derived Properties

    var items: [ClipboardItem] { state.items }
    var isSearching: Bool { state.isLoading }
    var hasMore: Bool { state.hasMore }

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
            let appDir = appSupport.appendingPathComponent("ClippySwift", isDirectory: true)
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
                }

                try db.create(index: "idx_items_hash", on: "items", columns: ["contentHash"], ifNotExists: true)
                try db.create(index: "idx_items_timestamp", on: "items", columns: ["timestamp"], ifNotExists: true)

                try db.execute(sql: """
                    CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
                        content, content=items, content_rowid=id, tokenize='porter unicode61'
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

    // MARK: - Loading

    func loadItems(reset: Bool = false) {
        guard !searchQuery.isEmpty == false else { return } // Don't load if searching

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

    func loadMoreItems() {
        guard case .loaded(_, true) = state, searchQuery.isEmpty else { return }
        loadItems(reset: false)
    }

    // MARK: - Search

    private func handleSearchQueryChange() {
        searchTask?.cancel()

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            loadItems(reset: true)
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await performSearch(query: query)
        }
    }

    private func performSearch(query: String) async {
        state = .searching

        let pattern = query
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { "\($0)*" }
            .joined(separator: " ")

        guard let dbQueue else {
            state = .error("Database not available")
            return
        }

        let searchResults = await Task.detached { [pattern, query] () -> Result<[ClipboardItem], Error> in
            // FTS search
            do {
                let results = try dbQueue.read { db -> [ClipboardItem] in
                    try ClipboardItem.fetchAll(db, sql: """
                        SELECT items.* FROM items
                        JOIN items_fts ON items.id = items_fts.rowid
                        WHERE items_fts MATCH ?
                        ORDER BY bm25(items_fts), items.timestamp DESC
                        LIMIT 100
                    """, arguments: [pattern])
                }
                return .success(results)
            } catch {
                // FTS failed, try LIKE fallback
                do {
                    let results = try dbQueue.read { db in
                        try ClipboardItem
                            .filter(Column("content").like("%\(query)%"))
                            .order(Column("timestamp").desc)
                            .limit(100)
                            .fetchAll(db)
                    }
                    return .success(results)
                } catch {
                    return .failure(error)
                }
            }
        }.value

        switch searchResults {
        case .success(let results):
            state = .searchResults(items: results, query: query)
        case .failure(let error):
            state = .error("Search failed: \(error.localizedDescription)")
        }
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

        guard let content = pasteboard.string(forType: .string), !content.isEmpty else { return }

        let hash = hashContent(content)

        do {
            if let existing = try dbQueue?.read({ db in
                try ClipboardItem.filter(Column("contentHash") == hash).fetchOne(db)
            }) {
                // Move to top
                try dbQueue?.write { db in
                    try db.execute(sql: "UPDATE items SET timestamp = ? WHERE id = ?", arguments: [Date(), existing.id])
                }
            } else {
                // Insert new
                let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
                try dbQueue?.write { db in
                    var item = ClipboardItem(content: content, sourceApp: sourceApp)
                    try item.insert(db)
                }
            }

            // Reload if not searching
            if searchQuery.isEmpty {
                loadItems(reset: true)
            }
        } catch {
            print("Clipboard save failed: \(error)")
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
            if searchQuery.isEmpty {
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

            // Update state immutably
            switch state {
            case .loaded(let items, let hasMore):
                state = .loaded(items: items.filter { $0.id != id }, hasMore: hasMore)
            case .searchResults(let items, let query):
                state = .searchResults(items: items.filter { $0.id != id }, query: query)
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

    func resetForDisplay() {
        searchQuery = ""
        loadItems(reset: true)
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
