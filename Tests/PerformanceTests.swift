#!/usr/bin/env swift

import Foundation
import GRDB

// MARK: - Configuration

enum TestConfig {
    // Content diversity settings
    static let shortContentRatio: Double = 0.3      // 30% short clips (< 100 chars)
    static let mediumContentRatio: Double = 0.5    // 50% medium clips (100-1000 chars)
    static let longContentRatio: Double = 0.2      // 20% long clips (1000-50000 chars)

    // Content type distribution
    static let codeRatio: Double = 0.4             // 40% code snippets
    static let proseRatio: Double = 0.3            // 30% prose/text
    static let urlRatio: Double = 0.1              // 10% URLs
    static let jsonRatio: Double = 0.1             // 10% JSON
    static let mixedRatio: Double = 0.1            // 10% mixed/special chars

    static func targetSizeBytes(forGB gb: Double) -> Int64 {
        Int64(gb * 1024 * 1024 * 1024)
    }
}

// MARK: - Content Generators

struct ContentGenerator {

    // Programming languages for code generation
    static let languages = ["swift", "python", "javascript", "rust", "go", "typescript", "java", "kotlin"]

    // Common words for prose generation
    static let words = [
        "the", "be", "to", "of", "and", "a", "in", "that", "have", "I",
        "it", "for", "not", "on", "with", "he", "as", "you", "do", "at",
        "this", "but", "his", "by", "from", "they", "we", "say", "her", "she",
        "or", "an", "will", "my", "one", "all", "would", "there", "their", "what",
        "so", "up", "out", "if", "about", "who", "get", "which", "go", "me",
        "function", "class", "variable", "method", "property", "interface", "protocol",
        "async", "await", "return", "import", "export", "const", "let", "var",
        "data", "user", "system", "application", "server", "client", "request", "response",
        "error", "success", "failed", "loading", "complete", "pending", "active"
    ]

    // Source apps for diversity
    static let sourceApps = [
        "Xcode", "Visual Studio Code", "Terminal", "Safari", "Chrome", "Firefox",
        "Slack", "Discord", "Notes", "TextEdit", "Sublime Text", "IntelliJ IDEA",
        "Finder", "Mail", "Messages", "Notion", "Obsidian", nil
    ]

    static func generateContent(type: ContentType, length: ContentLength) -> String {
        let targetLength = length.charCount

        switch type {
        case .code:
            return generateCode(targetLength: targetLength)
        case .prose:
            return generateProse(targetLength: targetLength)
        case .url:
            return generateURLs(targetLength: targetLength)
        case .json:
            return generateJSON(targetLength: targetLength)
        case .mixed:
            return generateMixed(targetLength: targetLength)
        }
    }

    static func generateCode(targetLength: Int) -> String {
        let lang = languages.randomElement()!
        var result = "// \(lang) code snippet\n"

        let templates: [String] = [
            """
            func \(randomIdentifier())(\(randomParams())) -> \(randomType()) {
                let \(randomIdentifier()) = \(randomValue())
                if \(randomCondition()) {
                    return \(randomIdentifier())
                }
                return \(randomValue())
            }
            """,
            """
            class \(randomIdentifier().capitalized) {
                private var \(randomIdentifier()): \(randomType())

                init(\(randomParams())) {
                    self.\(randomIdentifier()) = \(randomIdentifier())
                }

                func \(randomIdentifier())() {
                    print("\\(self.\(randomIdentifier()))")
                }
            }
            """,
            """
            struct \(randomIdentifier().capitalized): Codable {
                let \(randomIdentifier()): String
                let \(randomIdentifier()): Int
                let \(randomIdentifier()): Bool
                var \(randomIdentifier()): [String]
            }
            """,
            """
            extension \(randomIdentifier().capitalized) {
                static func \(randomIdentifier())() async throws -> Self {
                    let data = try await fetch\(randomIdentifier().capitalized)()
                    return try JSONDecoder().decode(Self.self, from: data)
                }
            }
            """
        ]

        while result.count < targetLength {
            result += "\n\n" + templates.randomElement()!
        }

        return String(result.prefix(targetLength))
    }

