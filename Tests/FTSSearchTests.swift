import Testing
import GRDB
import Foundation

/// Integration tests for FTS5 fuzzy search logic
/// Tests the three-phase search strategy: exact phrase, trigram fuzzy, and Levenshtein ranking
@Suite("FTS Search Integration Tests")
struct FTSSearchTests {

    // MARK: - Test Harness

    /// Lightweight search harness that replicates the ClipboardStore search logic
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

        /// Perform search and return matched content strings in order
        func search(_ query: String) throws -> [String] {
            // Short query: use LIKE search
            if query.count < 3 {
                return try likeSearch(query)
            }

            // Phase 1: Exact phrase search
            let phase1Results = try phraseSearch(query)
            let phase1Contents = Set(phase1Results)

            // Phase 2: Trigram fuzzy search
            let phase2Candidates = try trigramSearch(query)
                .filter { !phase1Contents.contains($0) }

            // Phase 3: Levenshtein distance filtering and ranking
            let phase3Results = levenshteinRank(candidates: phase2Candidates, query: query)

            return phase1Results + phase3Results
        }

        private func likeSearch(_ query: String) throws -> [String] {
            try dbQueue.read { db in
                let sql = "SELECT content FROM items WHERE content LIKE ? ORDER BY timestamp DESC"
                return try String.fetchAll(db, sql: sql, arguments: ["%\(query)%"])
            }
        }

        private func phraseSearch(_ query: String) throws -> [String] {
            try dbQueue.read { db in
                let escapedQuery = query.replacingOccurrences(of: "\"", with: "\"\"")
                let sql = """
                    SELECT items.content FROM items
                    INNER JOIN items_fts ON items.id = items_fts.rowid
                    WHERE items_fts MATCH ?
                    ORDER BY items.timestamp DESC
                """
                return try String.fetchAll(db, sql: sql, arguments: ["\"\(escapedQuery)\""])
            }
        }

        private func trigramSearch(_ query: String) throws -> [String] {
            try dbQueue.read { db in
                let termLower = query.lowercased()
                var trigrams: [String] = []
                let chars = Array(termLower)
                for i in 0..<max(0, chars.count - 2) {
                    let trigram = String(chars[i..<i+3])
                    let escaped = trigram
                        .replacingOccurrences(of: "\"", with: "\"\"")
                        .replacingOccurrences(of: "*", with: "")
                    if escaped.count == 3 {
                        trigrams.append("\"\(escaped)\"")
                    }
                }

                guard !trigrams.isEmpty else { return [] }

                let orQuery = trigrams.joined(separator: " OR ")
                let sql = """
                    SELECT items.content FROM items
                    INNER JOIN items_fts ON items.id = items_fts.rowid
                    WHERE items_fts MATCH ?
                    ORDER BY items.timestamp DESC
                    LIMIT 500
                """
                return try String.fetchAll(db, sql: sql, arguments: [orQuery])
            }
        }

