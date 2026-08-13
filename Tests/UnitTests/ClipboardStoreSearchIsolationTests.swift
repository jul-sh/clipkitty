@testable import ClipKitty
@testable import ClipKittyMacPlatform
import ClipKittyRust
import ClipKittyStore
import Foundation
import XCTest

/// Real-filesystem file manager that redirects Application Support to a unique
/// per-instance temp directory, so the Rust store can create a real sqlite
/// database without touching the user's data.
private final class TempAppSupportFileManager: FileManagerProtocol {
    private let base = FileManager.default
    let temporaryAppSupportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipboardStoreSearchIsolationTests-\(UUID().uuidString)", isDirectory: true)

    func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
        try base.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories, attributes: attributes)
    }

    func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        guard directory == .applicationSupportDirectory else {
            return base.urls(for: directory, in: domainMask)
        }
        return [temporaryAppSupportURL]
    }
}

@MainActor
final class ClipboardStoreSearchIsolationTests: XCTestCase {
    func testAwaitReadyPublishesReadyStateBeforeReturningFromIndexRebuild() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardStoreReadinessTests-\(UUID().uuidString)")
        let databaseURL = testRoot.appendingPathComponent("clipboard.sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: testRoot)
        }

        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        try seedDatabase(at: databaseURL)
        for entry in try FileManager.default.contentsOfDirectory(
            at: testRoot,
            includingPropertiesForKeys: nil
        ) where entry.lastPathComponent.hasPrefix("tantivy_index_") {
            try FileManager.default.removeItem(at: entry)
        }
        XCTAssertEqual(try StoreOpener.inspect(path: databaseURL.path), .rebuildIndex)

        let store = ClipboardStore(
            databaseLocation: .explicit(databaseURL),
            pasteboard: MockPasteboard(),
            workspace: MockWorkspace()
        )

        await store.awaitReady()

        XCTAssertEqual(store.lifecycle, .ready)
        let outcome = await store.startSearch(
            query: "",
            filter: .all,
            presentation: .compactRow
        ).awaitOutcome()
        switch outcome {
        case let .success(result):
            XCTAssertEqual(result.totalCount, 1)
        case .cancelled:
            XCTFail("Search was unexpectedly cancelled immediately after awaitReady")
        case let .failure(error):
            XCTFail("Search failed immediately after awaitReady: \(error.localizedDescription)")
        }
    }

    func testExplicitDatabaseLocationsKeepIndexesIsolated() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardStoreDatabaseLocationTests-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: testRoot)
        }

        let firstDirectory = testRoot.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = testRoot.appendingPathComponent("second", isDirectory: true)
        let firstStore = ClipboardStore(
            databaseLocation: .explicit(firstDirectory.appendingPathComponent("clipboard.sqlite")),
            pasteboard: MockPasteboard(),
            workspace: MockWorkspace()
        )
        let secondStore = ClipboardStore(
            databaseLocation: .explicit(secondDirectory.appendingPathComponent("clipboard.sqlite")),
            pasteboard: MockPasteboard(),
            workspace: MockWorkspace()
        )

        await firstStore.awaitReady()
        await secondStore.awaitReady()

        XCTAssertEqual(firstStore.lifecycle, .ready)
        XCTAssertEqual(secondStore.lifecycle, .ready)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: firstDirectory.path)
                .contains(where: { $0.hasPrefix("tantivy_index_") })
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: secondDirectory.path)
                .contains(where: { $0.hasPrefix("tantivy_index_") })
        )
    }

    func testBackgroundMutationDoesNotCancelInFlightBrowserSearch() async {
        let fileManager = TempAppSupportFileManager()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fileManager.temporaryAppSupportURL)
        }

        let store = ClipboardStore(
            pasteboard: MockPasteboard(),
            workspace: MockWorkspace(),
            fileManager: fileManager
        )
        await store.awaitReady()
        XCTAssertEqual(store.lifecycle, .ready)
        store.setPanelVisibility(true)

        let operation = store.startSearch(query: "invoice", filter: .all, presentation: .compactRow)
        // clearAll bumps contentRevision via invalidateContent mid-flight; that
        // path previously triggered refresh -> beginSearch, which cancelled the
        // browser's in-flight search via the store's global search token.
        _ = await store.clearAll()

        let outcome = await operation.awaitOutcome()
        if case .cancelled = outcome {
            XCTFail("Background mutation must not cancel the in-flight browser search")
        }
        XCTAssertGreaterThan(store.contentRevision, 0)
    }

    private func seedDatabase(at databaseURL: URL) throws {
        let store = try ClipKittyRust.ClipboardStore(dbPath: databaseURL.path)
        _ = try store.saveText(
            text: "ready after rebuild",
            sourceApp: nil,
            sourceAppBundleId: nil
        )
    }
}
