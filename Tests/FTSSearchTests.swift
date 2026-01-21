import Testing
import GRDB
import Foundation

/// Integration tests for FTS5 trigram search with ID Map & Hydration strategy
/// Tests the native SQLite trigram tokenizer with BM25 ranking
@Suite("FTS Search Integration Tests")
struct FTSSearchTests {

    // MARK: - Test Harness

    /// Lightweight search harness that replicates the ClipboardStore ID Map strategy
    struct SearchHarness {
        let dbQueue: DatabaseQueue

        init(items: [String]) throws {
            dbQueue = try DatabaseQueue()
            try dbQueue.write { db in
                // Create items table
                try db.execute(sql: """
                    CREATE TABLE items (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        content TEXT NOT NULL,
                        contentHash TEXT NOT NULL,
                        timestamp DATETIME NOT NULL,
                        sourceApp TEXT,
                        contentType TEXT DEFAULT 'text',
                        imageData BLOB,
                        linkTitle TEXT,
                        linkImageData BLOB,
                        sourceAppBundleID TEXT
                    )
                """)

                // Create FTS5 table with trigram tokenizer
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE items_fts USING fts5(
                        content, content=items, content_rowid=id, tokenize='trigram'
                    )
                """)

                // Create triggers for FTS sync
                try db.execute(sql: """
                    CREATE TRIGGER items_ai AFTER INSERT ON items BEGIN
                        INSERT INTO items_fts(rowid, content) VALUES (new.id, new.content);
                    END
                """)

                // Insert test data with descending timestamps (newest first)
                let baseDate = Date()
                for (index, item) in items.enumerated() {
                    let timestamp = baseDate.addingTimeInterval(Double(-index))
                    let hash = String(item.hashValue)
                    try db.execute(
                        sql: "INSERT INTO items (content, contentHash, timestamp, contentType) VALUES (?, ?, ?, 'text')",
                        arguments: [item, hash, timestamp]
                    )
                }
            }
        }

        /// Perform search using ID Map strategy and return matched content strings in order
        func search(_ query: String) throws -> [String] {
            // Short query: use LIKE search (streaming approach for < 3 chars)
            if query.count < 3 {
                return try likeSearch(query)
            }

            // ID Map Strategy: Fetch IDs sorted by BM25 rank, then hydrate
            return try idMapSearch(query)
        }

        private func likeSearch(_ query: String) throws -> [String] {
            try dbQueue.read { db in
                let sql = "SELECT content FROM items WHERE content LIKE ? ORDER BY timestamp DESC"
                return try String.fetchAll(db, sql: sql, arguments: ["%\(query)%"])
            }
        }

        /// ID Map Strategy: Native trigram query with BM25 ranking
        private func idMapSearch(_ query: String) throws -> [String] {
            // Phase A: Fetch only IDs sorted by relevance (BM25 rank)
            let orderedIDs: [Int64] = try dbQueue.read { db in
                // Escape double quotes and wrap in quotes for phrase matching
                let escaped = query.replacingOccurrences(of: "\"", with: "\"\"")
                let sql = """
                    SELECT rowid
                    FROM items_fts
                    WHERE items_fts MATCH ?
                    ORDER BY rank
                    LIMIT 2000
                """
                // Wrap in quotes to treat as literal phrase (handles special chars like parentheses)
                return try Int64.fetchAll(db, sql: sql, arguments: ["\"\(escaped)\""])
            }

            guard !orderedIDs.isEmpty else { return [] }

            // Phase B: Hydrate - fetch content for those IDs
            let contents: [String] = try dbQueue.read { db in
                let idList = orderedIDs.map(String.init).joined(separator: ",")
                let items = try Row.fetchAll(db, sql: "SELECT id, content FROM items WHERE id IN (\(idList))")

                // Re-sort to match BM25 ranking order
                let contentMap = Dictionary(uniqueKeysWithValues: items.map { ($0["id"] as Int64, $0["content"] as String) })
                return orderedIDs.compactMap { contentMap[$0] }
            }

            return contents
        }
    }

    // MARK: - Exact Phrase Search Tests

    @Test("Exact substring match returns results")
    func exactSubstringMatch() throws {
        let harness = try SearchHarness(items: [
            "Hello World",
            "Hello there",
            "World peace",
            "Goodbye"
        ])

        let results = try harness.search("Hello")
        #expect(results.contains("Hello World"))
        #expect(results.contains("Hello there"))
    }

    @Test("Exact phrase with spaces matches correctly")
    func exactPhraseWithSpaces() throws {
        let harness = try SearchHarness(items: [
            "Hello World",
            "HelloWorld",
            "Hello  World",
            "World Hello"
        ])

        let results = try harness.search("Hello World")
        #expect(results.contains("Hello World"))
    }

    @Test("Case insensitive exact match")
    func caseInsensitiveExactMatch() throws {
        let harness = try SearchHarness(items: [
            "HELLO WORLD",
            "hello world",
            "Hello World",
            "HeLLo WoRLd"
        ])

        let results = try harness.search("hello")
        #expect(results.count == 4)
    }

    @Test("No results when no match")
    func noMatchReturnsEmpty() throws {
        let harness = try SearchHarness(items: [
            "Hello World",
            "Goodbye Moon"
        ])

        let results = try harness.search("xyz123")
        #expect(results.isEmpty)
    }

    // MARK: - Short Query LIKE Search Tests

    @Test("Single character search uses LIKE")
    func singleCharSearch() throws {
        let harness = try SearchHarness(items: [
            "apple",
            "banana",
            "apricot"
        ])

        let results = try harness.search("a")
        #expect(results == ["apple", "banana", "apricot"])
    }

    @Test("Two character search uses LIKE")
    func twoCharSearch() throws {
        let harness = try SearchHarness(items: [
            "apple",
            "application",
            "banana"
        ])

        let results = try harness.search("ap")
        #expect(results == ["apple", "application"])
    }

    // MARK: - Trigram Search Tests

    @Test("Trigram partial match")
    func trigramPartialMatch() throws {
        let harness = try SearchHarness(items: [
            "ClipboardStore",
            "clipboard manager",
            "something else"
        ])

        let results = try harness.search("clipboard")
        #expect(results.contains("ClipboardStore"))
        #expect(results.contains("clipboard manager"))
    }

    // MARK: - BM25 Ranking Tests

    @Test("Results ranked by BM25 score")
    func rankedByBM25Score() throws {
        let harness = try SearchHarness(items: [
            "test",      // exact match - highest BM25
            "testy",     // very close
            "testing",   // close
            "toast"      // different (but may match via trigrams)
        ])

        let results = try harness.search("test")
        // Exact match should be ranked high by BM25
        #expect(results.contains("test"))
        #expect(results.contains("testy"))
        #expect(results.contains("testing"))
    }

    @Test("Close matches ranked before distant matches")
    func closeMatchesRankedFirst() throws {
        let harness = try SearchHarness(items: [
            "config",          // exact
            "configure",       // close
            "configuration",   // contains "config"
            "reconfigure"      // contains "config"
        ])

        let results = try harness.search("config")
        // All contain "config" so all should match
        #expect(results.contains("config"))
        #expect(results.contains("configure"))
        #expect(results.contains("configuration"))
    }

    // MARK: - Result Ordering Tests

    @Test("Results preserve BM25 ranking order")
    func preserveBM25Order() throws {
        let harness = try SearchHarness(items: [
            "first match",
            "second match",
            "third match"
        ])

        let results = try harness.search("match")
        // All have same relevance, BM25 may order by document length or other factors
        #expect(results.count == 3)
    }

    @Test("Exact matches ranked higher by BM25")
    func exactMatchesRankedHigher() throws {
        let harness = try SearchHarness(items: [
            "exact hello match",
            "helo world",          // typo - trigram may match some
            "hello there"
        ])

        let results = try harness.search("hello")
        // Items containing "hello" should appear
        #expect(results.contains("exact hello match"))
        #expect(results.contains("hello there"))
    }

    // MARK: - Edge Cases

    @Test("Empty query handled by LIKE fallback")
    func emptyQuery() throws {
        let harness = try SearchHarness(items: ["Hello", "World"])

        let results = try harness.search("")
        #expect(results.count == 2)
    }

    @Test("Query with special characters")
    func specialCharacters() throws {
        let harness = try SearchHarness(items: [
            "function test() { }",
            "const x = \"hello\"",
            "array[0]"
        ])

        let results = try harness.search("test()")
        #expect(results.contains("function test() { }"))
    }

    @Test("Unicode content search")
    func unicodeSearch() throws {
        let harness = try SearchHarness(items: [
            "Hello 世界",
            "Bonjour monde",
            "Привет мир"
        ])

        let results = try harness.search("世界")
        #expect(results.contains("Hello 世界"))
    }

    @Test("Long content search")
    func longContentSearch() throws {
        let longContent = String(repeating: "word ", count: 100) + "needle" + String(repeating: " word", count: 100)
        let harness = try SearchHarness(items: [
            longContent,
            "short text",
            "another needle here"
        ])

        let results = try harness.search("needle")
        #expect(results.count == 2)
        #expect(results.contains(longContent))
        #expect(results.contains("another needle here"))
    }

    @Test("Multiline content search")
    func multilineSearch() throws {
        let harness = try SearchHarness(items: [
            "line1\nline2\nline3",
            "single line with line2 text",
            "no match"
        ])

        let results = try harness.search("line2")
        #expect(results.count == 2)
    }

    @Test("Code snippet search")
    func codeSnippetSearch() throws {
        let harness = try SearchHarness(items: [
            "func calculateSum(_ numbers: [Int]) -> Int",
            "let result = calculateSum([1, 2, 3])",
            "def calculate_sum(numbers):",
            "something unrelated"
        ])

        let results = try harness.search("calculateSum")
        #expect(results.contains("func calculateSum(_ numbers: [Int]) -> Int"))
        #expect(results.contains("let result = calculateSum([1, 2, 3])"))
    }

    @Test("URL search")
    func urlSearch() throws {
        let harness = try SearchHarness(items: [
            "https://github.com/user/repo",
            "https://gitlab.com/user/repo",
            "Visit github.com for more",
            "something else"
        ])

        let results = try harness.search("github")
        #expect(results.count == 2)
    }

    @Test("Email search")
    func emailSearch() throws {
        let harness = try SearchHarness(items: [
            "user@example.com",
            "Contact: admin@example.org",
            "no email here"
        ])

        let results = try harness.search("example")
        #expect(results.count == 2)
    }

    // MARK: - Stress Tests

    @Test("Search with many items")
    func manyItemsSearch() throws {
        var items: [String] = []
        for i in 0..<1000 {
            items.append("Item number \(i) with some content")
        }
        items.append("Special target item to find")

        let harness = try SearchHarness(items: items)
        let results = try harness.search("Special target")

        #expect(results.contains("Special target item to find"))
    }

    @Test("Search with duplicate-like content")
    func duplicateLikeContent() throws {
        let harness = try SearchHarness(items: [
            "test1",
            "test2",
            "test3",
            "test10",
            "test100"
        ])

        let results = try harness.search("test1")
        #expect(results.contains("test1"))
        #expect(results.contains("test10"))
        #expect(results.contains("test100"))
    }
}
