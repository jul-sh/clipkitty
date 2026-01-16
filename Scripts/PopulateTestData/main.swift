import Foundation
import GRDB
import ClipKittyCore

// MARK: - Test Data

enum TestContent {
    case text(String, sourceApp: String?, bundleID: String?)
    case link(String, sourceApp: String?, bundleID: String?)
}

let testItems: [TestContent] = [
    // Email address
    .text("sarah.johnson@techcorp.io", sourceApp: "Mail", bundleID: "com.apple.mail"),

    // Phone number
    .text("+1 (555) 867-5309", sourceApp: "Contacts", bundleID: "com.apple.AddressBook"),

    // UUID
    .text("f47ac10b-58cc-4372-a567-0e02b2c3d479", sourceApp: "Terminal", bundleID: "com.apple.Terminal"),

    // JSON snippet
    .text("""
    {
      "user": {
        "id": 42,
        "name": "Alice Chen",
        "roles": ["admin", "developer"]
      }
    }
    """, sourceApp: "VS Code", bundleID: "com.microsoft.VSCode"),

    // URL - GitHub repo
    .link("https://github.com/apple/swift-collections", sourceApp: "Safari", bundleID: "com.apple.Safari"),

    // Swift code snippet
    .text("""
    func fetchUsers() async throws -> [User] {
        let response = try await client.get("/api/users")
        return try decoder.decode([User].self, from: response.data)
    }
    """, sourceApp: "Xcode", bundleID: "com.apple.dt.Xcode"),

    // SQL query
    .text("""
    SELECT u.name, COUNT(o.id) as order_count
    FROM users u
    LEFT JOIN orders o ON u.id = o.user_id
    WHERE u.created_at > '2024-01-01'
    GROUP BY u.id
    HAVING order_count > 5;
    """, sourceApp: "TablePlus", bundleID: "com.tinyapp.TablePlus"),

    // URL - Documentation
    .link("https://developer.apple.com/documentation/swiftui/view", sourceApp: "Safari", bundleID: "com.apple.Safari"),

    // Terminal command
    .text("git log --oneline --graph --all -20", sourceApp: "Terminal", bundleID: "com.apple.Terminal"),

    // Street address
    .text("1 Infinite Loop, Cupertino, CA 95014", sourceApp: "Maps", bundleID: "com.apple.Maps"),

    // CSS snippet
    .text("""
    .container {
      display: flex;
      justify-content: center;
      gap: 1rem;
      padding: 2rem;
    }
    """, sourceApp: "VS Code", bundleID: "com.microsoft.VSCode"),

    // URL - Stack Overflow
    .link("https://stackoverflow.com/questions/24002369/how-to-call-objective-c-code-from-swift", sourceApp: "Arc", bundleID: "company.thebrowser.Browser"),

    // Error message
    .text("Error: SQLITE_CONSTRAINT: UNIQUE constraint failed: users.email", sourceApp: "Terminal", bundleID: "com.apple.Terminal"),

    // Python code
    .text("""
    def calculate_metrics(data: list[dict]) -> dict:
        return {
            "count": len(data),
            "avg": sum(d["value"] for d in data) / len(data)
        }
    """, sourceApp: "PyCharm", bundleID: "com.jetbrains.pycharm"),

    // Markdown text
    .text("""
    ## Quick Start

    1. Install dependencies: `npm install`
    2. Run dev server: `npm run dev`
    3. Open http://localhost:3000
    """, sourceApp: "Obsidian", bundleID: "md.obsidian"),

    // API endpoint
    .link("https://api.stripe.com/v1/customers", sourceApp: "Postman", bundleID: "com.postmanlabs.mac"),

    // Regex pattern
    .text(#"^(?=.*[A-Z])(?=.*[a-z])(?=.*\d)[A-Za-z\d@$!%*?&]{8,}$"#, sourceApp: "VS Code", bundleID: "com.microsoft.VSCode"),

    // Shell script snippet
    .text("""
    for file in *.json; do
        jq '.data[] | select(.active == true)' "$file"
    done
    """, sourceApp: "Terminal", bundleID: "com.apple.Terminal"),

    // URL - YouTube
    .link("https://www.youtube.com/watch?v=dQw4w9WgXcQ", sourceApp: "Arc", bundleID: "company.thebrowser.Browser"),

    // TypeScript interface
    .text("""
    interface UserProfile {
      id: string;
      email: string;
      preferences: {
        theme: 'light' | 'dark';
        notifications: boolean;
      };
    }
    """, sourceApp: "VS Code", bundleID: "com.microsoft.VSCode"),
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
