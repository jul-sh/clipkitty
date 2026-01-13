import Testing
import Foundation
@testable import ClipKittyCore

/// Tests for the enum-driven SyncState type
/// Verifies that invalid states are structurally unrepresentable
@Suite("SyncState Enum-Driven Design")
struct SyncStateTests {

    // MARK: - State Invariants

    @Test("Local state has no metadata")
    func localStateHasNoMetadata() {
        let state = SyncState.local

        #expect(state.recordID == nil)
        #expect(state.deviceID == nil)
        #expect(state.modifiedAt == nil)
        #expect(state.databaseStatus == "local")
    }

    @Test("Pending state has deviceID and modifiedAt but no recordID")
    func pendingStateHasPartialMetadata() {
        let deviceID = "test-device-123"
        let modifiedAt = Date()
        let state = SyncState.pending(deviceID: deviceID, modifiedAt: modifiedAt)

        #expect(state.recordID == nil)
        #expect(state.deviceID == deviceID)
        #expect(state.modifiedAt == modifiedAt)
        #expect(state.databaseStatus == "pending")
        #expect(state.isPending)
        #expect(!state.isSynced)
    }

    @Test("Synced state has all metadata")
    func syncedStateHasAllMetadata() {
        let recordID = "record-abc"
        let deviceID = "device-xyz"
        let modifiedAt = Date()
        let state = SyncState.synced(recordID: recordID, deviceID: deviceID, modifiedAt: modifiedAt)

        #expect(state.recordID == recordID)
        #expect(state.deviceID == deviceID)
        #expect(state.modifiedAt == modifiedAt)
        #expect(state.databaseStatus == "synced")
        #expect(state.isSynced)
        #expect(!state.isPending)
    }

    // MARK: - Database Round-Trip

    @Test("Local state survives database round-trip")
    func localStateRoundTrip() {
        let original = SyncState.local
        let fields = original.databaseFields

        let restored = SyncState.from(
            status: fields.status,
            recordID: fields.recordID,
            deviceID: fields.deviceID,
            modifiedAt: fields.modifiedAt
        )

        #expect(restored == original)
    }

    @Test("Pending state survives database round-trip")
    func pendingStateRoundTrip() {
        let deviceID = "my-device"
        let modifiedAt = Date(timeIntervalSince1970: 1700000000)
        let original = SyncState.pending(deviceID: deviceID, modifiedAt: modifiedAt)
        let fields = original.databaseFields

        let restored = SyncState.from(
            status: fields.status,
            recordID: fields.recordID,
            deviceID: fields.deviceID,
            modifiedAt: fields.modifiedAt
        )

        #expect(restored == original)
    }

    @Test("Synced state survives database round-trip")
    func syncedStateRoundTrip() {
        let recordID = "ck-record-id"
        let deviceID = "mac-pro-2024"
        let modifiedAt = Date(timeIntervalSince1970: 1700000000)
        let original = SyncState.synced(recordID: recordID, deviceID: deviceID, modifiedAt: modifiedAt)
        let fields = original.databaseFields

        let restored = SyncState.from(
            status: fields.status,
            recordID: fields.recordID,
            deviceID: fields.deviceID,
            modifiedAt: fields.modifiedAt
        )

        #expect(restored == original)
    }

    // MARK: - Corruption Recovery

    @Test("Corrupted synced state (missing recordID) demotes to local")
    func corruptedSyncedStateMissingRecordID() {
        // Simulates database corruption where synced status exists but recordID is nil
        let restored = SyncState.from(
            status: "synced",
            recordID: nil,  // Corrupted!
            deviceID: "device",
            modifiedAt: Date()
        )

        #expect(restored == .local)
    }

    @Test("Corrupted synced state (missing deviceID) demotes to local")
    func corruptedSyncedStateMissingDeviceID() {
        let restored = SyncState.from(
            status: "synced",
            recordID: "record",
            deviceID: nil,  // Corrupted!
            modifiedAt: Date()
        )

        #expect(restored == .local)
    }

    @Test("Corrupted synced state (missing modifiedAt) demotes to local")
    func corruptedSyncedStateMissingModifiedAt() {
        let restored = SyncState.from(
            status: "synced",
            recordID: "record",
            deviceID: "device",
            modifiedAt: nil  // Corrupted!
        )

        #expect(restored == .local)
    }

    @Test("Pending state with missing deviceID uses current device")
    func pendingStateMissingDeviceIDUsesDefault() {
        let restored = SyncState.from(
            status: "pending",
            recordID: nil,
            deviceID: nil,  // Missing, but recoverable
            modifiedAt: Date()
        )

        if case .pending(let deviceID, _) = restored {
            #expect(!deviceID.isEmpty)
        } else {
            Issue.record("Expected pending state")
        }
    }

    @Test("Unknown status defaults to local")
    func unknownStatusDefaultsToLocal() {
        let restored = SyncState.from(
            status: "garbage",
            recordID: "rec",
            deviceID: "dev",
            modifiedAt: Date()
        )

        #expect(restored == .local)
    }

    @Test("Nil status defaults to local")
    func nilStatusDefaultsToLocal() {
        let restored = SyncState.from(
            status: nil,
            recordID: nil,
            deviceID: nil,
            modifiedAt: nil
        )

        #expect(restored == .local)
    }

    // MARK: - Equatable

    @Test("Same synced states are equal")
    func syncedStatesEquality() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let a = SyncState.synced(recordID: "r", deviceID: "d", modifiedAt: date)
        let b = SyncState.synced(recordID: "r", deviceID: "d", modifiedAt: date)

        #expect(a == b)
    }

    @Test("Different synced states are not equal")
    func syncedStatesInequality() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let a = SyncState.synced(recordID: "r1", deviceID: "d", modifiedAt: date)
        let b = SyncState.synced(recordID: "r2", deviceID: "d", modifiedAt: date)

        #expect(a != b)
    }
}