    static func generateProse(targetLength: Int) -> String {
        var result = ""

        while result.count < targetLength {
            // Generate sentences
            let sentenceLength = Int.random(in: 5...20)
            var sentence = ""
            for i in 0..<sentenceLength {
                let word = words.randomElement()!
                if i == 0 {
                    sentence += word.capitalized
                } else {
                    sentence += " " + word
                }
            }
            sentence += [".", "!", "?"].randomElement()!
            result += sentence + " "

            // Occasionally add paragraph breaks
            if Int.random(in: 0...10) == 0 {
                result += "\n\n"
            }
        }

        return String(result.prefix(targetLength))
    }

    static func generateURLs(targetLength: Int) -> String {
        let domains = ["github.com", "stackoverflow.com", "apple.com", "google.com", "example.com", "docs.swift.org"]
        let paths = ["users", "repos", "issues", "pull", "commit", "blob", "tree", "questions", "answers"]

        var result = ""
        while result.count < targetLength {
            let domain = domains.randomElement()!
            let pathCount = Int.random(in: 1...4)
            var url = "https://\(domain)"
            for _ in 0..<pathCount {
                url += "/\(paths.randomElement()!)"
            }
            if Bool.random() {
                url += "/\(Int.random(in: 1000...999999))"
            }
            if Bool.random() {
                url += "?id=\(Int.random(in: 1...1000))&page=\(Int.random(in: 1...100))"
            }
            result += url + "\n"
        }

        return String(result.prefix(targetLength))
    }

    static func generateJSON(targetLength: Int) -> String {
        var result = "{\n"

        while result.count < targetLength - 10 {
            let key = randomIdentifier()
            let value: String
            switch Int.random(in: 0...4) {
            case 0:
                value = "\"\(words.randomElement()!) \(words.randomElement()!)\""
            case 1:
                value = String(Int.random(in: -10000...10000))
            case 2:
                value = String(Double.random(in: -1000...1000))
            case 3:
                value = Bool.random() ? "true" : "false"
            default:
                value = "[\"\(words.randomElement()!)\", \"\(words.randomElement()!)\"]"
            }
            result += "  \"\(key)\": \(value),\n"
        }

        result += "  \"id\": \(Int.random(in: 1...99999))\n}"
        return String(result.prefix(targetLength))
    }

    static func generateMixed(targetLength: Int) -> String {
        let specialChars = "!@#$%^&*()_+-=[]{}|;':\",./<>?`~"
        let emojis = "😀🎉🚀💻📱🔥✨🎯💡🌟"

        var result = ""
        while result.count < targetLength {
            switch Int.random(in: 0...4) {
            case 0:
                result += words.randomElement()! + " "
            case 1:
                result += String(specialChars.randomElement()!)
            case 2:
                result += String(emojis.randomElement()!)
            case 3:
                result += String(Int.random(in: 0...9999)) + " "
            default:
                result += "\n"
            }
        }

        return String(result.prefix(targetLength))
    }

    // Helper functions
    static func randomIdentifier() -> String {
        let prefixes = ["get", "set", "fetch", "load", "save", "update", "delete", "create", "process", "handle"]
        let suffixes = ["Data", "User", "Item", "Value", "Result", "State", "Config", "Manager", "Service", "Helper"]
        return prefixes.randomElement()! + suffixes.randomElement()!
    }

    static func randomParams() -> String {
        let count = Int.random(in: 0...3)
        if count == 0 { return "" }
        return (0..<count).map { _ in "\(randomIdentifier()): \(randomType())" }.joined(separator: ", ")
    }

    static func randomType() -> String {
        ["String", "Int", "Bool", "Double", "[String]", "Data", "URL", "Date"].randomElement()!
    }

    static func randomValue() -> String {
        switch Int.random(in: 0...3) {
        case 0: return "\"\(words.randomElement()!)\""
        case 1: return String(Int.random(in: 0...100))
        case 2: return Bool.random() ? "true" : "false"
        default: return "nil"
        }
    }

    static func randomCondition() -> String {
        ["\(randomIdentifier()) != nil", "\(randomIdentifier()) > 0", "\(randomIdentifier()).isEmpty", "!\(randomIdentifier())"].randomElement()!
    }

    static func randomSourceApp() -> String? {
        sourceApps.randomElement()!
    }
}

