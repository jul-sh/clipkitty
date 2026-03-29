import CloudKit
import ClipKittyRust
import Observation
import XCTest
@testable import ClipKitty

@MainActor
final class SyncEngineTests: XCTestCase {
    private final class FakeCloudTransport: SyncCloudTransport {
        var accountStatusResult: Result<CKAccountStatus, Error> = .success(.available)
        var zoneChangeResults: [SyncZoneChangeResult] = []
        var saveRecordsHandler: (([CKRecord], CKModifyRecordsOperation.RecordSavePolicy) -> SyncRecordSaveResult)?
        var deleteRecordsHandler: (([CKRecord.ID]) -> SyncRecordDeleteResult)?
        var fetchAllRecordsHandler: ((String, CKRecordZone.ID) throws -> [CKRecord])?
        var onSaveSubscription: (() -> Void)?

        private(set) var ensuredZones: [CKRecordZone.ID] = []
        private(set) var savedSubscriptionIDs: [String] = []
        private(set) var savePolicies: [CKModifyRecordsOperation.RecordSavePolicy] = []
        private(set) var queriedRecordTypes: [String] = []

        func accountStatus() async throws -> CKAccountStatus {
            try accountStatusResult.get()
        }

        func ensureZoneExists(_ zone: CKRecordZone) async throws {
            ensuredZones.append(zone.zoneID)
        }

        func saveSubscription(_ subscription: CKDatabaseSubscription) async throws {
            savedSubscriptionIDs.append(subscription.subscriptionID)
            onSaveSubscription?()
        }

        func fetchZoneChanges(
            in _: CKRecordZone.ID,
            since _: CKServerChangeToken?
        ) async -> SyncZoneChangeResult {
            if zoneChangeResults.isEmpty {
                return SyncZoneChangeResult()
            }
            return zoneChangeResults.removeFirst()
        }

        func saveRecords(
            _ records: [CKRecord],
            savePolicy: CKModifyRecordsOperation.RecordSavePolicy
        ) async -> SyncRecordSaveResult {
            savePolicies.append(savePolicy)
            return saveRecordsHandler?(records, savePolicy)
                ?? SyncRecordSaveResult(savedRecordIDs: records.map(\.recordID))
        }

        func deleteRecords(_ recordIDs: [CKRecord.ID]) async -> SyncRecordDeleteResult {
            deleteRecordsHandler?(recordIDs)
                ?? SyncRecordDeleteResult(deletedRecordIDs: recordIDs)
        }

        func fetchAllRecords(
            ofType recordType: String,
            in zoneID: CKRecordZone.ID
        ) async throws -> [CKRecord] {
            queriedRecordTypes.append(recordType)
            return try fetchAllRecordsHandler?(recordType, zoneID) ?? []
        }
    }

