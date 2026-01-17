import Foundation
import AppKit
import Observation
import GRDB
import ClipKittyCore
import os.signpost
import os.log
import ImageIO

// MARK: - Performance Tracing

private let performanceLog = OSLog(subsystem: "com.clipkitty.app", category: "Performance")
private let logger = Logger(subsystem: "com.clipkitty.app", category: "Performance")

private enum TraceID {
    static let loadItems = OSSignpostID(log: performanceLog)
    static let search = OSSignpostID(log: performanceLog)
    static let metadata = OSSignpostID(log: performanceLog)
}

/// Simple timing helper - uses os_log for reliable capture
private func measureTime<T>(_ label: String, _ block: () throws -> T) rethrows -> T {
    let start = CFAbsoluteTimeGetCurrent()
    let result = try block()
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
    os_log(.default, log: performanceLog, "%{public}s: %.2fms", label, elapsed)
    return result
}

private func measureTimeAsync<T>(_ label: String, _ block: () async throws -> T) async rethrows -> T {
    let start = CFAbsoluteTimeGetCurrent()
    let result = try await block()
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
    os_log(.default, log: performanceLog, "%{public}s: %.2fms", label, elapsed)
    return result
}

/// Calculate Levenshtein distance between two strings
private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
    let s1Array = Array(s1.lowercased())
    let s2Array = Array(s2.lowercased())
    let s1Len = s1Array.count
    let s2Len = s2Array.count

    guard s1Len > 0 else { return s2Len }
    guard s2Len > 0 else { return s1Len }

    var matrix = Array(repeating: Array(repeating: 0, count: s2Len + 1), count: s1Len + 1)

    for i in 0...s1Len {
        matrix[i][0] = i
    }
    for j in 0...s2Len {
        matrix[0][j] = j
    }

    for i in 1...s1Len {
        for j in 1...s2Len {
            let cost = s1Array[i - 1] == s2Array[j - 1] ? 0 : 1
            matrix[i][j] = min(
                matrix[i - 1][j] + 1,      // deletion
                matrix[i][j - 1] + 1,      // insertion
                matrix[i - 1][j - 1] + cost // substitution
            )
        }
    }

    return matrix[s1Len][s2Len]
}

/// Search result state - makes loading/results states explicit
enum SearchResultState: Equatable {
    case loading(previousResults: [ClipboardItem])
    case loadingMore(results: [ClipboardItem])  // Loading additional results via scroll
    case results([ClipboardItem], hasMore: Bool)
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

    // MARK: - Adaptive Polling State
    private var lastActivityTime: Date = Date()
    private var isSystemSleeping: Bool = false
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var searchTask: Task<Void, Never>?
    /// Cursor for keyset pagination - timestamp of the oldest loaded item
    private var oldestLoadedTimestamp: Date?
    /// Cursor for search pagination - timestamp of oldest search result
    private var oldestSearchTimestamp: Date?
    /// Current search query (for pagination continuity)
    private var currentSearchQuery: String = ""
    private let pageSize = 50
    private let searchPageSize = 50

    /// Increments each time the display is reset - views observe this to reset local state
    private(set) var displayVersion: Int = 0

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
                if !columns.contains("sourceAppBundleID") {
                    try db.execute(sql: "ALTER TABLE items ADD COLUMN sourceAppBundleID TEXT")
                }

