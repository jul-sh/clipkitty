import Testing
import Foundation
@testable import ClipKittyCore

/// Tests for SyncableClipboardItem construction and state management
@Suite("SyncableClipboardItem")
struct SyncableClipboardItemTests {

    // MARK: - Construction

    @Test("Item created with sync disabled has local state")
    func itemWithSyncDisabledIsLocal() {
        let item = ClipboardItem(text: "hello", sourceApp: "TestApp")
        let syncable = SyncableClipboardItem(item: item, syncEnabled: false)

        #expect(syncable.syncState == .local)
        #expect(syncable.syncStatus == .local)
        #expect(syncable.syncRecordID == nil)
    }

    @Test("Item created with sync enabled has pending state")
    func itemWithSyncEnabledIsPending() {
        let item = ClipboardItem(text: "hello", sourceApp: "TestApp")
        let syncable = SyncableClipboardItem(item: item, syncEnabled: true)

        #expect(syncable.syncState.isPending)
        #expect(syncable.syncStatus == .pending)
        #expect(syncable.syncRecordID == nil)
        #expect(syncable.deviceID != nil)
    }

    @Test("Item with explicit synced state has all metadata")
    func itemWithSyncedState() {
        let item = ClipboardItem(text: "synced content", sourceApp: "Safari")
        let recordID = "cloudkit-record-123"
        let deviceID = "macbook-pro"
        let modifiedAt = Date()

        let syncState = SyncState.synced(recordID: recordID, deviceID: deviceID, modifiedAt: modifiedAt)
        let syncable = SyncableClipboardItem(item: item, syncState: syncState)

        #expect(syncable.syncState.isSynced)
        #expect(syncable.syncRecordID == recordID)
        #expect(syncable.deviceID == deviceID)
        #expect(syncable.modifiedAt == modifiedAt)
    }

    // MARK: - Legacy Compatibility

    @Test("Legacy initializer creates correct state for synced")
    func legacyInitializerSynced() {
        let item = ClipboardItem(text: "legacy", sourceApp: nil)
        let recordID = "legacy-record"
        let modifiedAt = Date()
        let deviceID = "legacy-device"

        let syncable = SyncableClipboardItem(
            item: item,
            syncRecordID: recordID,
            syncStatus: .synced,
            modifiedAt: modifiedAt,
            deviceID: deviceID
        )

        #expect(syncable.syncState.isSynced)
        #expect(syncable.syncRecordID == recordID)
        #expect(syncable.deviceID == deviceID)
    }

    @Test("Legacy initializer creates correct state for pending")
    func legacyInitializerPending() {
        let item = ClipboardItem(text: "pending item", sourceApp: nil)
        let modifiedAt = Date()
        let deviceID = "my-device"

        let syncable = SyncableClipboardItem(
            item: item,
            syncRecordID: nil,
            syncStatus: .pending,
            modifiedAt: modifiedAt,
            deviceID: deviceID
        )

        #expect(syncable.syncState.isPending)
        #expect(syncable.syncRecordID == nil)
        #expect(syncable.deviceID == deviceID)
    }

    @Test("Legacy initializer creates correct state for local")
    func legacyInitializerLocal() {
        let item = ClipboardItem(text: "local only", sourceApp: nil)

        let syncable = SyncableClipboardItem(
            item: item,
            syncRecordID: nil,
            syncStatus: .local,
            modifiedAt: Date(),
            deviceID: nil
        )

        #expect(syncable.syncState == .local)
        #expect(syncable.syncRecordID == nil)
    }

    // MARK: - ID and Identity

    @Test("Syncable item ID matches underlying item ID")
    func syncableItemIDMatchesItemID() {
        var item = ClipboardItem(text: "test", sourceApp: nil)
        item.id = 42

        let syncable = SyncableClipboardItem(item: item, syncEnabled: false)

        #expect(syncable.id == 42)
    }

    @Test("Syncable item with no ID returns nil")
    func syncableItemWithNoIDReturnsNil() {
        let item = ClipboardItem(text: "no id", sourceApp: nil)
        let syncable = SyncableClipboardItem(item: item, syncEnabled: false)

        #expect(syncable.id == nil)
    }

    // MARK: - Content Types

    @Test("Text item syncs correctly")
    func textItemSyncs() {
        let item = ClipboardItem(text: "Plain text content", sourceApp: "Notes")
        let syncable = SyncableClipboardItem(item: item, syncEnabled: true)

        #expect(syncable.item.textContent == "Plain text content")
        #expect(syncable.syncState.isPending)
    }

    @Test("Image item syncs correctly")
    func imageItemSyncs() {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0])  // JPEG magic bytes
        let item = ClipboardItem(imageData: imageData, sourceApp: "Preview")
        let syncable = SyncableClipboardItem(item: item, syncEnabled: true)

        if case .image(let data, _) = syncable.item.content {
            #expect(data == imageData)
        } else {
            Issue.record("Expected image content")
        }
    }

    @Test("Link item with metadata syncs correctly")
    func linkItemSyncs() {
        let metadata = LinkMetadataState.loaded(title: "Example Site", imageData: nil)
        let item = ClipboardItem(url: "https://example.com", metadataState: metadata, sourceApp: "Safari")
        let syncable = SyncableClipboardItem(item: item, syncEnabled: true)

        if case .link(let url, let state) = syncable.item.content {
            #expect(url == "https://example.com")
            #expect(state.title == "Example Site")
        } else {
            Issue.record("Expected link content")
        }
    }

    // MARK: - Equatable

    @Test("Same syncable items are equal")
    func syncableItemsEquality() {
        let item = ClipboardItem(text: "same", sourceApp: nil)
        let state = SyncState.local

        let a = SyncableClipboardItem(item: item, syncState: state)
        let b = SyncableClipboardItem(item: item, syncState: state)

        #expect(a == b)
    }

    @Test("Different sync states make items unequal")
    func differentSyncStatesMakeUnequal() {
        let item = ClipboardItem(text: "same text", sourceApp: nil)

        let a = SyncableClipboardItem(item: item, syncState: .local)
        let b = SyncableClipboardItem(item: item, syncEnabled: true)  // pending

        #expect(a != b)
    }
}
