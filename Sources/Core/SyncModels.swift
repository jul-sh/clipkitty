import Foundation
import CloudKit
import GRDB

// MARK: - Sync State (Enum-Driven)

/// Represents the synchronization state of a clipboard item.
/// Uses sum types to make invalid states unrepresentable:
/// - Local items have no sync metadata
/// - Pending items have deviceID but no recordID yet
/// - Synced items have all metadata
public enum SyncState: Sendable, Equatable {
    /// Never synced - item is local only (sync was disabled when created)
    case local

    /// Queued for upload - has device info but no cloud record yet
    case pending(deviceID: String, modifiedAt: Date)

    /// Successfully synced with CloudKit
    case synced(recordID: String, deviceID: String, modifiedAt: Date)

    // MARK: - Database Serialization

    /// Database status string
    public var databaseStatus: String {
        switch self {
        case .local: return "local"
        case .pending: return "pending"
        case .synced: return "synced"
        }
    }

    /// Extract fields for database storage
    public var databaseFields: (status: String, recordID: String?, deviceID: String?, modifiedAt: Date?) {
        switch self {
        case .local:
            return ("local", nil, nil, nil)
        case .pending(let deviceID, let modifiedAt):
            return ("pending", nil, deviceID, modifiedAt)
        case .synced(let recordID, let deviceID, let modifiedAt):
            return ("synced", recordID, deviceID, modifiedAt)
        }
    }

    /// Reconstruct from database row values
    public static func from(
        status: String?,
        recordID: String?,
        deviceID: String?,
        modifiedAt: Date?
    ) -> SyncState {
        switch status {
        case "synced":
            guard let recordID = recordID, let deviceID = deviceID, let modifiedAt = modifiedAt else {
                // Corrupted synced state - demote to local
                return .local
            }
            return .synced(recordID: recordID, deviceID: deviceID, modifiedAt: modifiedAt)
        case "pending":
            let device = deviceID ?? currentDeviceID
            let modified = modifiedAt ?? Date()
            return .pending(deviceID: device, modifiedAt: modified)
        default:
            return .local
        }
    }

    /// Current device's unique identifier
    public static var currentDeviceID: String {
        if let uuid = getHardwareUUID() {
            return uuid
        }
        let key = "ClipKittyDeviceID"
        if let stored = UserDefaults.standard.string(forKey: key) {
            return stored
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    private static func getHardwareUUID() -> String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }

        guard platformExpert != 0,
              let uuidData = IORegistryEntryCreateCFProperty(
                  platformExpert,
                  "IOPlatformUUID" as CFString,
                  kCFAllocatorDefault,
                  0
              )?.takeRetainedValue() as? String else {
            return nil
        }
        return uuidData
    }

    // MARK: - Convenience Accessors

    public var isSynced: Bool {
        if case .synced = self { return true }
        return false
    }

    public var isPending: Bool {
        if case .pending = self { return true }
        return false
    }

    public var recordID: String? {
        if case .synced(let recordID, _, _) = self { return recordID }
        return nil
    }

    public var modifiedAt: Date? {
        switch self {
        case .local: return nil
        case .pending(_, let date): return date
        case .synced(_, _, let date): return date
        }
    }

    public var deviceID: String? {
        switch self {
        case .local: return nil
        case .pending(let deviceID, _): return deviceID
        case .synced(_, let deviceID, _): return deviceID
        }
    }
}

// MARK: - Legacy SyncStatus (for migration compatibility)

/// Legacy status enum - prefer SyncState for new code
public enum SyncStatus: String, Sendable, Codable {
    case local = "local"
    case pending = "pending"
    case synced = "synced"

    public static func from(databaseValue: String?) -> SyncStatus {
        guard let value = databaseValue else { return .local }
        return SyncStatus(rawValue: value) ?? .local
    }
}

// MARK: - Syncable Item

/// Extended clipboard item with sync metadata using enum-driven state
public struct SyncableClipboardItem: Identifiable, Sendable, Equatable {
    public let item: ClipboardItem
    public let syncState: SyncState

    public var id: Int64? { item.id }

    /// Create from a ClipboardItem with default sync values
    public init(item: ClipboardItem, syncEnabled: Bool = false) {
        self.item = item
        if syncEnabled {
            self.syncState = .pending(deviceID: SyncState.currentDeviceID, modifiedAt: item.timestamp)
        } else {
            self.syncState = .local
        }
    }

    /// Create with explicit sync state
    public init(item: ClipboardItem, syncState: SyncState) {
        self.item = item
        self.syncState = syncState
    }

