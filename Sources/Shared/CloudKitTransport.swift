#if ENABLE_SYNC

    import CloudKit
    import Foundation
    import os

    /// Concrete CloudKit transport shared by macOS and iOS sync engines.
    final class CloudKitTransport: SyncCloudTransport {
        private let logger = Logger(subsystem: "com.clipkitty", category: "SyncEngine")
        private let container: CKContainer

        private var database: CKDatabase {
            container.privateCloudDatabase
        }

        init(containerIdentifier: String) {
            container = CKContainer(identifier: containerIdentifier)
        }

        func accountStatus() async throws -> CKAccountStatus {
            try await container.accountStatus()
        }

        func ensureZoneExists(_ zone: CKRecordZone) async throws {
            _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
        }

        func saveSubscription(_ subscription: CKDatabaseSubscription) async throws {
            _ = try await database.save(subscription)
        }

        func fetchZoneChanges(
            in zoneID: CKRecordZone.ID,
            since changeToken: CKServerChangeToken?
        ) async -> SyncZoneChangeResult {
            var result = SyncZoneChangeResult()

            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            config.previousServerChangeToken = changeToken

            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: config]
            )

            return await withCheckedContinuation { continuation in
                operation.recordWasChangedBlock = { _, fetchResult in
                    switch fetchResult {
                    case let .success(record):
                        if record.recordType == "ItemEvent" {
                            result.events.append(record)
                        } else if record.recordType == "ItemSnapshot" {
                            result.snapshots.append(record)
                        }
                    case let .failure(error):
                        if result.fetchError == nil {
                            result.fetchError = error
                        }
                        self.logger.warning("Record fetch error: \(error.localizedDescription)")
                    }
                }

                operation.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
                    result.newToken = token
                }

                operation.recordZoneFetchResultBlock = { _, fetchResult in
                    switch fetchResult {
                    case let .success((token, _, _)):
                        result.newToken = token
                    case let .failure(error):
                        let nsError = error as NSError
                        if nsError.code == CKError.changeTokenExpired.rawValue {
                            result.tokenExpired = true
                        } else if result.fetchError == nil {
                            result.fetchError = error
                        }
                        self.logger.warning("Zone fetch error: \(error.localizedDescription)")
                    }
                }

                operation.fetchRecordZoneChangesResultBlock = { fetchResult in
                    if case let .failure(error) = fetchResult {
                        let nsError = error as NSError
                        if nsError.code == CKError.changeTokenExpired.rawValue {
                            result.tokenExpired = true
                        } else if result.fetchError == nil {
                            result.fetchError = error
                        }
                    }
                    continuation.resume(returning: result)
                }

                database.add(operation)
            }
        }

        func saveRecords(
            _ records: [CKRecord],
            savePolicy: CKModifyRecordsOperation.RecordSavePolicy
        ) async -> SyncRecordSaveResult {
            guard !records.isEmpty else { return SyncRecordSaveResult() }

            let operation = CKModifyRecordsOperation(
                recordsToSave: records,
                recordIDsToDelete: nil
            )
            operation.savePolicy = savePolicy
            operation.isAtomic = false

            return await withCheckedContinuation { continuation in
                var result = SyncRecordSaveResult()

                operation.perRecordSaveBlock = { recordID, saveResult in
                    switch saveResult {
                    case .success:
                        result.savedRecordIDs.append(recordID)
                    case let .failure(error):
                        result.perRecordErrors[recordID] = error
                    }
                }

                operation.modifyRecordsResultBlock = { modifyResult in
                    if case let .failure(error) = modifyResult {
                        result.operationError = error
                    }
                    continuation.resume(returning: result)
                }

                self.database.add(operation)
            }
        }

        func deleteRecords(_ recordIDs: [CKRecord.ID]) async -> SyncRecordDeleteResult {
            guard !recordIDs.isEmpty else { return SyncRecordDeleteResult() }

            let operation = CKModifyRecordsOperation(
                recordsToSave: nil,
                recordIDsToDelete: recordIDs
            )
            operation.isAtomic = false

            return await withCheckedContinuation { continuation in
                var result = SyncRecordDeleteResult()

                operation.perRecordDeleteBlock = { recordID, deleteResult in
                    switch deleteResult {
                    case .success:
                        result.deletedRecordIDs.append(recordID)
                    case let .failure(error):
                        result.perRecordErrors[recordID] = error
                    }
                }

                operation.modifyRecordsResultBlock = { modifyResult in
                    if case let .failure(error) = modifyResult {
                        result.operationError = error
                    }
                    continuation.resume(returning: result)
                }

                self.database.add(operation)
            }
        }

        func fetchAllRecords(
            ofType recordType: String,
            in zoneID: CKRecordZone.ID
        ) async throws -> [CKRecord] {
            var records: [CKRecord] = []
            var cursor: CKQueryOperation.Cursor?

            let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
            let (results, queryCursor) = try await database.records(
                matching: query,
                inZoneWith: zoneID,
                resultsLimit: CKQueryOperation.maximumResults
            )
            try collectQueryResults(results, into: &records)
            cursor = queryCursor

            while let activeCursor = cursor {
                let (moreResults, nextCursor) = try await database.records(
                    continuingMatchFrom: activeCursor,
                    resultsLimit: CKQueryOperation.maximumResults
                )
                try collectQueryResults(moreResults, into: &records)
                cursor = nextCursor
            }

            return records
        }

        private func collectQueryResults(
            _ results: [(CKRecord.ID, Result<CKRecord, Error>)],
            into records: inout [CKRecord]
        ) throws {
            for (_, result) in results {
                switch result {
                case let .success(record):
                    records.append(record)
                case let .failure(error):
                    throw error
                }
            }
        }
    }

#endif
