import ClipKittyRust
import ClipKittyStore
import XCTest

final class StoreOpenerTests: XCTestCase {
    private final class RepairProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var repairedStore: ClipKittyRust.ClipboardStore?

        func record(_ store: ClipKittyRust.ClipboardStore) {
            lock.withLock {
                repairedStore = store
            }
        }

        func store() -> ClipKittyRust.ClipboardStore? {
            lock.withLock { repairedStore }
        }
    }

    private func makeDatabasePath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-store-opener-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("clipboard.sqlite").path
    }

    func testReadyPlanSkipsCustomRepairAndAssemblesOneStoreBoundary() throws {
        let path = try makeDatabasePath()
        let probe = RepairProbe()

        let session = try StoreOpener.open(
            path: path,
            plan: .ready,
            repairStrategy: .custom { probe.record($0) }
        )

        XCTAssertNil(probe.store())
        XCTAssertTrue(session.repository.store === session.store)
    }

    func testRebuildPlanDelegatesRepairWithTheSessionStore() throws {
        let path = try makeDatabasePath()
        let probe = RepairProbe()

        let session = try StoreOpener.open(
            path: path,
            plan: .rebuildIndex,
            repairStrategy: .custom { probe.record($0) }
        )

        XCTAssertTrue(probe.store() === session.store)
        XCTAssertTrue(session.repository.store === session.store)
    }

    func testInspectAndOpenFreshStoreUsesReadyFastPath() throws {
        let path = try makeDatabasePath()

        XCTAssertEqual(try StoreOpener.inspect(path: path), .ready)
        let session = try StoreOpener.open(path: path, repairStrategy: .rebuildImmediately)

        XCTAssertTrue(session.repository.store === session.store)
    }
}
