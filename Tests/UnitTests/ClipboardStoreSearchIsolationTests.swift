@testable import ClipKitty
@testable import ClipKittyMacPlatform
import ClipKittyRust
import Foundation
import XCTest

/// Real-filesystem file manager that redirects Application Support to a unique
/// per-instance temp directory, so the Rust store can create a real sqlite
/// database without touching the user's data.
private final class TempAppSupportFileManager: FileManagerProtocol {
    private let base = FileManager.default
    let temporaryAppSupportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipboardStoreSearchIsolationTests-\(UUID().uuidString)", isDirectory: true)

    func fileExists(atPath path: String) -> Bool {
        base.fileExists(atPath: path)
    }

    func contents(atPath path: String) -> Data? {
        base.contents(atPath: path)
    }

    func contentsOfDirectory(atPath path: String) throws -> [String] {
        try base.contentsOfDirectory(atPath: path)
    }

    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        try base.attributesOfItem(atPath: path)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
        try base.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories, attributes: attributes)
    }

    func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        guard directory == .applicationSupportDirectory else {
            return base.urls(for: directory, in: domainMask)
        }
        return [temporaryAppSupportURL]
    }

    var homeDirectoryForCurrentUser: URL {
        base.homeDirectoryForCurrentUser
    }

    func removeItem(at url: URL) throws {
        try base.removeItem(at: url)
    }
}

@MainActor
final class ClipboardStoreSearchIsolationTests: XCTestCase {
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
}
