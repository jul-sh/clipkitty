import Foundation
import GRDB
import ClipKittyCore

// MARK: - Test Data

enum TestContent {
    case text(String, sourceApp: String?, bundleID: String?)
    case link(String, sourceApp: String?, bundleID: String?)
}

// Items ordered for best screenshot appearance - most recent at top
// Only uses built-in macOS apps that are guaranteed on every system
let testItems: [TestContent] = [
    // 1. Swift code - will be selected and shown in preview
    .text("""
    func fetchUsers() async throws -> [User] {
        let url = URL(string: "https://api.example.com/users")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([User].self, from: data)
    }
    """, sourceApp: "Terminal", bundleID: "com.apple.Terminal"),

    // 2. JSON - shows multiline content handling
    .text("""
    {
      "user": {
        "id": 42,
        "name": "Alice Chen",
        "email": "alice@example.com",
        "roles": ["admin", "developer"]
      }
    }
    """, sourceApp: "Mail", bundleID: "com.apple.mail"),

    // 3. GitHub link
    .link("https://github.com/apple/swift", sourceApp: "Safari", bundleID: "com.apple.Safari"),

    // 4. SQL query - shows another code type
    .text("""
    SELECT users.name, COUNT(orders.id) AS total
    FROM users
    JOIN orders ON users.id = orders.user_id
    GROUP BY users.id
    ORDER BY total DESC
    LIMIT 10;
    """, sourceApp: "Terminal", bundleID: "com.apple.Terminal"),

    // 5. Terminal command
    .text("git clone https://github.com/clipkitty/clipkitty.git", sourceApp: "Terminal", bundleID: "com.apple.Terminal"),

    // 6. Email address
    .text("contact@example.com", sourceApp: "Mail", bundleID: "com.apple.mail"),

    // 7. Configuration text
    .text("""
    server {
        listen 80;
        server_name example.com;
        root /var/www/html;
    }
    """, sourceApp: "Terminal", bundleID: "com.apple.Terminal"),

    // 8. Apple Developer documentation link
    .link("https://developer.apple.com/documentation/swiftui", sourceApp: "Safari", bundleID: "com.apple.Safari"),

    // 9. UUID
    .text("550e8400-e29b-41d4-a716-446655440000", sourceApp: "Terminal", bundleID: "com.apple.Terminal"),

    // 10. SSH command
    .text("ssh -i ~/.ssh/id_rsa user@example.com -p 2222", sourceApp: "Terminal", bundleID: "com.apple.Terminal"),

    // 11. API endpoint URL
    .link("https://api.example.com/v1/users", sourceApp: "Safari", bundleID: "com.apple.Safari"),

    // 12. Environment variables
    .text("""
    export DATABASE_URL=postgresql://user:pass@localhost/db
    export API_KEY=sk_live_abc123xyz
    export DEBUG=true
    """, sourceApp: "Terminal", bundleID: "com.apple.Terminal"),

    // 13. Documentation link
    .link("https://www.apple.com", sourceApp: "Safari", bundleID: "com.apple.Safari"),

    // 14. Code snippet
    .text("let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in print(\"tick\") }", sourceApp: "Mail", bundleID: "com.apple.mail"),

    // 15. Quick note
    .text("Remember to update the changelog and tag the release before pushing to production", sourceApp: "Terminal", bundleID: "com.apple.Terminal"),
]

// MARK: - Database Operations

// Use separate database for screenshots to preserve user's real data
let screenshotDatabaseFilename = "clipboard-screenshot.sqlite"

func getDatabasePaths() -> [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser

    // Container path (for sandboxed app)
    let containerPath = home
        .appendingPathComponent("Library/Containers/com.clipkitty.app/Data/Library/Application Support/ClipKitty", isDirectory: true)

    // Regular path (for non-sandboxed app / ad-hoc signed)
    let regularPath = home
        .appendingPathComponent("Library/Application Support/ClipKitty", isDirectory: true)

    try? FileManager.default.createDirectory(at: containerPath, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: regularPath, withIntermediateDirectories: true)

    return [
        containerPath.appendingPathComponent(screenshotDatabaseFilename).path,
        regularPath.appendingPathComponent(screenshotDatabaseFilename).path
    ]
}

func populateDatabase() throws {
    // Populate both paths since ad-hoc signing may not enforce sandbox
    for dbPath in getDatabasePaths() {
        print("📂 Database: \(dbPath)")
        try populateDatabaseAt(path: dbPath)
    }
}

func populateDatabaseAt(path dbPath: String) throws {
    let dbQueue = try DatabaseQueue(path: dbPath)

    try dbQueue.write { db in
        // Create table if not exists
        try db.create(table: ClipboardItem.databaseTableName, ifNotExists: true) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("content", .text).notNull()
            t.column("contentHash", .text).notNull()
            t.column("timestamp", .datetime).notNull()
            t.column("sourceApp", .text)
            t.column("sourceAppBundleID", .text)
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
        for (index, testContent) in testItems.enumerated() {
            let timestamp = now.addingTimeInterval(Double(-index * 300)) // 5 min apart

            let item: ClipboardItem
            switch testContent {
            case .text(let content, let sourceApp, let bundleID):
                item = ClipboardItem(text: content, sourceApp: sourceApp, sourceAppBundleID: bundleID, timestamp: timestamp)
            case .link(let url, let sourceApp, let bundleID):
                item = ClipboardItem(url: url, sourceApp: sourceApp, sourceAppBundleID: bundleID, timestamp: timestamp)
            }

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

}

// MARK: - Main

print("📋 Populating ClipKitty database with test data...")

do {
    try populateDatabase()
    print("✅ Inserted \(testItems.count) items to both database locations")
} catch {
    print("❌ Error: \(error)")
    exit(1)
}
