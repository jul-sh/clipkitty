import ClipKittyBrowser
import ClipKittyContentServices
@testable import ClipKittyiOS
import ClipKittyRust
import ClipKittyStore
import XCTest

final class iOSFeedSnapshotTests: XCTestCase {
    private func makeMatch(id: String, text: String) -> ItemMatch {
        ItemMatch(
            itemMetadata: ItemMetadata(
                itemId: id,
                icon: .symbol(iconType: .text),
                sourceApp: "Tests",
                sourceAppBundleId: nil,
                timestampUnix: 1_725_000_000,
                tags: []
            ),
            presentation: .baseline(excerpt: BaselineExcerpt(text: text))
        )
    }

    // MARK: - Snapshot encoding

    func testSnapshotRoundTripPreservesItemsAndTotalCount() {
        let items = [
            makeMatch(id: "a", text: "first clip"),
            makeMatch(id: "b", text: "second clip"),
        ]

        let data = iOSFeedSnapshotStore.encode(items: items, totalCount: 41)
        let snapshot = iOSFeedSnapshotStore.decode(data)

        XCTAssertEqual(snapshot?.items, items)
        XCTAssertEqual(snapshot?.totalCount, 41)
    }

    func testDecodeRejectsCorruptedPayload() {
        let items = [makeMatch(id: "a", text: "clip")]
        var data = iOSFeedSnapshotStore.encode(items: items, totalCount: 1)

        // Truncation and header corruption must both fail closed.
        XCTAssertNil(iOSFeedSnapshotStore.decode(data.dropLast(3)))
        data[data.startIndex] = 0
        XCTAssertNil(iOSFeedSnapshotStore.decode(data))
        XCTAssertNil(iOSFeedSnapshotStore.decode(Data()))
    }

    func testDecodeRejectsForeignVersionStamp() {
        let items = [makeMatch(id: "a", text: "clip")]
        let data = iOSFeedSnapshotStore.encode(items: items, totalCount: 1)

        // Rewrite the embedded app-version stamp to simulate a snapshot left
        // behind by a different build of the app.
        var mutated = Data(data)
        let versionOffset = mutated.startIndex + 4 + 4 + 4
        mutated[versionOffset] ^= 0xFF
        XCTAssertNil(iOSFeedSnapshotStore.decode(mutated))
    }

    // MARK: - Warm client serving

    @MainActor
    func testWarmClientServesSnapshotForInitialFeedWhileStorePending() async {
        let handle = DeferredStoreHandle()
        let repository = ClipboardRepository(deferredStore: handle)
        let snapshot = iOSFeedSnapshot(
            items: [makeMatch(id: "warm", text: "cached row")],
            totalCount: 7
        )
        let client = iOSBrowserStoreClient(
            repository: repository,
            previewLoader: PreviewLoader(repository: repository),
            feedSnapshotting: .enabled(initial: snapshot)
        )

        let operation = client.startSearch(
            request: SearchRequest(text: "", filter: .all)
        )
        guard case let .success(response) = await operation.awaitOutcome() else {
            return XCTFail("expected the warm snapshot to serve the initial feed")
        }
        XCTAssertEqual(response.items, snapshot.items)
        XCTAssertEqual(response.totalCount, 7)
        XCTAssertNil(response.firstPreviewPayload)

        handle.revoke()
    }

    @MainActor
    func testWarmClientDefersNonInitialSearchesInsteadOfServingSnapshot() async {
        let handle = DeferredStoreHandle()
        let repository = ClipboardRepository(deferredStore: handle)
        let client = iOSBrowserStoreClient(
            repository: repository,
            previewLoader: PreviewLoader(repository: repository),
            feedSnapshotting: .enabled(initial: iOSFeedSnapshot(
                items: [makeMatch(id: "warm", text: "cached row")],
                totalCount: 1
            ))
        )

        let operation = client.startSearch(
            request: SearchRequest(text: "query", filter: .all)
        )
        let outcomeTask = Task {
            await operation.awaitOutcome()
        }
        handle.revoke()

        guard case .cancelled = await outcomeTask.value else {
            return XCTFail("expected a typed query to wait on the live store, not the snapshot")
        }
    }

    @MainActor
    func testDisabledSnapshottingNeverServesCachedRows() async {
        let handle = DeferredStoreHandle()
        let repository = ClipboardRepository(deferredStore: handle)
        let client = iOSBrowserStoreClient(
            repository: repository,
            previewLoader: PreviewLoader(repository: repository),
            feedSnapshotting: .disabled
        )

        let operation = client.startSearch(
            request: SearchRequest(text: "", filter: .all)
        )
        let outcomeTask = Task {
            await operation.awaitOutcome()
        }
        handle.revoke()

        guard case .cancelled = await outcomeTask.value else {
            return XCTFail("expected disabled snapshotting to defer to the live store")
        }
    }
}
