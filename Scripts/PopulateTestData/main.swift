import Foundation
import GRDB

// MARK: - Types (mirroring ClipboardItem.swift)

enum ContentType: String, Codable, DatabaseValueConvertible {
    case text
    case link
    case image
}

struct ClipboardItem: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "items"

    var id: Int64?
    let content: String
    let contentHash: String
    let timestamp: Date
    let sourceApp: String?
    let contentType: ContentType
    let imageData: Data?
    var linkTitle: String?
    var linkImageData: Data?

    init(content: String, sourceApp: String? = nil, contentType: ContentType? = nil, timestamp: Date = Date()) {
        self.id = nil
        self.content = content
        self.contentHash = Self.hash(content)
        self.timestamp = timestamp
        self.sourceApp = sourceApp
        self.imageData = nil
        self.linkTitle = nil
        self.linkImageData = nil

        if let type = contentType {
            self.contentType = type
        } else if Self.isURL(content) {
            self.contentType = .link
        } else {
            self.contentType = .text
        }
    }

    static func isURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count < 2000, !trimmed.contains("\n") else { return false }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed) != nil
        }
        if trimmed.hasPrefix("www.") {
            return URL(string: "https://\(trimmed)") != nil
        }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return false
        }
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        guard let match = detector.firstMatch(in: trimmed, options: [], range: range) else {
            return false
        }
        guard match.range.length == range.length else { return false }
        if let url = match.url {
            return url.scheme == "http" || url.scheme == "https"
        }
        return false
    }

    private static func hash(_ string: String) -> String {
        var hasher = Hasher()
        hasher.combine(string)
        return String(hasher.finalize())
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Test Data

struct TestData {
    let content: String
    let sourceApp: String?
    let contentType: ContentType?

    init(_ content: String, sourceApp: String? = nil, contentType: ContentType? = nil) {
        self.content = content
        self.sourceApp = sourceApp
        self.contentType = contentType
    }
}

let testItems: [TestData] = [
    // Email address
    TestData("sarah.johnson@techcorp.io", sourceApp: "Mail"),

    // Phone number
    TestData("+1 (555) 867-5309", sourceApp: "Contacts"),

    // UUID
    TestData("f47ac10b-58cc-4372-a567-0e02b2c3d479", sourceApp: "Terminal"),

    // JSON snippet
    TestData("""
    {
      "user": {
        "id": 42,
        "name": "Alice Chen",
        "roles": ["admin", "developer"]
      }
    }
    """, sourceApp: "VS Code"),

    // URL - GitHub repo
    TestData("https://github.com/apple/swift-collections", sourceApp: "Safari", contentType: .link),

    // Swift code snippet
    TestData("""
    func fetchUsers() async throws -> [User] {
        let response = try await client.get("/api/users")
        return try decoder.decode([User].self, from: response.data)
    }
    """, sourceApp: "Xcode"),

    // SQL query
    TestData("""
    SELECT u.name, COUNT(o.id) as order_count
    FROM users u
    LEFT JOIN orders o ON u.id = o.user_id
    WHERE u.created_at > '2024-01-01'
    GROUP BY u.id
    HAVING order_count > 5;
    """, sourceApp: "TablePlus"),

    // URL - Documentation
    TestData("https://developer.apple.com/documentation/swiftui/view", sourceApp: "Safari", contentType: .link),

    // Terminal command
    TestData("git log --oneline --graph --all -20", sourceApp: "Terminal"),

    // Street address
    TestData("1 Infinite Loop, Cupertino, CA 95014", sourceApp: "Maps"),

    // CSS snippet
    TestData("""
    .container {
      display: flex;
      justify-content: center;
      gap: 1rem;
      padding: 2rem;
    }
    """, sourceApp: "VS Code"),

    // URL - Stack Overflow
    TestData("https://stackoverflow.com/questions/24002369/how-to-call-objective-c-code-from-swift", sourceApp: "Arc", contentType: .link),

    // Error message
    TestData("Error: SQLITE_CONSTRAINT: UNIQUE constraint failed: users.email", sourceApp: "Terminal"),

    // Python code
    TestData("""
    def calculate_metrics(data: list[dict]) -> dict:
        return {
            "count": len(data),
            "avg": sum(d["value"] for d in data) / len(data)
        }
    """, sourceApp: "PyCharm"),

    // Markdown text
    TestData("""
    ## Quick Start

    1. Install dependencies: `npm install`
    2. Run dev server: `npm run dev`
    3. Open http://localhost:3000
    """, sourceApp: "Obsidian"),

    // API endpoint
    TestData("https://api.stripe.com/v1/customers", sourceApp: "Postman", contentType: .link),

    // Regex pattern
    TestData(#"^(?=.*[A-Z])(?=.*[a-z])(?=.*\d)[A-Za-z\d@$!%*?&]{8,}$"#, sourceApp: "VS Code"),

    // Shell script snippet
    TestData("""
    for file in *.json; do
        jq '.data[] | select(.active == true)' "$file"
    done
    """, sourceApp: "Terminal"),

    // URL - YouTube
    TestData("https://www.youtube.com/watch?v=dQw4w9WgXcQ", sourceApp: "Arc", contentType: .link),

    // TypeScript interface
    TestData("""
    interface UserProfile {
      id: string;
      email: string;
      preferences: {
        theme: 'light' | 'dark';
        notifications: boolean;
      };
    }
    """, sourceApp: "VS Code"),
]

// MARK: - Database Operations

func getDatabasePath() -> String {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let appDir = appSupport.appendingPathComponent("ClipKitty", isDirectory: true)
    try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
    return appDir.appendingPathComponent("clipboard.sqlite").path
}

func populateDatabase() throws {
    let dbPath = getDatabasePath()
    print("📂 Database: \(dbPath)")

    let dbQueue = try DatabaseQueue(path: dbPath)

    try dbQueue.write { db in
        // Create table if not exists
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

        try db.create(index: "idx_items_hash", on: "items", columns: ["contentHash"], ifNotExists: true)
        try db.create(index: "idx_items_timestamp", on: "items", columns: ["timestamp"], ifNotExists: true)

        // Clear existing items
        try db.execute(sql: "DELETE FROM items")

        // Insert test items with varying timestamps
        let now = Date()
        for (index, testData) in testItems.enumerated() {
            let timestamp = now.addingTimeInterval(Double(-index * 300)) // 5 min apart
            let item = ClipboardItem(
                content: testData.content,
                sourceApp: testData.sourceApp,
                contentType: testData.contentType,
                timestamp: timestamp
            )
            try item.insert(db)
        }

        // Rebuild FTS index
        try db.execute(sql: "DROP TABLE IF EXISTS items_fts")
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
                content, content=items, content_rowid=id, tokenize='trigram'
            )
        """)
        try db.execute(sql: "INSERT INTO items_fts(items_fts) VALUES('rebuild')")

        // Recreate triggers
        try db.execute(sql: "DROP TRIGGER IF EXISTS items_ai")
        try db.execute(sql: "DROP TRIGGER IF EXISTS items_ad")
        try db.execute(sql: "DROP TRIGGER IF EXISTS items_au")

        try db.execute(sql: """
            CREATE TRIGGER items_ai AFTER INSERT ON items BEGIN
                INSERT INTO items_fts(rowid, content) VALUES (new.id, new.content);
            END
        """)
        try db.execute(sql: """
            CREATE TRIGGER items_ad AFTER DELETE ON items BEGIN
                INSERT INTO items_fts(items_fts, rowid, content) VALUES('delete', old.id, old.content);
            END
        """)
        try db.execute(sql: """
            CREATE TRIGGER items_au AFTER UPDATE ON items BEGIN
                INSERT INTO items_fts(items_fts, rowid, content) VALUES('delete', old.id, old.content);
                INSERT INTO items_fts(rowid, content) VALUES (new.id, new.content);
            END
        """)
    }

    print("✅ Inserted \(testItems.count) items")
}

// MARK: - Main

print("📋 Populating ClipKitty database with test data...")

do {
    try populateDatabase()
    print("✅ Done!")
} catch {
    print("❌ Error: \(error)")
    exit(1)
}