        private func levenshteinRank(candidates: [String], query: String) -> [String] {
            let maxDistance = max(query.count / 2, 3)
            let termLower = query.lowercased()

            return candidates
                .compactMap { content -> (String, Int)? in
                    let contentLower = content.lowercased()
                    var bestDistance = Int.max
                    let windowSize = min(query.count + maxDistance, contentLower.count)

                    if contentLower.count >= query.count {
                        let contentChars = Array(contentLower)
                        for start in 0..<min(contentChars.count - query.count + 1, 100) {
                            let end = min(start + windowSize, contentChars.count)
                            let substring = String(contentChars[start..<end])
                            let dist = levenshteinDistance(termLower, substring)
                            bestDistance = min(bestDistance, dist)
                            if bestDistance <= 1 { break }
                        }
                    } else {
                        bestDistance = levenshteinDistance(termLower, contentLower)
                    }

                    return bestDistance <= maxDistance ? (content, bestDistance) : nil
                }
                .sorted { $0.1 < $1.1 }
                .map { $0.0 }
        }
    }

    // MARK: - Exact Phrase Search Tests (Phase 1)

    @Test("Exact substring match returns results")
    func exactSubstringMatch() throws {
        let harness = try SearchHarness(items: [
            "Hello World",
            "Hello there",
            "World peace",
            "Goodbye"
        ])

        let results = try harness.search("Hello")
        #expect(results == ["Hello World", "Hello there"])
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
        // FTS5 trigram tokenizer matches substrings, so exact phrase "Hello World"
        // will match content containing that substring. "HelloWorld" contains the
        // trigrams of "Hello World" (llo, lo , o W, etc don't match without space).
        // Actually trigram matches any 3-char sequences, so behavior may vary.
        #expect(results.contains("Hello World"))
        #expect(!results.contains("World Hello")) // Order matters for phrase
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

    // MARK: - Fuzzy/Trigram Search Tests (Phase 2)

    @Test("Fuzzy match with typo finds similar content")
    func fuzzyMatchWithTypo() throws {
        let harness = try SearchHarness(items: [
            "application",
            "database",
            "configuration"
        ])

        // "aplication" (missing 'p') should still match "application" via trigrams
        let results = try harness.search("aplication")
        #expect(results.contains("application"))
    }

    @Test("Trigram partial match")
    func trigramPartialMatch() throws {
        let harness = try SearchHarness(items: [
            "ClipboardStore",
            "clipboard manager",
            "something else"
        ])

        let results = try harness.search("clipboard")
        #expect(results.contains("ClipboardStore") || results.contains("clipboard manager"))
    }

    // MARK: - Levenshtein Distance Ranking Tests (Phase 3)

    @Test("Results ranked by edit distance")
    func rankedByEditDistance() throws {
        let harness = try SearchHarness(items: [
            "test",      // exact match
            "testy",     // 1 edit (addition)
            "testing",   // 3 edits
            "toast"      // 2 edits
        ])

        let results = try harness.search("test")
        // Exact match should be first (Phase 1), then ranked by distance
        #expect(results.first == "test")
    }

    @Test("Close matches ranked before distant matches")
    func closeMatchesRankedFirst() throws {
        // Insert in reverse order so "config" (exact) is newest
        let harness = try SearchHarness(items: [
            "config",          // exact - newest
            "configure",       // close
            "configuration",   // contains "config"
            "reconfigure"      // contains "config" but prefix
        ])

        let results = try harness.search("config")
        // All contain "config" so all match in Phase 1
        // Within Phase 1, results are ordered by timestamp (newest first)
        #expect(results.first == "config")
        #expect(results.contains("configure"))
        #expect(results.contains("configuration"))
    }

    // MARK: - Result Ordering Tests

    @Test("Results preserve timestamp order within same match quality")
    func preserveTimestampOrder() throws {
        let harness = try SearchHarness(items: [
            "first match",   // newest (index 0)
            "second match",  // older (index 1)
            "third match"    // oldest (index 2)
        ])

        let results = try harness.search("match")
        #expect(results == ["first match", "second match", "third match"])
    }

    @Test("Phase 1 results come before Phase 2/3 results")
    func phase1BeforePhase2() throws {
        let harness = try SearchHarness(items: [
            "exact hello match",  // Phase 1: exact
            "helo world",         // Phase 2/3: fuzzy (typo)
            "hello there"         // Phase 1: exact
        ])

        let results = try harness.search("hello")
        // Both exact matches should appear before the fuzzy match
        let helloExactIndices = results.enumerated()
            .filter { $0.element.contains("hello") }
            .map { $0.offset }
        let heloIndex = results.firstIndex(of: "helo world")

        if let heloIdx = heloIndex {
            for exactIdx in helloExactIndices {
                #expect(exactIdx < heloIdx, "Exact matches should come before fuzzy matches")
            }
        }
    }

    // MARK: - Edge Cases

    @Test("Empty query handled by LIKE fallback")
    func emptyQuery() throws {
        let harness = try SearchHarness(items: ["Hello", "World"])

        // Empty query uses LIKE '%' which matches everything
        // In practice, ClipboardStore intercepts empty queries before searching
        let results = try harness.search("")
        // LIKE '%' matches all items
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
        // Phase 1 matches exact "calculateSum"
        // Phase 2/3 may match "calculate_sum" via trigram similarity (cal, alc, lcu, etc.)
        #expect(results.contains("func calculateSum(_ numbers: [Int]) -> Int"))
        #expect(results.contains("let result = calculateSum([1, 2, 3])"))
        // Fuzzy match may or may not include calculate_sum depending on distance threshold
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

    // MARK: - Fuzzy Match Ordering Tests

    @Test("Exact match ranked before partial fuzzy match")
    func exactBeforePartialFuzzy() throws {
        let harness = try SearchHarness(items: [
            "celebrated creativity, rebellion, and challenging the status quo, the app as one for innovators and visionaries who change the world.",
            "that's too on the nose. keep code and stuff. it's just the subtle message.",
            "server_name example.com",
            "we went too far"
        ])

        let results = try harness.search("too far")

        // "we went too far" contains exact phrase "too far" - should be first
        #expect(results.first == "we went too far")

        // "that's too on the nose..." contains "too" but not "too far" - fuzzy match
        let tooOnTheNose = "that's too on the nose. keep code and stuff. it's just the subtle message."
        #expect(results.contains(tooOnTheNose))

        // The exact match should come before the partial match
        if let exactIndex = results.firstIndex(of: "we went too far"),
           let fuzzyIndex = results.firstIndex(of: tooOnTheNose) {
            #expect(exactIndex < fuzzyIndex, "Exact 'too far' match should rank before partial 'too' match")
        }

        // Items without "too" or "far" should not appear
        #expect(!results.contains("server_name example.com"))
        #expect(!results.contains("celebrated creativity, rebellion, and challenging the status quo, the app as one for innovators and visionaries who change the world."))
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
        // FTS5 trigram tokenizer will match any content containing "test1" as substring
        // All items share trigrams like "tes", "est" so Phase 2 may match more broadly
        #expect(results.contains("test1"))
        #expect(results.contains("test10"))
        #expect(results.contains("test100"))
        // Phase 2 trigram matching may include test2/test3 due to shared trigrams
        // but Phase 3 Levenshtein filtering should exclude them if distance > threshold
    }
}

// MARK: - Levenshtein Distance Helper

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
                matrix[i - 1][j] + 1,
                matrix[i][j - 1] + 1,
                matrix[i - 1][j - 1] + cost
            )
        }
    }

    return matrix[s1Len][s2Len]
}