enum ContentType: CaseIterable {
    case code, prose, url, json, mixed

    static func random() -> ContentType {
        let rand = Double.random(in: 0...1)
        if rand < TestConfig.codeRatio { return .code }
        if rand < TestConfig.codeRatio + TestConfig.proseRatio { return .prose }
        if rand < TestConfig.codeRatio + TestConfig.proseRatio + TestConfig.urlRatio { return .url }
        if rand < TestConfig.codeRatio + TestConfig.proseRatio + TestConfig.urlRatio + TestConfig.jsonRatio { return .json }
        return .mixed
    }
}

enum ContentLength {
    case short, medium, long

    var charCount: Int {
        switch self {
        case .short: return Int.random(in: 10...100)
        case .medium: return Int.random(in: 100...1000)
        case .long: return Int.random(in: 1000...50000)
        }
    }

    static func random() -> ContentLength {
        let rand = Double.random(in: 0...1)
        if rand < TestConfig.shortContentRatio { return .short }
        if rand < TestConfig.shortContentRatio + TestConfig.mediumContentRatio { return .medium }
        return .long
    }
}

// MARK: - Database Setup

func createTestDatabase(at path: String) throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue(path: path)

    try dbQueue.write { db in
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
    }

    return dbQueue
}

func getDatabaseSize(at path: String) -> Int64 {
    let fileManager = FileManager.default
    guard let attrs = try? fileManager.attributesOfItem(atPath: path),
          let size = attrs[.size] as? Int64 else {
        return 0
    }
    return size
}

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

// MARK: - Performance Tests

struct PerformanceResult {
    let name: String
    let duration: TimeInterval
    let iterations: Int

    var avgDuration: TimeInterval { duration / Double(iterations) }

    var description: String {
        String(format: "  %@: %.3fms avg (%.2fs total, %d iterations)",
               name, avgDuration * 1000, duration, iterations)
    }
}

func measureTime(_ block: () throws -> Void) rethrows -> TimeInterval {
    let start = CFAbsoluteTimeGetCurrent()
    try block()
    return CFAbsoluteTimeGetCurrent() - start
}