                try db.create(index: "idx_items_hash", on: "items", columns: ["contentHash"], ifNotExists: true)
                try db.create(index: "idx_items_timestamp", on: "items", columns: ["timestamp"], ifNotExists: true)

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
            currentSearchQuery = ""
            oldestSearchTimestamp = nil
            loadItems(reset: true)
            return
        }

        // Reset search cursor when query changes
        currentSearchQuery = query
        oldestSearchTimestamp = nil

        // Preserve previous results while loading new ones
        let previousResults: [ClipboardItem] = {
            switch state {
            case .loaded(let items, _):
                return items
            case .searching(_, let searchState):
                switch searchState {
                case .loading(let previous):
                    return previous
                case .loadingMore(let results):
                    return results
                case .results(let results, _):
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
            await performSearch(query: query, isLoadingMore: false)
        }
    }

    /// Load more search results when user scrolls to bottom
    func loadMoreSearchResults() {
        guard case .searching(let query, let searchState) = state else { return }

        // Only load more if we have results with more available
        switch searchState {
        case .results(let items, let hasMore):
            guard hasMore, !items.isEmpty else { return }
            state = .searching(query: query, state: .loadingMore(results: items))

            searchTask = Task {
                guard !Task.isCancelled else { return }
                await performSearch(query: query, isLoadingMore: true)
            }
        default:
            return
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
        let cursorTimestamp: Date?
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
                case .loadingMore(let results):
                    return results
                case .results(let results, _):
                    return results
                }
            default:
                return []
            }
        }()

        if reset {
            oldestLoadedTimestamp = nil
            cursorTimestamp = nil
            existingItems = []
            // Only show loading spinner if we have no cached items to display
            if currentItems.isEmpty {
                state = .loading
            }
            // Otherwise keep showing current items - they'll be replaced when load completes
        } else {
            cursorTimestamp = oldestLoadedTimestamp
            if case .loaded(let items, _) = state {
                existingItems = items
            } else {
                existingItems = []
            }
        }

        guard let dbQueue else { return }
        let pageSizeCopy = pageSize
        let signpostID = OSSignpostID(log: performanceLog)
        os_signpost(.begin, log: performanceLog, name: "loadItems", signpostID: signpostID, "reset=%d", reset ? 1 : 0)

        Task.detached {
            let result = Self.fetchItems(dbQueue: dbQueue, pageSize: pageSizeCopy, beforeTimestamp: cursorTimestamp)

            await MainActor.run { [weak self] in
                os_signpost(.end, log: performanceLog, name: "loadItems", signpostID: signpostID)
                switch result {
                case .success(let (newItems, hasMore)):
                    // Update cursor to oldest item's timestamp for next page
                    if let oldestItem = newItems.last {
                        self?.oldestLoadedTimestamp = oldestItem.timestamp
                    }
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

    /// Keyset pagination: fetches items older than the cursor timestamp
    /// This is O(log n) via index vs O(n) for OFFSET-based pagination
    private nonisolated static func fetchItems(dbQueue: DatabaseQueue, pageSize: Int, beforeTimestamp: Date?) -> Result<([ClipboardItem], Bool), Error> {
        let signpostID = OSSignpostID(log: performanceLog)
        os_signpost(.begin, log: performanceLog, name: "fetchItems.db", signpostID: signpostID)
        do {
            let newItems = try measureTime("fetchItems.db") {
                try dbQueue.read { db in
                    var query = ClipboardItem.order(Column("timestamp").desc)
                    if let cursor = beforeTimestamp {
                        query = query.filter(Column("timestamp") < cursor)
                    }
                    return try query.limit(pageSize).fetchAll(db)
                }
            }
            os_signpost(.end, log: performanceLog, name: "fetchItems.db", signpostID: signpostID, "count=%d", newItems.count)
            let hasMore = newItems.count == pageSize
            return .success((newItems, hasMore))
        } catch {
            os_signpost(.end, log: performanceLog, name: "fetchItems.db", signpostID: signpostID, "error")
            return .failure(error)
        }
    }

    // MARK: - Search

    private func performSearch(query: String, isLoadingMore: Bool) async {
        guard let dbQueue else {
            state = .error("Database not available")
            return
        }

        let signpostID = OSSignpostID(log: performanceLog)
        os_signpost(.begin, log: performanceLog, name: "search", signpostID: signpostID, "query=%{public}s,more=%d", query, isLoadingMore ? 1 : 0)

        // Capture existing results for load-more
        let existingResults: [ClipboardItem]
        if isLoadingMore, case .searching(_, .loadingMore(let results)) = state {
            existingResults = results
        } else {
            existingResults = []
        }

        let cursorTimestamp = isLoadingMore ? oldestSearchTimestamp : nil
        let limit = searchPageSize

        // For short queries, use streaming search that updates UI as results arrive
        if query.count < 3 {
            var streamedResults = existingResults
            var lastUpdateTime = CFAbsoluteTimeGetCurrent()
            let minUpdateInterval: Double = 0.016  // ~60fps, 16ms between updates

            let stream = Self.streamingLikeSearch(
                dbQueue: dbQueue,
                query: query,
                beforeTimestamp: cursorTimestamp,
                limit: limit
            )

            for await item in stream {
                guard !Task.isCancelled else { break }
                guard case .searching(let currentQuery, _) = state, currentQuery == query else { break }

                streamedResults.append(item)

                // Batch UI updates to ~60fps max
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastUpdateTime >= minUpdateInterval {
                    state = .searching(query: query, state: .results(streamedResults, hasMore: true))
                    lastUpdateTime = now
                }
            }

            os_signpost(.end, log: performanceLog, name: "search", signpostID: signpostID, "results=%d", streamedResults.count - existingResults.count)

            guard !Task.isCancelled else { return }
            guard case .searching(let currentQuery, _) = state, currentQuery == query else { return }

            // Update cursor and finalize
            if let oldestItem = streamedResults.last {
                oldestSearchTimestamp = oldestItem.timestamp
            }
            let newResultsCount = streamedResults.count - existingResults.count
            let hasMore = newResultsCount == limit
            state = .searching(query: query, state: .results(streamedResults, hasMore: hasMore))
            return
        }

        // THREE-PHASE SEARCH STRATEGY
        // Phase 1: FTS5 Prefix Search (instant, no limit) - exact prefix matches
        let phase1Results = await Task.detached { [query] () -> [ClipboardItem] in
            measureTime("search.phase1[\(query.prefix(10))]") {
                do {
                    return try dbQueue.read { db in
                        let escapedQuery = query.replacingOccurrences(of: "\"", with: "\"\"")
                        // Use prefix search: query* for exact prefix matching
                        let sql = """
                            SELECT items.* FROM items
                            INNER JOIN items_fts ON items.id = items_fts.rowid
                            WHERE items_fts MATCH ?
                            ORDER BY items.timestamp DESC
                        """
                        return try ClipboardItem.fetchAll(db, sql: sql, arguments: ["\(escapedQuery)*"])
                    }
                } catch {
                    logError("Phase 1 prefix search failed: \(error)")
                    return []
                }
            }
        }.value

        // Update UI with Phase 1 results immediately
        guard !Task.isCancelled else { return }
        guard case .searching(let currentQuery, _) = state, currentQuery == query else { return }

        let phase1Combined = isLoadingMore ? existingResults + phase1Results : phase1Results
        state = .searching(query: query, state: .results(phase1Combined, hasMore: true))

        let phase1IDs = Set(phase1Results.map { $0.id })

        // Phase 2 & 3: Run asynchronously in parallel
        let phase2And3Task = Task.detached { [query] () -> [ClipboardItem] in
            // PHASE 2: Fuzzy search using trigram OR matching for typo tolerance
            // Build OR query from trigrams to find partial matches
            let phase2Results: [ClipboardItem] = measureTime("search.phase2[\(query.prefix(10))]") {
                do {
                    return try dbQueue.read { db in
                        // Generate trigrams from query and search with OR to allow partial matches
                        let queryLower = query.lowercased()
                        var trigrams: [String] = []
                        let chars = Array(queryLower)
                        for i in 0..<max(0, chars.count - 2) {
                            let trigram = String(chars[i..<i+3])
                            // Escape special FTS characters
                            let escaped = trigram
                                .replacingOccurrences(of: "\"", with: "\"\"")
                                .replacingOccurrences(of: "*", with: "")
                                .replacingOccurrences(of: "-", with: "")
                            if !escaped.isEmpty && escaped.count == 3 {
                                trigrams.append("\"\(escaped)\"")
                            }
                        }

                        guard !trigrams.isEmpty else { return [] }

                        // Use OR to find items matching ANY trigram (fuzzy matching)
                        let orQuery = trigrams.joined(separator: " OR ")
                        let sql = """
                            SELECT items.* FROM items
                            INNER JOIN items_fts ON items.id = items_fts.rowid
                            WHERE items_fts MATCH ?
                            ORDER BY items.timestamp DESC
                            LIMIT 500
                        """
                        let allResults = try ClipboardItem.fetchAll(db, sql: sql, arguments: [orQuery])
                        // Filter out Phase 1 results
                        return allResults.filter { !phase1IDs.contains($0.id) }
                    }
                } catch {
                    logError("Phase 2 trigram search failed: \(error)")
                    return []
                }
            }

            // PHASE 3: Filter and rank by Levenshtein distance
            // Only keep items within reasonable edit distance, then sort by closeness
            let phase3Results: [ClipboardItem] = measureTime("search.phase3[\(query.prefix(10))]") {
                let maxDistance = max(query.count / 2, 3)  // Allow ~50% edits or at least 3

                return phase2Results
                    .compactMap { item -> (ClipboardItem, Int)? in
                        let content = item.content.textContent.lowercased()
                        let queryLower = query.lowercased()

                        // Find best matching substring in content
                        var bestDistance = Int.max
                        let windowSize = min(query.count + maxDistance, content.count)

                        // Slide window through content to find best match
                        if content.count >= query.count {
                            let contentChars = Array(content)
                            for start in 0..<min(contentChars.count - query.count + 1, 100) {
                                let end = min(start + windowSize, contentChars.count)
                                let substring = String(contentChars[start..<end])
                                let dist = levenshteinDistance(queryLower, substring)
                                bestDistance = min(bestDistance, dist)
                                if bestDistance <= 1 { break }  // Good enough, stop early
                            }
                        } else {
                            bestDistance = levenshteinDistance(queryLower, content)
                        }

                        return bestDistance <= maxDistance ? (item, bestDistance) : nil
                    }
                    .sorted { $0.1 < $1.1 }  // Sort by distance (lower = better)
                    .map { $0.0 }  // Extract just the items
            }

            return phase3Results
        }

        // Await Phase 2 & 3 completion and merge results
        let phase2And3Results = await phase2And3Task.value

        // Final update with all results combined
        guard !Task.isCancelled else { return }
        guard case .searching(let currentQuery, _) = state, currentQuery == query else { return }

        let finalResults = phase1Combined + phase2And3Results

        // Update cursor for pagination
        if let oldestItem = finalResults.last {
            oldestSearchTimestamp = oldestItem.timestamp
        }

        state = .searching(query: query, state: .results(finalResults, hasMore: false))

        os_signpost(.end, log: performanceLog, name: "search", signpostID: signpostID, "phase1=%d,phase2+3=%d,total=%d",
                    phase1Results.count, phase2And3Results.count, finalResults.count)
    }

    /// Streaming LIKE search that yields results one at a time via AsyncStream
    /// Allows UI to update immediately as each result is found
    private nonisolated static func streamingLikeSearch(
        dbQueue: DatabaseQueue,
        query: String,
        beforeTimestamp: Date?,
        limit: Int
    ) -> AsyncStream<ClipboardItem> {
        AsyncStream { continuation in
            Task.detached {
                var count = 0
                do {
                    try dbQueue.read { db in
                        var sql = "SELECT * FROM items WHERE content LIKE ?"
                        var arguments: [DatabaseValueConvertible] = ["%\(query)%"]

                        if let cursor = beforeTimestamp {
                            sql += " AND timestamp < ?"
                            arguments.append(cursor)
                        }

                        sql += " ORDER BY timestamp DESC"

                        let statement = try db.makeStatement(sql: sql)
                        try statement.setArguments(StatementArguments(arguments))
                        let cursor = try Row.fetchCursor(statement)

                        while let row = try cursor.next() {
                            if Task.isCancelled { break }

                            if let item = try? ClipboardItem(row: row) {
                                continuation.yield(item)
                                count += 1
                                if count >= limit { break }
                            }
                        }
                    }
                } catch {
                    logError("Streaming LIKE search failed: \(error)")
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Clipboard Monitoring

    func startMonitoring() {
        pollingTask?.cancel()
        setupSystemObservers()

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                // Skip polling entirely while system is sleeping
                if self.isSystemSleeping {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }

                self.checkForChanges()
                let interval = self.adaptivePollingInterval()
                try? await Task.sleep(for: .milliseconds(interval))
            }
        }
    }

    func stopMonitoring() {
        pollingTask?.cancel()
        pollingTask = nil
        removeSystemObservers()
    }

    private func setupSystemObservers() {
        let workspace = NSWorkspace.shared
        let nc = workspace.notificationCenter

        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isSystemSleeping = true
            }
        }

        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isSystemSleeping = false
                // Brief burst of faster polling after wake to catch any changes
                self?.lastActivityTime = Date()
            }
        }
    }

    private func removeSystemObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        if let observer = sleepObserver {
            nc.removeObserver(observer)
            sleepObserver = nil
        }
        if let observer = wakeObserver {
            nc.removeObserver(observer)
            wakeObserver = nil
        }
    }

    /// Returns polling interval in milliseconds based on system state and activity
    private func adaptivePollingInterval() -> Int {
        let idleTime = Date().timeIntervalSince(lastActivityTime)

        // Low power mode: always use slower polling
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return 2000
        }

        // Adaptive based on idle time
        switch idleTime {
        case ..<5:
            // Recently active: fast polling for responsiveness
            return 250
        case ..<30:
            // Normal usage: balanced polling
            return 500
        case ..<120:
            // Idle: reduce polling frequency
            return 1000
        default:
            // Long idle: minimal polling
            return 1500
        }
    }

    private func checkForChanges() {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // User is actively copying - enable faster polling
        lastActivityTime = Date()

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
        let sourceAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Move all DB operations to background
        guard let dbQueue else { return }
        Task.detached { [weak self] in
            let newItemId = Self.saveTextItem(dbQueue: dbQueue, text: text, hash: hash, sourceApp: sourceApp, sourceAppBundleID: sourceAppBundleID)

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

    private nonisolated static func saveTextItem(dbQueue: DatabaseQueue, text: String, hash: String, sourceApp: String?, sourceAppBundleID: String?) -> Int64? {
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
                    let item = ClipboardItem(text: text, sourceApp: sourceApp, sourceAppBundleID: sourceAppBundleID)
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

        // Update the specific item in-place instead of reloading the entire list
        let newMetadataState = LinkMetadataState.fromDatabase(title: title, imageData: imageData)
        updateItemMetadata(itemId: itemId, url: url, metadataState: newMetadataState)
    }

    /// Updates a single item's metadata in-place without reloading the entire list
    private func updateItemMetadata(itemId: Int64, url: String, metadataState: LinkMetadataState) {
        switch state {
        case .loaded(let items, let hasMore):
            let updatedItems = items.map { item -> ClipboardItem in
                guard item.id == itemId else { return item }
                return ClipboardItem(
                    id: item.id,
                    content: .link(url: url, metadataState: metadataState),
                    contentHash: item.contentHash,
                    timestamp: item.timestamp,
                    sourceApp: item.sourceApp,
                    sourceAppBundleID: item.sourceAppBundleID
                )
            }
            state = .loaded(items: updatedItems, hasMore: hasMore)

        case .searching(let query, let searchState):
            let updateItems: ([ClipboardItem]) -> [ClipboardItem] = { items in
                items.map { item -> ClipboardItem in
                    guard item.id == itemId else { return item }
                    return ClipboardItem(
                        id: item.id,
                        content: .link(url: url, metadataState: metadataState),
                        contentHash: item.contentHash,
                        timestamp: item.timestamp,
                        sourceApp: item.sourceApp,
                        sourceAppBundleID: item.sourceAppBundleID
                    )
                }
            }
            let newSearchState: SearchResultState
            switch searchState {
            case .loading(let previous):
                newSearchState = .loading(previousResults: updateItems(previous))
            case .loadingMore(let results):
                newSearchState = .loadingMore(results: updateItems(results))
            case .results(let results, let hasMore):
                newSearchState = .results(updateItems(results), hasMore: hasMore)
            }
            state = .searching(query: query, state: newSearchState)

        default:
            break
        }
    }

    private func generateAndUpdateImageDescription(itemId: Int64, imageData: Data) async {
        guard let description = await ImageDescriptionGenerator.generateDescription(from: imageData) else { return }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let dbQueue else { return }
        await Task.detached { [dbQueue] in
            do {
                try dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE items SET content = ? WHERE id = ? AND contentType = 'image'",
                        arguments: [trimmed, itemId]
                    )
                }
            } catch {
                logError("Failed to update image description: \(error)")
            }
        }.value

        await MainActor.run { [weak self] in
            self?.updateItemImageDescription(itemId: itemId, description: trimmed)
        }
    }

    private func updateItemImageDescription(itemId: Int64, description: String) {
        let updateItem: (ClipboardItem) -> ClipboardItem = { item in
            guard item.id == itemId else { return item }
            guard case .image(let data, let existingDescription) = item.content else { return item }
            guard existingDescription != description else { return item }
            return ClipboardItem(
                id: item.id,
                content: .image(data: data, description: description),
                contentHash: item.contentHash,
                timestamp: item.timestamp,
                sourceApp: item.sourceApp,
                sourceAppBundleID: item.sourceAppBundleID
            )
        }

        switch state {
        case .loaded(let items, let hasMore):
            state = .loaded(items: items.map(updateItem), hasMore: hasMore)

        case .searching(let query, let searchState):
            let updatedResults: ([ClipboardItem]) -> [ClipboardItem] = { items in
                items.map(updateItem)
            }
            let newSearchState: SearchResultState
            switch searchState {
            case .loading(let previous):
                newSearchState = .loading(previousResults: updatedResults(previous))
            case .loadingMore(let results):
                newSearchState = .loadingMore(results: updatedResults(results))
            case .results(let results, let hasMore):
                newSearchState = .results(updatedResults(results), hasMore: hasMore)
            }
            state = .searching(query: query, state: newSearchState)

        default:
            break
        }
    }

    private func saveImageItem(rawImageData: Data) {
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let sourceAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let maxPixels = Int(AppSettings.shared.maxImageMegapixels * 1_000_000)
        let quality = AppSettings.shared.imageCompressionQuality

        // Move compression and DB write to background
        guard let dbQueue else { return }
        Task.detached { [weak self] in
            let saveResult = Self.saveImageItemToDB(
                dbQueue: dbQueue,
                rawImageData: rawImageData,
                sourceApp: sourceApp,
                sourceAppBundleID: sourceAppBundleID,
                maxPixels: maxPixels,
                quality: quality
            )

            guard let self else { return }
            await MainActor.run { [weak self] in
                if case .loaded = self?.state {
                    self?.loadItems(reset: true)
                }
            }

            guard let saveResult else { return }
            Task.detached { [weak self] in
                await self?.generateAndUpdateImageDescription(itemId: saveResult.itemId, imageData: saveResult.imageData)
            }
        }
    }

    private nonisolated static func saveImageItemToDB(
        dbQueue: DatabaseQueue,
        rawImageData: Data,
        sourceApp: String?,
        sourceAppBundleID: String?,
        maxPixels: Int,
        quality: Double
    ) -> (itemId: Int64, imageData: Data)? {
        // Compress image with HEIC (HEVC)
        guard let compressedData = compressToHEIC(rawImageData, quality: quality, maxPixels: maxPixels) else {
            logError("Image compression failed, skipping")
            return nil
        }

        do {
            let itemId = try dbQueue.write { db -> Int64 in
                let item = ClipboardItem(imageData: compressedData, sourceApp: sourceApp, sourceAppBundleID: sourceAppBundleID)
                try item.insert(db)
                return db.lastInsertedRowID
            }
            return (itemId: itemId, imageData: compressedData)
        } catch {
            logError("Image save failed: \(error)")
            return nil
        }
    }

    /// Compress image data to HEIC format using HEVC compression
    /// Resizes to maxPixels if larger, then compresses
    private nonisolated static func compressToHEIC(_ imageData: Data, quality: CGFloat, maxPixels: Int) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              var cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        // Resize if exceeds max pixels
        let width = cgImage.width
        let height = cgImage.height
        let pixels = width * height

        if pixels > maxPixels {
            let scale = sqrt(Double(maxPixels) / Double(pixels))
            let newWidth = Int(Double(width) * scale)
            let newHeight = Int(Double(height) * scale)

            guard let context = CGContext(
                data: nil,
                width: newWidth,
                height: newHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }

            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

            guard let resized = context.makeImage() else {
                return nil
            }
            cgImage = resized
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.heic" as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]

        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return data as Data
    }

    private func hashContent(_ string: String) -> String {
        var hasher = Hasher()
        hasher.combine(string)
        return String(hasher.finalize())
    }

    // MARK: - Actions

    func paste(item: ClipboardItem) {
        // Handle images differently - convert off main thread
        if case .image(let data, _) = item.content {
            pasteImage(data: data, itemId: item.id)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.textContent, forType: .string)
        lastChangeCount = pasteboard.changeCount

        if let id = item.id {
            Task {
                await updateItemTimestamp(id: id)
            }
        }
    }

    private func pasteImage(data: Data, itemId: Int64?) {
        // Pre-increment to avoid race with checkForChanges polling
        // The pasteboard changeCount will increment when we set data
        lastChangeCount = NSPasteboard.general.changeCount + 1

        Task {
            // Convert from stored format (HEIC) to TIFF off main thread
            let tiffData = await Task.detached {
                guard let image = NSImage(data: data),
                      let tiff = image.tiffRepresentation else {
                    return nil as Data?
                }
                return tiff
            }.value

            guard let tiffData else {
                // Conversion failed, reset the change count
                lastChangeCount = NSPasteboard.general.changeCount
                return
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(tiffData, forType: .tiff)
            lastChangeCount = pasteboard.changeCount

            if let itemId {
                await updateItemTimestamp(id: itemId)
            }
        }
    }

    private func updateItemTimestamp(id: Int64) async {
        // Defer database operations to avoid blocking clipboard availability
        await Task.detached { [dbQueue] in
            do {
                try dbQueue?.write { db in
                    try db.execute(sql: "UPDATE items SET timestamp = ? WHERE id = ?", arguments: [Date(), id])
                }
            } catch {
                logError("Failed to update timestamp: \(error)")
            }
        }.value

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
            case .loadingMore(let results):
                newState = .loadingMore(results: results.filter { $0.id != id })
            case .results(let results, let hasMore):
                newState = .results(results.filter { $0.id != id }, hasMore: hasMore)
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
        let maxSizeGB = AppSettings.shared.maxDatabaseSizeGB
        guard maxSizeGB > 0, let dbQueue else { return }

        let maxBytes = Int64(maxSizeGB * 1024 * 1024 * 1024)

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