    /// Create from database row (legacy compatibility)
    public init(
        item: ClipboardItem,
        syncRecordID: String?,
        syncStatus: SyncStatus,
        modifiedAt: Date,
        deviceID: String?
    ) {
        self.item = item
        self.syncState = SyncState.from(
            status: syncStatus.rawValue,
            recordID: syncRecordID,
            deviceID: deviceID,
            modifiedAt: modifiedAt
        )
    }

    // MARK: - Legacy Accessors (for compatibility during migration)

    public var syncRecordID: String? { syncState.recordID }
    public var modifiedAt: Date { syncState.modifiedAt ?? item.timestamp }
    public var deviceID: String? { syncState.deviceID }

    public var syncStatus: SyncStatus {
        switch syncState {
        case .local: return .local
        case .pending: return .pending
        case .synced: return .synced
        }
    }

    /// Delegate to SyncState for device ID
    public static var currentDeviceID: String { SyncState.currentDeviceID }
}

// MARK: - CloudKit Record Conversion

public extension SyncableClipboardItem {
    /// CloudKit record type name
    static let recordType = "ClipboardItem"
    
    /// CloudKit zone ID for clipboard items
    static let zoneID = CKRecordZone.ID(zoneName: "ClipKittyZone", ownerName: CKCurrentUserDefaultName)
    
    /// Convert to a CloudKit record
    func toCKRecord() -> CKRecord {
        let recordID: CKRecord.ID
        if let existingID = syncRecordID {
            recordID = CKRecord.ID(recordName: existingID, zoneID: Self.zoneID)
        } else {
            // Generate a new record ID based on content hash for deduplication
            recordID = CKRecord.ID(recordName: item.contentHash, zoneID: Self.zoneID)
        }
        
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        
        // Core fields
        record["contentHash"] = item.contentHash as CKRecordValue
        record["timestamp"] = item.timestamp as CKRecordValue
        record["modifiedAt"] = modifiedAt as CKRecordValue
        record["sourceApp"] = item.sourceApp as CKRecordValue?
        record["deviceID"] = deviceID as CKRecordValue?
        record["contentType"] = item.content.databaseType as CKRecordValue
        
        // Content fields
        let (text, imageData, linkTitle, linkImageData) = item.content.databaseFields
        record["content"] = text as CKRecordValue
        record["linkTitle"] = linkTitle as CKRecordValue?
        
        // Store binary data as CKAsset for large content
        if let imageData = imageData {
            record["imageData"] = saveAsAsset(data: imageData) as CKRecordValue?
        }
        if let linkImageData = linkImageData {
            record["linkImageData"] = saveAsAsset(data: linkImageData) as CKRecordValue?
        }
        
        return record
    }
    
    /// Create from a CloudKit record
    static func from(record: CKRecord) -> SyncableClipboardItem? {
        guard let contentHash = record["contentHash"] as? String,
              let timestamp = record["timestamp"] as? Date,
              let content = record["content"] as? String,
              let contentType = record["contentType"] as? String else {
            return nil
        }
        
        let sourceApp = record["sourceApp"] as? String
        let modifiedAt = record["modifiedAt"] as? Date ?? timestamp
        let deviceID = record["deviceID"] as? String
        let linkTitle = record["linkTitle"] as? String
        
        // Load binary data from assets
        let imageData = loadFromAsset(record["imageData"] as? CKAsset)
        let linkImageData = loadFromAsset(record["linkImageData"] as? CKAsset)
        
        let clipboardContent = ClipboardContent.from(
            databaseType: contentType,
            content: content,
            imageData: imageData,
            linkTitle: linkTitle,
            linkImageData: linkImageData
        )
        
        let item = ClipboardItem(
            id: nil,  // Will be assigned by local database
            content: clipboardContent,
            contentHash: contentHash,
            timestamp: timestamp,
            sourceApp: sourceApp
        )
        
        return SyncableClipboardItem(
            item: item,
            syncRecordID: record.recordID.recordName,
            syncStatus: .synced,
            modifiedAt: modifiedAt,
            deviceID: deviceID
        )
    }
    
    /// Save data as a temporary file for CKAsset
    private func saveAsAsset(data: Data) -> CKAsset? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try data.write(to: tempURL)
            return CKAsset(fileURL: tempURL)
        } catch {
            return nil
        }
    }
    
    /// Load data from a CKAsset
    private static func loadFromAsset(_ asset: CKAsset?) -> Data? {
        guard let asset = asset, let url = asset.fileURL else { return nil }
        return try? Data(contentsOf: url)
    }
}

// MARK: - GRDB Extensions for Sync Fields

public extension SyncableClipboardItem {
    /// Column names for sync fields
    enum SyncColumns {
        static let syncRecordID = "syncRecordID"
        static let syncStatus = "syncStatus"
        static let modifiedAt = "modifiedAt"
        static let deviceID = "deviceID"
    }
}