func runPerformanceTests(dbQueue: DatabaseQueue, itemCount: Int) throws -> [PerformanceResult] {
    var results: [PerformanceResult] = []

    print("\n📊 Running performance tests...")

    // Test 1: Load first page (50 items)
    let loadIterations = 100
    var loadTime: TimeInterval = 0
    for _ in 0..<loadIterations {
        loadTime += measureTime {
            _ = try? dbQueue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT * FROM items ORDER BY timestamp DESC LIMIT 50
                """)
            }
        }
    }
    results.append(PerformanceResult(name: "Load first page (50 items)", duration: loadTime, iterations: loadIterations))

    // Test 2: Load with offset (pagination)
    let paginationIterations = 50
    var paginationTime: TimeInterval = 0
    let offsets = [100, 500, 1000, 5000, 10000]
    for offset in offsets {
        for _ in 0..<(paginationIterations / offsets.count) {
            paginationTime += measureTime {
                _ = try? dbQueue.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT * FROM items ORDER BY timestamp DESC LIMIT 50 OFFSET ?
                    """, arguments: [offset])
                }
            }
        }
    }
    results.append(PerformanceResult(name: "Paginated load (various offsets)", duration: paginationTime, iterations: paginationIterations))

    // Test 3: Short search queries (1-3 chars) - stress test
    let shortSearchIterations = 50
    var shortSearchTime: TimeInterval = 0
    let shortQueries = ["a", "th", "cod", "fn", "x"]
    for query in shortQueries {
        for _ in 0..<(shortSearchIterations / shortQueries.count) {
            shortSearchTime += measureTime {
                _ = try? dbQueue.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT * FROM items
                        WHERE content LIKE ?
                        ORDER BY timestamp DESC LIMIT 1000
                    """, arguments: ["%\(query)%"])
                }
            }
        }
    }
    results.append(PerformanceResult(name: "Short search queries (1-3 chars)", duration: shortSearchTime, iterations: shortSearchIterations))

    // Test 4: Medium search queries (4-10 chars)
    let mediumSearchIterations = 50
    var mediumSearchTime: TimeInterval = 0
    let mediumQueries = ["function", "return", "class", "import", "async"]
    for query in mediumQueries {
        for _ in 0..<(mediumSearchIterations / mediumQueries.count) {
            mediumSearchTime += measureTime {
                _ = try? dbQueue.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT * FROM items
                        WHERE content LIKE ?
                        ORDER BY timestamp DESC LIMIT 1000
                    """, arguments: ["%\(query)%"])
                }
            }
        }
    }
    results.append(PerformanceResult(name: "Medium search queries (4-10 chars)", duration: mediumSearchTime, iterations: mediumSearchIterations))

    // Test 5: Long/specific search queries
    let longSearchIterations = 50
    var longSearchTime: TimeInterval = 0
    let longQueries = ["fetchUserData", "handleRequest", "processResult", "configuration"]
    for query in longQueries {
        for _ in 0..<(longSearchIterations / longQueries.count) {
            longSearchTime += measureTime {
                _ = try? dbQueue.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT * FROM items
                        WHERE content LIKE ?
                        ORDER BY timestamp DESC LIMIT 1000
                    """, arguments: ["%\(query)%"])
                }
            }
        }
    }
    results.append(PerformanceResult(name: "Long search queries (10+ chars)", duration: longSearchTime, iterations: longSearchIterations))

    // Test 6: Insert performance
    let insertIterations = 100
    var insertTime: TimeInterval = 0
    for _ in 0..<insertIterations {
        let content = ContentGenerator.generateContent(type: .random(), length: .random())
        let hash = String(content.hashValue)
        insertTime += measureTime {
            try? dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO items (content, contentHash, timestamp, sourceApp) VALUES (?, ?, ?, ?)
                """, arguments: [content, hash, Date(), ContentGenerator.randomSourceApp()])
            }
        }
    }
    results.append(PerformanceResult(name: "Insert new item", duration: insertTime, iterations: insertIterations))

    // Test 7: Update timestamp (simulating paste)
    let updateIterations = 100
    var updateTime: TimeInterval = 0
    let maxId = try dbQueue.read { db in
        try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM items") ?? 0
    }
    for _ in 0..<updateIterations {
        let randomId = Int64.random(in: 1...maxId)
        updateTime += measureTime {
            try? dbQueue.write { db in
                try db.execute(sql: "UPDATE items SET timestamp = ? WHERE id = ?", arguments: [Date(), randomId])
            }
        }
    }
    results.append(PerformanceResult(name: "Update timestamp", duration: updateTime, iterations: updateIterations))

    // Test 8: Delete item
    let deleteIterations = 50
    var deleteTime: TimeInterval = 0
    for _ in 0..<deleteIterations {
        let randomId = Int64.random(in: 1...maxId)
        deleteTime += measureTime {
            try? dbQueue.write { db in
                try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [randomId])
            }
        }
    }
    results.append(PerformanceResult(name: "Delete item", duration: deleteTime, iterations: deleteIterations))

    // Test 9: Check for duplicate (by hash)
    let hashCheckIterations = 100
    var hashCheckTime: TimeInterval = 0
    let sampleHashes = try dbQueue.read { db in
        try String.fetchAll(db, sql: "SELECT contentHash FROM items ORDER BY RANDOM() LIMIT 20")
    }
    for hash in sampleHashes {
        for _ in 0..<(hashCheckIterations / sampleHashes.count) {
            hashCheckTime += measureTime {
                _ = try? dbQueue.read { db in
                    try Row.fetchOne(db, sql: "SELECT id FROM items WHERE contentHash = ?", arguments: [hash])
                }
            }
        }
    }
    results.append(PerformanceResult(name: "Hash duplicate check", duration: hashCheckTime, iterations: hashCheckIterations))

    // Test 10: Count total items
    let countIterations = 100
    var countTime: TimeInterval = 0
    for _ in 0..<countIterations {
        countTime += measureTime {
            _ = try? dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items")
            }
        }
    }
    results.append(PerformanceResult(name: "Count total items", duration: countTime, iterations: countIterations))

    return results
}

// MARK: - Fuzzy Match Performance Test

struct FuzzyMatch {
    struct Result {
        let score: Int
        let positions: [Int]