    private func makeStore() throws -> ClipKittyRust.ClipboardStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-sync-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dbPath = tmp.appendingPathComponent("test.sqlite").path
        return try ClipKittyRust.ClipboardStore(dbPath: dbPath)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "SyncEngineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeEngine(
        store: ClipKittyRust.ClipboardStore,
        transport: FakeCloudTransport,
        defaults: UserDefaults,
        deviceId: String = "sync-engine-test-device"
    ) -> SyncEngine {
        SyncEngine(
            store: store,
            cloud: transport,
            userDefaults: defaults,
            deviceId: deviceId,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func assertSynced(
        _ status: SyncEngine.SyncStatus,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .synced = status else {
            return XCTFail("Expected synced status, got \(status)", file: file, line: line)
        }
    }

    private func assertError(
        _ status: SyncEngine.SyncStatus,
        contains expectedSubstring: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .error(message) = status else {
            return XCTFail("Expected error status, got \(status)", file: file, line: line)
        }
        XCTAssertTrue(
            message.contains(expectedSubstring),
            "Expected error message to contain `\(expectedSubstring)`, got `\(message)`",
            file: file,
            line: line
        )
    }

    func testCoordinatorTreatsDuplicateEventUploadAsSuccessfulSync() async throws {
        let store = try makeStore()
        let defaults = makeDefaults()
        let transport = FakeCloudTransport()
        let deviceId = "duplicate-upload-device"

        store.setSyncDeviceId(deviceId: deviceId)
        _ = try store.saveText(text: "hello sync", sourceApp: nil, sourceAppBundleId: nil)

        transport.saveRecordsHandler = { records, savePolicy in
            switch savePolicy {
            case .ifServerRecordUnchanged:
                var result = SyncRecordSaveResult()
                for record in records {
                    result.perRecordErrors[record.recordID] = CKError(.serverRecordChanged)
                }
                return result
            case .changedKeys:
                return SyncRecordSaveResult(savedRecordIDs: records.map(\.recordID))
            case .allKeys:
                XCTFail("Unexpected save policy \(savePolicy)")
                return SyncRecordSaveResult(savedRecordIDs: records.map(\.recordID))
            @unknown default:
                XCTFail("Unexpected save policy \(savePolicy)")
                return SyncRecordSaveResult(savedRecordIDs: records.map(\.recordID))
            }
        }

        let engine = makeEngine(
            store: store,
            transport: transport,
            defaults: defaults,
            deviceId: deviceId
        )

        await engine.runCoordinatorCycle()

        assertSynced(engine.status)
        XCTAssertTrue(try store.pendingLocalEvents().isEmpty)
        XCTAssertTrue(try store.pendingSnapshotRecords().isEmpty)
        XCTAssertEqual(transport.savePolicies, [.ifServerRecordUnchanged, .changedKeys])
    }

    func testCoordinatorSurfacesOperationLevelUploadFailure() async throws {
        let store = try makeStore()
        let defaults = makeDefaults()
        let transport = FakeCloudTransport()
        let deviceId = "operation-error-device"

        store.setSyncDeviceId(deviceId: deviceId)
        _ = try store.saveText(text: "network failure", sourceApp: nil, sourceAppBundleId: nil)

        transport.saveRecordsHandler = { records, savePolicy in
            switch savePolicy {
            case .ifServerRecordUnchanged:
                return SyncRecordSaveResult(operationError: CKError(.networkUnavailable))
            case .changedKeys:
                return SyncRecordSaveResult(savedRecordIDs: records.map(\.recordID))
            case .allKeys:
                XCTFail("Unexpected save policy \(savePolicy)")
                return SyncRecordSaveResult(savedRecordIDs: records.map(\.recordID))
            @unknown default:
                XCTFail("Unexpected save policy \(savePolicy)")
                return SyncRecordSaveResult(savedRecordIDs: records.map(\.recordID))
            }
        }

        let engine = makeEngine(
            store: store,
            transport: transport,
            defaults: defaults,
            deviceId: deviceId
        )

        await engine.runCoordinatorCycle()

        assertError(engine.status, contains: "Upload failed")
        XCTAssertEqual(try store.pendingLocalEvents().count, 1)
    }

    func testCoordinatorPrefersFullResyncWhenTokenExpires() async throws {
        let store = try makeStore()
        let defaults = makeDefaults()
        let transport = FakeCloudTransport()
        let deviceId = "token-expired-device"

        var result = SyncZoneChangeResult()
        result.tokenExpired = true
        result.fetchError = CKError(.networkUnavailable)
        transport.zoneChangeResults = [result]

        let engine = makeEngine(
            store: store,
            transport: transport,
            defaults: defaults,
            deviceId: deviceId
        )

        await engine.runCoordinatorCycle()

        assertSynced(engine.status)
        XCTAssertEqual(transport.queriedRecordTypes, ["ItemSnapshot", "ItemEvent"])
    }

    func testCoordinatorFailsOnUnreadableCloudAsset() async throws {
        let store = try makeStore()
        let defaults = makeDefaults()
        let transport = FakeCloudTransport()
        let deviceId = "asset-failure-device"
        let zoneID = CKRecordZone(zoneName: "ClipKittySync").zoneID

        let recordID = CKRecord.ID(recordName: "event-1", zoneID: zoneID)
        let record = CKRecord(recordType: "ItemEvent", recordID: recordID)
        record["globalItemId"] = "global-1" as CKRecordValue
        record["originDeviceId"] = "remote-device" as CKRecordValue
        record["schemaVersion"] = Int64(1) as CKRecordValue
        record["recordedAt"] = Int64(1) as CKRecordValue
        record["payloadType"] = "item_created" as CKRecordValue
        record["payloadData"] = "{}" as CKRecordValue
        record["imageAsset"] = CKAsset(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-\(UUID().uuidString).bin")
        )

        var result = SyncZoneChangeResult()
        result.events = [record]
        transport.zoneChangeResults = [result]

        let engine = makeEngine(
            store: store,
            transport: transport,
            defaults: defaults,
            deviceId: deviceId
        )

        await engine.runCoordinatorCycle()

        assertError(engine.status, contains: "CloudKit asset")
    }

    func testStatusChangesInvalidateObservation() async throws {
        let store = try makeStore()
        let defaults = makeDefaults()
        let transport = FakeCloudTransport()
        let deviceId = "observation-device"
        let engine = makeEngine(
            store: store,
            transport: transport,
            defaults: defaults,
            deviceId: deviceId
        )

        let didChange = expectation(description: "status observation invalidated")
        withObservationTracking {
            _ = engine.status
        } onChange: {
            didChange.fulfill()
        }

        await engine.runCoordinatorCycle()
        await fulfillment(of: [didChange], timeout: 1.0)
        assertSynced(engine.status)
    }

    func testStartStillEnsuresSubscriptionWhenDefaultsContainStaleFlag() async throws {
        let store = try makeStore()
        let defaults = makeDefaults()
        defaults.set(true, forKey: "clipkitty.sync.subscriptionSaved")
        let transport = FakeCloudTransport()
        let savedSubscription = expectation(description: "subscription saved")
        transport.onSaveSubscription = {
            savedSubscription.fulfill()
        }

        let engine = makeEngine(
            store: store,
            transport: transport,
            defaults: defaults
        )
        defer { engine.stop() }

        engine.start()

        await fulfillment(of: [savedSubscription], timeout: 1.0)
        XCTAssertEqual(transport.savedSubscriptionIDs, ["clipkitty-sync-changes"])
    }
}
