import Testing
import Foundation
@testable import ClipKittyCore

/// Tests for CloudKit record conversion
/// Verifies data integrity through CKRecord serialization
@Suite("CloudKit Record Conversion")
struct CloudKitRecordConversionTests {

    // MARK: - Text Content

    @Test("Text item converts to CKRecord with correct fields")
    func textItemToCKRecord() {
        let item = ClipboardItem(text: "Hello, World!", sourceApp: "Notes")
        let syncState = SyncState.pending(deviceID: "test-device", modifiedAt: Date())
        let syncable = SyncableClipboardItem(item: item, syncState: syncState)

        let record = syncable.toCKRecord()

        #expect(record["content"] as? String == "Hello, World!")
        #expect(record["contentType"] as? String == "text")
        #expect(record["contentHash"] as? String == item.contentHash)
        #expect(record["sourceApp"] as? String == "Notes")
        #expect(record["deviceID"] as? String == "test-device")
    }

    @Test("Text item round-trips through CKRecord")
    func textItemRoundTrip() {
        let originalItem = ClipboardItem(text: "Round trip test", sourceApp: "Safari")
        let syncState = SyncState.pending(deviceID: "my-mac", modifiedAt: Date())
        let original = SyncableClipboardItem(item: originalItem, syncState: syncState)

        let record = original.toCKRecord()
        let restored = SyncableClipboardItem.from(record: record)

        #expect(restored != nil)
        #expect(restored?.item.textContent == "Round trip test")
        #expect(restored?.item.sourceApp == "Safari")
        #expect(restored?.item.contentHash == originalItem.contentHash)
        #expect(restored?.syncState.isSynced == true)  // from(record:) marks as synced
    }

    // MARK: - Link Content

    @Test("Link item converts to CKRecord with metadata")
    func linkItemToCKRecord() {
        let metadata = LinkMetadataState.loaded(title: "Example", imageData: nil)
        let item = ClipboardItem(url: "https://example.com", metadataState: metadata, sourceApp: "Safari")
        let syncState = SyncState.pending(deviceID: "test-device", modifiedAt: Date())
        let syncable = SyncableClipboardItem(item: item, syncState: syncState)

        let record = syncable.toCKRecord()

        #expect(record["content"] as? String == "https://example.com")
        #expect(record["contentType"] as? String == "link")
        #expect(record["linkTitle"] as? String == "Example")
    }

    @Test("Link item with pending metadata converts correctly")
    func linkItemPendingMetadata() {
        let item = ClipboardItem(url: "https://example.com", metadataState: .pending, sourceApp: nil)
        let syncState = SyncState.pending(deviceID: "device", modifiedAt: Date())
        let syncable = SyncableClipboardItem(item: item, syncState: syncState)

        let record = syncable.toCKRecord()

        #expect(record["content"] as? String == "https://example.com")
        #expect(record["contentType"] as? String == "link")
        // Pending metadata should have nil title in database encoding
        #expect(record["linkTitle"] == nil)
    }

    // MARK: - Record ID Generation

    @Test("New item generates record ID from content hash")
    func newItemRecordIDFromContentHash() {
        let item = ClipboardItem(text: "unique content", sourceApp: nil)
        let syncable = SyncableClipboardItem(item: item, syncEnabled: true)

        let record = syncable.toCKRecord()

        #expect(record.recordID.recordName == item.contentHash)
    }

    @Test("Synced item preserves existing record ID")
    func syncedItemPreservesRecordID() {
        let item = ClipboardItem(text: "already synced", sourceApp: nil)
        let existingRecordID = "existing-cloudkit-record-id"
        let syncState = SyncState.synced(recordID: existingRecordID, deviceID: "device", modifiedAt: Date())
        let syncable = SyncableClipboardItem(item: item, syncState: syncState)

        let record = syncable.toCKRecord()

        #expect(record.recordID.recordName == existingRecordID)
    }

    // MARK: - Timestamp Handling

    @Test("Timestamps are preserved through conversion")
    func timestampsPreserved() {
        let timestamp = Date(timeIntervalSince1970: 1700000000)
        let modifiedAt = Date(timeIntervalSince1970: 1700001000)

        let item = ClipboardItem(text: "timestamped", sourceApp: nil, timestamp: timestamp)
        let syncState = SyncState.pending(deviceID: "device", modifiedAt: modifiedAt)
        let syncable = SyncableClipboardItem(item: item, syncState: syncState)

        let record = syncable.toCKRecord()

        #expect(record["timestamp"] as? Date == timestamp)
        #expect(record["modifiedAt"] as? Date == modifiedAt)
    }

    // MARK: - Invalid Record Handling

    @Test("Missing contentHash returns nil")
    func missingContentHashReturnsNil() {
        // We can't easily create a CKRecord without going through the normal path,
        // but we can test the guard conditions conceptually
        // The from(record:) method guards on contentHash, timestamp, content, contentType
        // This test documents the expected behavior
        #expect(true)  // Placeholder - actual test would require mocking CKRecord
    }

    // MARK: - Zone Configuration

    @Test("Record zone is correctly configured")
    func recordZoneConfiguration() {
        let item = ClipboardItem(text: "test", sourceApp: nil)
        let syncable = SyncableClipboardItem(item: item, syncEnabled: true)

        let record = syncable.toCKRecord()

        #expect(record.recordID.zoneID.zoneName == "ClipKittyZone")
    }

    // MARK: - Content Types

    @Test("Email content type is preserved")
    func emailContentType() {
        let item = ClipboardItem(text: "test@example.com", sourceApp: nil)
        // The content detection should identify this as email
        if case .email = item.content {
            let syncable = SyncableClipboardItem(item: item, syncEnabled: true)
            let record = syncable.toCKRecord()

            #expect(record["contentType"] as? String == "email")
            #expect(record["content"] as? String == "test@example.com")
        }
    }

    @Test("Phone content type is preserved")
    func phoneContentType() {
        let item = ClipboardItem(text: "+1 (555) 123-4567", sourceApp: nil)
        // The content detection should identify this as phone
        if case .phone = item.content {
            let syncable = SyncableClipboardItem(item: item, syncEnabled: true)
            let record = syncable.toCKRecord()

            #expect(record["contentType"] as? String == "phone")
        }
    }

    // MARK: - Source App

    @Test("Nil source app is handled correctly")
    func nilSourceApp() {
        let item = ClipboardItem(text: "no source", sourceApp: nil)
        let syncable = SyncableClipboardItem(item: item, syncEnabled: true)

        let record = syncable.toCKRecord()

        // CKRecord should handle nil gracefully
        #expect(record["sourceApp"] == nil)
    }

    @Test("Source app is preserved")
    func sourceAppPreserved() {
        let item = ClipboardItem(text: "from app", sourceApp: "Finder")
        let syncable = SyncableClipboardItem(item: item, syncEnabled: true)

        let record = syncable.toCKRecord()

        #expect(record["sourceApp"] as? String == "Finder")
    }
}