        static let noMatch = Result(score: 0, positions: [])
        var isMatch: Bool { !positions.isEmpty }
    }

    private static let scoreMatch = 16
    private static let scoreGapStart = -3
    private static let scoreGapExtension = -1
    private static let bonusConsecutive = 8
    private static let bonusBoundary = 8
    private static let bonusFirstChar = 8
    private static let bonusCamelCase = 7
    private static let bonusAfterSlash = 9
    private static let bonusAfterSpace = 8

    static func match(pattern: String, in text: String) -> Result? {
        guard !pattern.isEmpty else { return Result(score: 0, positions: []) }
        guard !text.isEmpty else { return nil }

        let patternChars = Array(pattern.lowercased())
        let textChars = Array(text)
        let textLower = Array(text.lowercased())

        let n = textChars.count
        let m = patternChars.count

        guard m <= n else { return nil }

        var patternIdx = 0
        for char in textLower {
            if char == patternChars[patternIdx] {
                patternIdx += 1
                if patternIdx == m { break }
            }
        }
        guard patternIdx == m else { return nil }

        var positions = [Int](repeating: -1, count: m)

        patternIdx = 0
        for (textIdx, char) in textLower.enumerated() {
            if patternIdx < m && char == patternChars[patternIdx] {
                positions[patternIdx] = textIdx
                patternIdx += 1
            }
        }

        let score = calculateScore(positions: positions, textChars: textChars)
        return Result(score: score, positions: positions)
    }

    private static func calculateScore(positions: [Int], textChars: [Character]) -> Int {
        guard !positions.isEmpty else { return 0 }

        var score = 0
        var prevPos = -1

        for pos in positions {
            score += scoreMatch

            if pos == 0 {
                score += bonusFirstChar
            }

            if prevPos >= 0 && pos == prevPos + 1 {
                score += bonusConsecutive
            } else if prevPos >= 0 {
                let gap = pos - prevPos - 1
                score += scoreGapStart + (gap - 1) * scoreGapExtension
            }

            if pos > 0 {
                let prevChar = textChars[pos - 1]
                let currChar = textChars[pos]

                if prevChar == "/" || prevChar == "\\" {
                    score += bonusAfterSlash
                } else if prevChar == " " || prevChar == "_" || prevChar == "-" {
                    score += bonusAfterSpace
                } else if prevChar.isLowercase && currChar.isUppercase {
                    score += bonusCamelCase
                } else if !prevChar.isLetter && currChar.isLetter {
                    score += bonusBoundary
                }
            }

            prevPos = pos
        }

        return score
    }
}

func runFuzzyMatchTests(dbQueue: DatabaseQueue) throws -> [PerformanceResult] {
    var results: [PerformanceResult] = []

    print("\n🔍 Running fuzzy match performance tests...")

    // Load sample items for fuzzy testing
    let sampleItems: [String] = try dbQueue.read { db in
        try String.fetchAll(db, sql: "SELECT content FROM items ORDER BY timestamp DESC LIMIT 1000")
    }

    let testQueries = ["fn", "usr", "cfg", "async", "fetch", "getData", "handleReq", "processUserData"]

    for query in testQueries {
        let iterations = 10
        var totalTime: TimeInterval = 0
        var matchCount = 0

        for _ in 0..<iterations {
            totalTime += measureTime {
                for item in sampleItems {
                    if FuzzyMatch.match(pattern: query, in: item) != nil {
                        matchCount += 1
                    }
                }
            }
        }

        results.append(PerformanceResult(
            name: "Fuzzy '\(query)' on 1000 items",
            duration: totalTime,
            iterations: iterations
        ))
    }

    return results
}

// MARK: - Main

