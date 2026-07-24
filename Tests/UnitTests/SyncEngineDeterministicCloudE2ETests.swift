@testable import ClipKitty
@testable import ClipKittyCloudSync
import ClipKittyRust
import CloudKit
import XCTest

@MainActor
final class SyncEngineDeterministicCloudE2ETests: XCTestCase {
    private final class DeterministicCloud {
        private struct StoredRecord {
            let recordType: String
            var record: CKRecord
        }

        private struct Change {
            let sequence: Int64
            let recordID: CKRecord.ID
            let recordType: String
        }

        private let zoneID = CKRecordZone(zoneName: "ClipKittySync").zoneID
        private let assetDirectory: URL
        private var nextSequence: Int64 = 0
        private var storedRecords: [CKRecord.ID: StoredRecord] = [:]
        private var changes: [Change] = []

        var accountStatusResult: Result<CKAccountStatus, Error> = .success(.available)
        var nextSaveOperationError: Error?
        var nextFetchError: Error?

        init() throws {
            assetDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("clipkitty-deterministic-cloud-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        }

        func makeTransport() -> DeterministicCloudTransport {
            DeterministicCloudTransport(cloud: self)
        }

        func accountStatus() throws -> CKAccountStatus {
            try accountStatusResult.get()
        }

        func ensureZoneExists(_ zone: CKRecordZone) throws {
            guard zone.zoneID.zoneName == zoneID.zoneName else {
                throw NSError(
                    domain: "DeterministicCloud",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected zone \(zone.zoneID.zoneName)"]
                )
            }
        }

        func saveSubscription(_: CKDatabaseSubscription) {}

        func fetchChanges(
            after cursor: Int64
        ) -> (result: SyncZoneChangeResult, newestSequence: Int64) {
            if let fetchError = nextFetchError {
                nextFetchError = nil
                return (SyncZoneChangeResult(fetchError: fetchError), cursor)
            }

            let visibleChanges = changes
                .filter { $0.sequence > cursor }
                .sorted { $0.sequence < $1.sequence }
            let newestSequence = visibleChanges.last?.sequence ?? cursor
            let records = visibleChanges.compactMap { change in
                storedRecords[change.recordID].map { (change.recordType, cloneRecord($0.record)) }
            }

            return (
                SyncZoneChangeResult(
                    events: records
                        .filter { $0.0 == "ItemEvent" }
                        .map(\.1),
                    snapshots: records
                        .filter { $0.0 == "ItemSnapshot" }
                        .map(\.1)
                ),
                newestSequence
            )
        }

        func saveRecords(
            _ records: [CKRecord],
            savePolicy: CKModifyRecordsOperation.RecordSavePolicy
        ) -> SyncRecordSaveResult {
            if let nextSaveOperationError {
                self.nextSaveOperationError = nil
                return SyncRecordSaveResult(operationError: nextSaveOperationError)
            }

            var savedRecordIDs: [CKRecord.ID] = []
            var perRecordErrors: [CKRecord.ID: Error] = [:]

            for record in records {
                do {
                    switch savePolicy {
                    case .ifServerRecordUnchanged:
                        if storedRecords[record.recordID] != nil {
                            perRecordErrors[record.recordID] = CKError(.serverRecordChanged)
                            continue
                        }
                        try storeNewRecord(record)

                    case .changedKeys:
                        try mergeChangedKeys(from: record)

                    case .allKeys:
                        try replaceRecord(record)

                    @unknown default:
                        throw NSError(
                            domain: "DeterministicCloud",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Unsupported save policy \(savePolicy)"]
                        )
                    }

                    savedRecordIDs.append(record.recordID)
                } catch {
                    perRecordErrors[record.recordID] = error
                }
            }

            return SyncRecordSaveResult(
                savedRecordIDs: savedRecordIDs,
                perRecordErrors: perRecordErrors
            )
        }

        func deleteRecords(_ recordIDs: [CKRecord.ID]) -> SyncRecordDeleteResult {
            var deletedRecordIDs: [CKRecord.ID] = []
            var perRecordErrors: [CKRecord.ID: Error] = [:]

            for recordID in recordIDs {
                if storedRecords.removeValue(forKey: recordID) != nil {
                    deletedRecordIDs.append(recordID)
                } else {
                    perRecordErrors[recordID] = CKError(.unknownItem)
                }
            }

            return SyncRecordDeleteResult(
                deletedRecordIDs: deletedRecordIDs,
                perRecordErrors: perRecordErrors
            )
        }

        func recordCount(recordType: String? = nil) -> Int {
            storedRecords.values.filter { stored in
                recordType.map { stored.recordType == $0 } ?? true
            }.count
        }

        private func storeNewRecord(_ record: CKRecord) throws {
            try replaceRecord(record)
        }

        private func replaceRecord(_ record: CKRecord) throws {
            let copied = try cloneRecordCopyingAssets(record)
            storedRecords[record.recordID] = StoredRecord(
                recordType: record.recordType,
                record: copied
            )
            appendChange(recordID: record.recordID, recordType: record.recordType)
        }

        private func mergeChangedKeys(from record: CKRecord) throws {
            let merged: CKRecord
            if let existing = storedRecords[record.recordID]?.record {
                merged = cloneRecord(existing)
            } else {
                merged = CKRecord(recordType: record.recordType, recordID: record.recordID)
            }

            let changedKeys = record.changedKeys()
            let keysToApply = changedKeys.isEmpty ? record.allKeys() : changedKeys

            for key in keysToApply {
                if let asset = record[key] as? CKAsset {
                    merged[key] = try copyAsset(asset, recordID: record.recordID, key: key)
                } else if let value = record[key] as? CKRecordValue {
                    merged[key] = value
                } else {
                    merged[key] = nil
                }
            }

            storedRecords[record.recordID] = StoredRecord(
                recordType: record.recordType,
                record: merged
            )
            appendChange(recordID: record.recordID, recordType: record.recordType)
        }

        private func appendChange(recordID: CKRecord.ID, recordType: String) {
            nextSequence += 1
            changes.append(
                Change(
                    sequence: nextSequence,
                    recordID: recordID,
                    recordType: recordType
                )
            )
        }

        private func cloneRecordCopyingAssets(_ record: CKRecord) throws -> CKRecord {
            let clone = CKRecord(recordType: record.recordType, recordID: record.recordID)
            for key in record.allKeys() {
                if let asset = record[key] as? CKAsset {
                    clone[key] = try copyAsset(asset, recordID: record.recordID, key: key)
                } else if let value = record[key] as? CKRecordValue {
                    clone[key] = value
                }
            }
            return clone
        }

        private func cloneRecord(_ record: CKRecord) -> CKRecord {
            let clone = CKRecord(recordType: record.recordType, recordID: record.recordID)
            for key in record.allKeys() {
                if let asset = record[key] as? CKAsset {
                    clone[key] = asset
                } else {
                    clone[key] = record[key] as? CKRecordValue
                }
            }
            return clone
        }

        private func copyAsset(
            _ asset: CKAsset,
            recordID: CKRecord.ID,
            key: String
        ) throws -> CKAsset {
            guard let sourceURL = asset.fileURL else {
                throw NSError(
                    domain: "DeterministicCloud",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Asset \(key) for \(recordID.recordName) has no file URL"]
                )
            }

            let destination = assetDirectory
                .appendingPathComponent("\(nextSequence)-\(UUID().uuidString)-\(key).asset")
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return CKAsset(fileURL: destination)
        }
    }

    private final class DeterministicCloudTransport: SyncCloudTransport {
        private let cloud: DeterministicCloud
        private var cursor: Int64 = 0
        private var shouldExpireNextToken = false

        init(cloud: DeterministicCloud) {
            self.cloud = cloud
        }

        func expireTokenOnNextFetch() {
            shouldExpireNextToken = true
        }

        func accountStatus() async throws -> CKAccountStatus {
            try cloud.accountStatus()
        }

        func ensureZoneExists(_ zone: CKRecordZone) async throws {
            try cloud.ensureZoneExists(zone)
        }

        func saveSubscription(_ subscription: CKDatabaseSubscription) async throws {
            cloud.saveSubscription(subscription)
        }

        func fetchZoneChanges(
            in _: CKRecordZone.ID,
            since _: CKServerChangeToken?
        ) async -> SyncZoneChangeResult {
            if shouldExpireNextToken {
                shouldExpireNextToken = false
                return SyncZoneChangeResult(tokenExpired: true)
            }

            // CKServerChangeToken is opaque and not constructible in tests, so
            // the deterministic transport owns the equivalent per-device cursor.
            let response = cloud.fetchChanges(after: cursor)
            cursor = response.newestSequence
            return response.result
        }

        func saveRecords(
            _ records: [CKRecord],
            savePolicy: CKModifyRecordsOperation.RecordSavePolicy
        ) async -> SyncRecordSaveResult {
            cloud.saveRecords(records, savePolicy: savePolicy)
        }

        func deleteRecords(_ recordIDs: [CKRecord.ID]) async -> SyncRecordDeleteResult {
            cloud.deleteRecords(recordIDs)
        }
    }

    private func makeStore() throws -> ClipKittyRust.ClipboardStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-sync-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return try ClipKittyRust.ClipboardStore(dbPath: tmp.appendingPathComponent("test.sqlite").path)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "SyncEngineDeterministicCloudE2ETests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeEngine(
        store: ClipKittyRust.ClipboardStore,
        transport: any SyncCloudTransport,
        deviceId: String
    ) -> SyncEngine {
        SyncEngine(
            store: store,
            cloud: transport,
            userDefaults: makeDefaults(),
            deviceId: deviceId,
            notificationCenter: NotificationCenter(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func assertSynced(
        _ engine: SyncEngine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .synced = engine.status else {
            return XCTFail("Expected synced status, got \(engine.status)", file: file, line: line)
        }
    }

    private func assertText(
        _ expectedText: String,
        itemId: String,
        in store: ClipKittyRust.ClipboardStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let items = try store.fetchByIds(itemIds: [itemId])
        XCTAssertEqual(items.count, 1, file: file, line: line)
        guard let item = items.first else { return }
        guard case let .text(value) = item.content else {
            return XCTFail("Expected text item, got \(item.content)", file: file, line: line)
        }
        XCTAssertEqual(value, expectedText, file: file, line: line)
    }

    private func assertMissing(
        itemId: String,
        in store: ClipKittyRust.ClipboardStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(
            try store.fetchByIds(itemIds: [itemId]).isEmpty,
            "Expected item \(itemId) to be absent",
            file: file,
            line: line
        )
    }

    private func assertSearchFinds(
        _ itemId: String,
        query: String,
        in store: ClipKittyRust.ClipboardStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let result = try await store.search(query: query, presentation: .compactRow)
        XCTAssertTrue(
            result.matches.contains { $0.itemMetadata.itemId == itemId },
            "Expected search for `\(query)` to find \(itemId), got \(result.matches.map(\.itemMetadata.itemId))",
            file: file,
            line: line
        )
    }

    func testTwoDevicesConvergeThroughDeterministicCloud() async throws {
        let cloud = try DeterministicCloud()
        let firstStore = try makeStore()
        let secondStore = try makeStore()
        let firstEngine = makeEngine(
            store: firstStore,
            transport: cloud.makeTransport(),
            deviceId: "device-a"
        )
        let secondEngine = makeEngine(
            store: secondStore,
            transport: cloud.makeTransport(),
            deviceId: "device-b"
        )

        firstStore.setSyncDeviceId(deviceId: "device-a")
        let itemId = try firstStore.saveText(
            text: "alpha from device a",
            sourceApp: nil,
            sourceAppBundleId: nil
        )

        await firstEngine.runCoordinatorCycle()
        assertSynced(firstEngine)
        XCTAssertTrue(try firstStore.pendingLocalEvents().isEmpty)
        XCTAssertEqual(cloud.recordCount(recordType: "ItemEvent"), 1)

        await secondEngine.runCoordinatorCycle()
        assertSynced(secondEngine)
        try assertText("alpha from device a", itemId: itemId, in: secondStore)
        try await assertSearchFinds(itemId, query: "alpha", in: secondStore)

        secondStore.setSyncDeviceId(deviceId: "device-b")
        try secondStore.updateTextItem(itemId: itemId, text: "beta edited on device b")
        try secondStore.addTag(itemId: itemId, tag: .bookmark)

        await secondEngine.runCoordinatorCycle()
        assertSynced(secondEngine)
        XCTAssertTrue(try secondStore.pendingLocalEvents().isEmpty)

        await firstEngine.runCoordinatorCycle()
        assertSynced(firstEngine)
        try assertText("beta edited on device b", itemId: itemId, in: firstStore)
        let firstItem = try XCTUnwrap(firstStore.fetchByIds(itemIds: [itemId]).first)
        XCTAssertTrue(firstItem.itemMetadata.tags.contains(.bookmark))

        try firstStore.deleteItem(itemId: itemId)

        await firstEngine.runCoordinatorCycle()
        assertSynced(firstEngine)
        await secondEngine.runCoordinatorCycle()
        assertSynced(secondEngine)
        try assertMissing(itemId: itemId, in: firstStore)
        try assertMissing(itemId: itemId, in: secondStore)
    }

    func testFullResyncRehydratesSnapshotAssetsFromDeterministicCloud() async throws {
        let cloud = try DeterministicCloud()
        let sourceStore = try makeStore()
        let resyncStore = try makeStore()
        let sourceEngine = makeEngine(
            store: sourceStore,
            transport: cloud.makeTransport(),
            deviceId: "snapshot-source"
        )
        let resyncTransport = cloud.makeTransport()
        let resyncEngine = makeEngine(
            store: resyncStore,
            transport: resyncTransport,
            deviceId: "snapshot-target"
        )
        let bookmark = Data((0 ..< 255).map(UInt8.init))

        sourceStore.setSyncDeviceId(deviceId: "snapshot-source")
        let itemId = try sourceStore.saveFiles(
            files: [NewFileInput(
                path: "/tmp/resync-document.txt",
                filename: "resync-document.txt",
                fileSize: UInt64(bookmark.count),
                uti: "public.plain-text",
                bookmarkData: bookmark,
                preview: .unavailable(reason: .notCaptured)
            )],
            sourceApp: nil,
            sourceAppBundleId: nil
        )
        _ = try sourceStore.runCompaction()

        await sourceEngine.runCoordinatorCycle()
        assertSynced(sourceEngine)
        XCTAssertTrue(try sourceStore.pendingLocalEvents().isEmpty)
        XCTAssertTrue(try sourceStore.pendingSnapshotRecords().isEmpty)
        XCTAssertEqual(cloud.recordCount(recordType: "ItemSnapshot"), 1)

        resyncTransport.expireTokenOnNextFetch()
        await resyncEngine.runCoordinatorCycle()
        assertSynced(resyncEngine)

        let items = try resyncStore.fetchByIds(itemIds: [itemId])
        XCTAssertEqual(items.count, 1)
        guard case let .file(_, files) = try XCTUnwrap(items.first).content else {
            return XCTFail("Expected file item after full resync")
        }
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].filename, "resync-document.txt")
        XCTAssertEqual(files[0].bookmarkData, bookmark)
        try await assertSearchFinds(itemId, query: "resync", in: resyncStore)
    }

    func testRetryableUploadFailureKeepsLocalEventUntilCloudAcceptsIt() async throws {
        let cloud = try DeterministicCloud()
        let sourceStore = try makeStore()
        let targetStore = try makeStore()
        let sourceEngine = makeEngine(
            store: sourceStore,
            transport: cloud.makeTransport(),
            deviceId: "retry-source"
        )
        let targetEngine = makeEngine(
            store: targetStore,
            transport: cloud.makeTransport(),
            deviceId: "retry-target"
        )

        sourceStore.setSyncDeviceId(deviceId: "retry-source")
        let itemId = try sourceStore.saveText(
            text: "event survives retryable upload failure",
            sourceApp: nil,
            sourceAppBundleId: nil
        )
        cloud.nextSaveOperationError = CKError(.networkUnavailable)

        await sourceEngine.runCoordinatorCycle()
        guard case .error = sourceEngine.status else {
            return XCTFail("Expected retryable upload error, got \(sourceEngine.status)")
        }
        XCTAssertEqual(try sourceStore.pendingLocalEvents().map(\.itemId), [itemId])
        XCTAssertEqual(cloud.recordCount(recordType: "ItemEvent"), 0)

        await sourceEngine.runCoordinatorCycle()
        assertSynced(sourceEngine)
        XCTAssertTrue(try sourceStore.pendingLocalEvents().isEmpty)
        XCTAssertEqual(cloud.recordCount(recordType: "ItemEvent"), 1)

        await targetEngine.runCoordinatorCycle()
        assertSynced(targetEngine)
        try assertText("event survives retryable upload failure", itemId: itemId, in: targetStore)
    }
}
