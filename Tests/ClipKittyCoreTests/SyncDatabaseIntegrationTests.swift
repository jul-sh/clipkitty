import Testing
import Foundation
import GRDB
@testable import ClipKittyCore

/// Integration tests for sync database operations
/// Uses in-memory database to test actual SQL behavior
@Suite("Sync Database Integration")
struct SyncDatabaseIntegrationTests {

    /// Creates an in-memory database with the sync schema
    private func makeTestDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            try db.create(table: "items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("content", .text).notNull()
                t.column("contentHash", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("sourceApp", .text)
                t.column("contentType", .text).defaults(to: "text")
                t.column("imageData", .blob)
                t.column("linkTitle", .text)
                t.column("linkImageData", .blob)
                t.column("syncRecordID", .text)
                t.column("syncStatus", .text).defaults(to: "local")
                t.column("modifiedAt", .datetime)
                t.column("deviceID", .text)
            }

            try db.create(index: "idx_items_hash", on: "items", columns: ["contentHash"])
            try db.create(index: "idx_items_sync", on: "items", columns: ["syncStatus"])
        }

        return dbQueue
    }

    // MARK: - Basic Insert/Query

    @Test("Insert local item and query sync status")
    func insertLocalItem() throws {
        let db = try makeTestDatabase()

        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO items (content, contentHash, timestamp, syncStatus, contentType)
                    VALUES (?, ?, ?, 'local', 'text')
                """,
                arguments: ["Hello", "hash123", Date()]
            )
        }

        let status = try db.read { db in
            try String.fetchOne(db, sql: "SELECT syncStatus FROM items WHERE contentHash = ?", arguments: ["hash123"])
        }

        #expect(status == "local")
    }

    @Test("Insert pending item with device metadata")
    func insertPendingItem() throws {
        let db = try makeTestDatabase()
        let deviceID = "test-device"
        let modifiedAt = Date()

        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO items (content, contentHash, timestamp, syncStatus, deviceID, modifiedAt, contentType)
                    VALUES (?, ?, ?, 'pending', ?, ?, 'text')
                """,
                arguments: ["Pending content", "hash-pending", Date(), deviceID, modifiedAt]
            )
        }

        let row = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT syncStatus, deviceID, modifiedAt FROM items WHERE contentHash = ?", arguments: ["hash-pending"])
        }

        #expect(row?["syncStatus"] as? String == "pending")
        #expect(row?["deviceID"] as? String == deviceID)
        // modifiedAt is stored as Double (REAL), GRDB retrieves it correctly as Date
        let storedDate: Date? = row?["modifiedAt"]
        #expect(storedDate != nil)
    }

    @Test("Update item to synced status")
    func updateToSynced() throws {
        let db = try makeTestDatabase()
        let recordID = "cloudkit-record-abc"

        // Insert pending item
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO items (content, contentHash, timestamp, syncStatus, deviceID, modifiedAt, contentType)
                    VALUES (?, ?, ?, 'pending', 'device1', ?, 'text')
                """,
                arguments: ["Content to sync", "hash-sync", Date(), Date()]
            )
        }

        // Mark as synced
        let newModifiedAt = Date()
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE items
                    SET syncStatus = 'synced', syncRecordID = ?, modifiedAt = ?
                    WHERE contentHash = ?
                """,
                arguments: [recordID, newModifiedAt, "hash-sync"]
            )
        }

        let row = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT syncStatus, syncRecordID FROM items WHERE contentHash = ?", arguments: ["hash-sync"])
        }

        #expect(row?["syncStatus"] as? String == "synced")
        #expect(row?["syncRecordID"] as? String == recordID)
    }

    // MARK: - Conflict Resolution Tests

    @Test("Last-writer-wins: remote newer overwrites local synced")
    func lastWriterWinsRemoteNewer() throws {
        let db = try makeTestDatabase()
        let contentHash = "conflict-hash"
        let localModifiedAt = Date(timeIntervalSince1970: 1000)
        let remoteModifiedAt = Date(timeIntervalSince1970: 2000)  // Newer

        // Insert local synced item
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO items (content, contentHash, timestamp, syncStatus, modifiedAt, deviceID, contentType)
                    VALUES ('local content', ?, ?, 'synced', ?, 'device-local', 'text')
                """,
                arguments: [contentHash, Date(), localModifiedAt]
            )
        }

        // Simulate upsertFromCloud logic
        try db.write { db in
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT modifiedAt, syncStatus FROM items WHERE contentHash = ?",
                arguments: [contentHash]
            )

            let existingModifiedAt = existing?["modifiedAt"] as? Date ?? Date.distantPast
            let existingStatus = existing?["syncStatus"] as? String

            // Last-writer-wins: update if remote is newer (for non-pending items)
            let shouldUpdate = existingStatus != "pending" && remoteModifiedAt >= existingModifiedAt

            if shouldUpdate {
                try db.execute(
                    sql: "UPDATE items SET content = 'remote content', modifiedAt = ?, deviceID = 'device-remote' WHERE contentHash = ?",
                    arguments: [remoteModifiedAt, contentHash]
                )
            }
        }

        let content = try db.read { db in
            try String.fetchOne(db, sql: "SELECT content FROM items WHERE contentHash = ?", arguments: [contentHash])
        }

        #expect(content == "remote content")
    }

    @Test("Last-writer-wins: local pending not overwritten by older remote")
    func lastWriterWinsLocalPendingPreserved() throws {
        let db = try makeTestDatabase()
        let contentHash = "pending-conflict-hash"
        let localModifiedAt = Date(timeIntervalSince1970: 2000)  // Newer
        let remoteModifiedAt = Date(timeIntervalSince1970: 1000)  // Older

        // Insert local pending item (has local changes not yet pushed)
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO items (content, contentHash, timestamp, syncStatus, modifiedAt, deviceID, contentType)
                    VALUES ('local pending content', ?, ?, 'pending', ?, 'device-local', 'text')
                """,
                arguments: [contentHash, Date(), localModifiedAt]
            )
        }

        // Simulate upsertFromCloud logic - should NOT overwrite pending with older remote
        try db.write { db in
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT modifiedAt, syncStatus FROM items WHERE contentHash = ?",
                arguments: [contentHash]
            )

            // GRDB returns Date directly when column type matches
            let existingModifiedAt: Date = existing?["modifiedAt"] ?? Date.distantPast
            let existingStatus = existing?["syncStatus"] as? String

            // For pending items, only update if remote is strictly newer
            let shouldUpdate: Bool
            if existingStatus == "pending" {
                shouldUpdate = remoteModifiedAt > existingModifiedAt
            } else {
                shouldUpdate = remoteModifiedAt >= existingModifiedAt
            }

            if shouldUpdate {
                try db.execute(
                    sql: "UPDATE items SET content = 'remote content', modifiedAt = ? WHERE contentHash = ?",
                    arguments: [remoteModifiedAt, contentHash]
                )
            }
        }

        let content = try db.read { db in
            try String.fetchOne(db, sql: "SELECT content FROM items WHERE contentHash = ?", arguments: [contentHash])
        }

        // Local pending content should be preserved because remote is older
        #expect(content == "local pending content")
    }

    @Test("Last-writer-wins: local pending overwritten by newer remote")
    func lastWriterWinsLocalPendingOverwrittenByNewer() throws {
        let db = try makeTestDatabase()
        let contentHash = "pending-newer-remote"
        let localModifiedAt = Date(timeIntervalSince1970: 1000)
        let remoteModifiedAt = Date(timeIntervalSince1970: 2000)  // Newer

        // Insert local pending item
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO items (content, contentHash, timestamp, syncStatus, modifiedAt, deviceID, contentType)
                    VALUES ('local pending', ?, ?, 'pending', ?, 'device-local', 'text')
                """,
                arguments: [contentHash, Date(), localModifiedAt]
            )
        }

        // Remote is newer - should overwrite even pending
        try db.write { db in
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT modifiedAt, syncStatus FROM items WHERE contentHash = ?",
                arguments: [contentHash]
            )

            let existingModifiedAt = existing?["modifiedAt"] as? Date ?? Date.distantPast
            let existingStatus = existing?["syncStatus"] as? String

            let shouldUpdate: Bool
            if existingStatus == "pending" {
                shouldUpdate = remoteModifiedAt > existingModifiedAt
            } else {
                shouldUpdate = remoteModifiedAt >= existingModifiedAt
            }

            if shouldUpdate {
                try db.execute(
                    sql: "UPDATE items SET content = 'remote wins', modifiedAt = ?, syncStatus = 'synced' WHERE contentHash = ?",
                    arguments: [remoteModifiedAt, contentHash]
                )
            }
        }

        let row = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT content, syncStatus FROM items WHERE contentHash = ?", arguments: [contentHash])
        }

        #expect(row?["content"] as? String == "remote wins")
        #expect(row?["syncStatus"] as? String == "synced")
    }

    // MARK: - Query Tests

    @Test("Query pending items for sync")
    func queryPendingItems() throws {
        let db = try makeTestDatabase()

        // Insert mix of items
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO items (content, contentHash, timestamp, syncStatus, contentType) VALUES ('local', 'h1', ?, 'local', 'text')",
                arguments: [Date()]
            )
            try db.execute(
                sql: "INSERT INTO items (content, contentHash, timestamp, syncStatus, deviceID, modifiedAt, contentType) VALUES ('pending1', 'h2', ?, 'pending', 'd1', ?, 'text')",
                arguments: [Date(), Date()]
            )
            try db.execute(
                sql: "INSERT INTO items (content, contentHash, timestamp, syncStatus, deviceID, modifiedAt, contentType) VALUES ('pending2', 'h3', ?, 'pending', 'd1', ?, 'text')",
                arguments: [Date(), Date()]
            )
            try db.execute(
                sql: "INSERT INTO items (content, contentHash, timestamp, syncStatus, syncRecordID, contentType) VALUES ('synced', 'h4', ?, 'synced', 'r1', 'text')",
                arguments: [Date()]
            )
        }

        let pendingCount = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE syncStatus = 'pending'")
        }

        #expect(pendingCount == 2)
    }

    @Test("Query synced items for library size calculation")
    func querySyncedItemsSize() throws {
        let db = try makeTestDatabase()

        try db.write { db in
            try db.execute(
                sql: "INSERT INTO items (content, contentHash, timestamp, syncStatus, syncRecordID, contentType) VALUES ('small', 'h1', ?, 'synced', 'r1', 'text')",
                arguments: [Date()]
            )
            try db.execute(
                sql: "INSERT INTO items (content, contentHash, timestamp, syncStatus, syncRecordID, contentType) VALUES ('medium content here', 'h2', ?, 'synced', 'r2', 'text')",
                arguments: [Date()]
            )
            try db.execute(
                sql: "INSERT INTO items (content, contentHash, timestamp, syncStatus, contentType) VALUES ('not synced', 'h3', ?, 'local', 'text')",
                arguments: [Date()]
            )
        }

        let syncedContents = try db.read { db in
            try String.fetchAll(db, sql: "SELECT content FROM items WHERE syncStatus = 'synced' ORDER BY timestamp")
        }

        #expect(syncedContents.count == 2)
        #expect(syncedContents.contains("small"))
        #expect(syncedContents.contains("medium content here"))
    }

    // MARK: - Deletion Tests

    @Test("Delete by syncRecordID")
    func deleteBySyncRecordID() throws {
        let db = try makeTestDatabase()
        let recordID = "delete-me-record"

        try db.write { db in
            try db.execute(
                sql: "INSERT INTO items (content, contentHash, timestamp, syncStatus, syncRecordID, contentType) VALUES ('to delete', 'h1', ?, 'synced', ?, 'text')",
                arguments: [Date(), recordID]
            )
            try db.execute(
                sql: "INSERT INTO items (content, contentHash, timestamp, syncStatus, syncRecordID, contentType) VALUES ('keep this', 'h2', ?, 'synced', 'other-record', 'text')",
                arguments: [Date()]
            )
        }

        try db.write { db in
            try db.execute(
                sql: "DELETE FROM items WHERE syncRecordID = ?",
                arguments: [recordID]
            )
        }

        let remainingCount = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items")
        }

        #expect(remainingCount == 1)
    }

    // MARK: - Pruning Tests

    @Test("Prune synced items by marking as local")
    func pruneSyncedItems() throws {
        let db = try makeTestDatabase()

        // Insert items with different timestamps (older first)
        let oldDate = Date(timeIntervalSince1970: 1000)
        let newDate = Date(timeIntervalSince1970: 2000)

        try db.write { db in
            try db.execute(
                sql: "INSERT INTO items (content, contentHash, timestamp, syncStatus, syncRecordID, contentType) VALUES ('old item', 'h1', ?, 'synced', 'r1', 'text')",
                arguments: [oldDate]
            )
            try db.execute(
                sql: "INSERT INTO items (content, contentHash, timestamp, syncStatus, syncRecordID, contentType) VALUES ('new item', 'h2', ?, 'synced', 'r2', 'text')",
                arguments: [newDate]
            )
        }

        // Prune oldest item (mark as local)
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE items
                    SET syncStatus = 'local', syncRecordID = NULL
                    WHERE id IN (
                        SELECT id FROM items
                        WHERE syncStatus = 'synced'
                        ORDER BY timestamp ASC
                        LIMIT 1
                    )
                """
            )
        }

        let syncedCount = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE syncStatus = 'synced'")
        }
        let localCount = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE syncStatus = 'local'")
        }

        #expect(syncedCount == 1)
        #expect(localCount == 1)
    }
}