func main(targetSizeGB: Double) throws {
    let targetSizeBytes = TestConfig.targetSizeBytes(forGB: targetSizeGB)

    print("╔════════════════════════════════════════════════════════════════╗")
    print("║         ClippySwift Performance Test Harness                    ║")
    print("╚════════════════════════════════════════════════════════════════╝")
    print("")

    let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("clippy-perf-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

    let dbPath = testDir.appendingPathComponent("test-clipboard.sqlite").path

    print("📁 Test database: \(dbPath)")
    print("🎯 Target size: \(formatBytes(targetSizeBytes))")
    print("")

    let dbQueue = try createTestDatabase(at: dbPath)

    // Generate data until we hit target size
    print("📝 Generating test data...")

    var itemCount = 0
    var lastProgressUpdate = Date()
    let batchSize = 1000

    while getDatabaseSize(at: dbPath) < targetSizeBytes {
        try dbQueue.write { db in
            for _ in 0..<batchSize {
                let contentType = ContentType.random()
                let contentLength = ContentLength.random()
                let content = ContentGenerator.generateContent(type: contentType, length: contentLength)
                let hash = String(content.hashValue)
                let timestamp = Date().addingTimeInterval(-Double.random(in: 0...(365 * 24 * 60 * 60))) // Random time in last year
                let sourceApp = ContentGenerator.randomSourceApp()

                try db.execute(sql: """
                    INSERT INTO items (content, contentHash, timestamp, sourceApp) VALUES (?, ?, ?, ?)
                """, arguments: [content, hash, timestamp, sourceApp])

                itemCount += 1
            }
        }

        // Progress update every 5 seconds
        if Date().timeIntervalSince(lastProgressUpdate) > 5 {
            let currentSize = getDatabaseSize(at: dbPath)
            let progress = Double(currentSize) / Double(targetSizeBytes) * 100
            print("   Progress: \(formatBytes(currentSize)) / \(formatBytes(targetSizeBytes)) (\(String(format: "%.1f", progress))%) - \(itemCount) items")
            lastProgressUpdate = Date()
        }
    }

    let finalSize = getDatabaseSize(at: dbPath)
    print("\n✅ Database generated:")
    print("   Size: \(formatBytes(finalSize))")
    print("   Items: \(itemCount)")

    // Verify data diversity
    print("\n📊 Data diversity check:")
    try dbQueue.read { db in
        let avgLength = try Double.fetchOne(db, sql: "SELECT AVG(LENGTH(content)) FROM items") ?? 0
        let minLength = try Int.fetchOne(db, sql: "SELECT MIN(LENGTH(content)) FROM items") ?? 0
        let maxLength = try Int.fetchOne(db, sql: "SELECT MAX(LENGTH(content)) FROM items") ?? 0
        let uniqueApps = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT sourceApp) FROM items") ?? 0

        print("   Avg content length: \(String(format: "%.0f", avgLength)) chars")
        print("   Min/Max length: \(minLength) / \(maxLength) chars")
        print("   Unique source apps: \(uniqueApps)")
    }

    // Run performance tests
    let dbResults = try runPerformanceTests(dbQueue: dbQueue, itemCount: itemCount)

    print("\n📈 Database Performance Results:")
    print("   " + String(repeating: "─", count: 60))
    for result in dbResults {
        print(result.description)
    }

    // Run fuzzy match tests
    let fuzzyResults = try runFuzzyMatchTests(dbQueue: dbQueue)

    print("\n📈 Fuzzy Match Performance Results:")
    print("   " + String(repeating: "─", count: 60))
    for result in fuzzyResults {
        print(result.description)
    }

    // Summary
    print("\n" + String(repeating: "═", count: 68))
    print("📋 SUMMARY")
    print(String(repeating: "═", count: 68))

    let criticalOps = ["Load first page", "Short search", "Insert new item", "Hash duplicate check"]
    let allResults = dbResults + fuzzyResults

    for result in allResults {
        for criticalOp in criticalOps {
            if result.name.contains(criticalOp) {
                let status = result.avgDuration < 0.1 ? "✅" : (result.avgDuration < 0.5 ? "⚠️" : "❌")
                print("\(status) \(result.name): \(String(format: "%.1f", result.avgDuration * 1000))ms avg")
            }
        }
    }

    // Cleanup option
    print("\n🧹 Cleanup:")
    print("   Test database at: \(dbPath)")
    print("   To remove: rm -rf \(testDir.path)")

    print("\n✨ Performance testing complete!")
}

// Run
do {
    // Parse command line args for size
    let args = CommandLine.arguments
    var targetSizeGB = 3.0
    if args.count > 1, let size = Double(args[1]) {
        targetSizeGB = size
    }
    try main(targetSizeGB: targetSizeGB)
} catch {
    print("❌ Error: \(error)")
    exit(1)
}
