#if ENABLE_SYNC

    import CloudKit
    import Foundation

    // MARK: - CloudKit Transport Protocol

    protocol SyncCloudTransport {
        func accountStatus() async throws -> CKAccountStatus
        func ensureZoneExists(_ zone: CKRecordZone) async throws
        func saveSubscription(_ subscription: CKDatabaseSubscription) async throws
        func fetchZoneChanges(
            in zoneID: CKRecordZone.ID,
            since changeToken: CKServerChangeToken?
        ) async -> SyncZoneChangeResult
        func saveRecords(
            _ records: [CKRecord],
            savePolicy: CKModifyRecordsOperation.RecordSavePolicy
        ) async -> SyncRecordSaveResult
        func deleteRecords(_ recordIDs: [CKRecord.ID]) async -> SyncRecordDeleteResult
        func fetchAllRecords(
            ofType recordType: String,
            in zoneID: CKRecordZone.ID
        ) async throws -> [CKRecord]
    }

    // MARK: - Transport Result Types

    struct SyncZoneChangeResult {
        var events: [CKRecord] = []
        var snapshots: [CKRecord] = []
        var newToken: CKServerChangeToken?
        var tokenExpired = false
        var fetchError: Error?
    }

    struct SyncRecordSaveResult {
        var savedRecordIDs: [CKRecord.ID] = []
        var perRecordErrors: [CKRecord.ID: Error] = [:]
        var operationError: Error?
    }

    struct SyncRecordDeleteResult {
        var deletedRecordIDs: [CKRecord.ID] = []
        var perRecordErrors: [CKRecord.ID: Error] = [:]
        var operationError: Error?
    }

    // MARK: - CloudKit Record Field Names

    enum CloudRecordJSONField {
        case payloadData
        case aggregateData

        var recordFieldName: String {
            switch self {
            case .payloadData: return "payloadData"
            case .aggregateData: return "aggregateData"
            }
        }
    }

    // MARK: - Blob Bundle Types

    enum BlobPathComponent: Codable, Equatable {
        case key(String)
        case index(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let key = try? container.decode(String.self) {
                self = .key(key)
            } else {
                self = try .index(container.decode(Int.self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .key(key):
                try container.encode(key)
            case let .index(index):
                try container.encode(index)
            }
        }
    }

    struct BlobBundleEntry: Codable, Equatable {
        let path: [BlobPathComponent]
        let base64Value: String
    }

    struct BlobBundle: Codable, Equatable {
        let entries: [BlobBundleEntry]
    }

    // MARK: - Array Chunking

    extension Array {
        func chunked(into size: Int) -> [[Element]] {
            stride(from: 0, to: count, by: size).map {
                Array(self[$0 ..< Swift.min($0 + size, count)])
            }
        }
    }

#endif
