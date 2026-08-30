@testable import ClipKittyiOS
import ClipKittyRust
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

@MainActor
private final class ExternalTransferBackgroundProbe {
    private let identifier: UIBackgroundTaskIdentifier
    private var expirationHandler: (@MainActor @Sendable () -> Void)?
    private(set) var endedIdentifiers: [UIBackgroundTaskIdentifier] = []

    init(identifier: UIBackgroundTaskIdentifier) {
        self.identifier = identifier
    }

    func makeClient() -> AppBackgroundTaskClient {
        AppBackgroundTaskClient(
            begin: { [weak self] _, expirationHandler in
                self?.expirationHandler = expirationHandler
                return self?.identifier ?? .invalid
            },
            end: { [weak self] identifier in
                self?.endedIdentifiers.append(identifier)
            }
        )
    }

    func expire() {
        guard let expirationHandler else {
            XCTFail("Expected external-transfer expiration handler")
            return
        }
        expirationHandler()
    }
}

final class ExternalCopyTransferGateTests: XCTestCase {
    @MainActor
    func testPayloadBuilderBoundsAndDeduplicatesBeforeProviderCreation() {
        let policy = DragItemProvider.SessionPolicy(
            maximumItemCount: 3,
            maximumTransferByteCount: 1024,
            maximumConcurrentLoads: 2
        )

        let payload = ExternalCopyDragPayload(
            itemIDs: ["third", "first", "third", "second", "ignored"],
            policy: policy,
            fetchSnapshot: { _ in nil }
        )

        XCTAssertEqual(payload.itemIDs, ["third", "first", "second"])
        XCTAssertEqual(payload.items.count, 3)
    }

    func testContentKindMapsAllMetadataIconVariants() {
        XCTAssertEqual(DragItemProvider.ContentKind(icon: .symbol(iconType: .text)), .text)
        XCTAssertEqual(DragItemProvider.ContentKind(icon: .symbol(iconType: .color)), .color)
        XCTAssertEqual(DragItemProvider.ContentKind(icon: .symbol(iconType: .link)), .link)
        XCTAssertEqual(DragItemProvider.ContentKind(icon: .symbol(iconType: .image)), .image)
        XCTAssertEqual(DragItemProvider.ContentKind(icon: .symbol(iconType: .file)), .file)
        XCTAssertEqual(DragItemProvider.ContentKind(icon: .colorSwatch(rgba: 0)), .color)
        XCTAssertEqual(DragItemProvider.ContentKind(icon: .thumbnail(bytes: Data())), .image)
    }

    @MainActor
    func testContentDescriptorsAdvertiseOnlyRelevantPublicRepresentations() {
        let textTypes = Self.registeredTypes(for: .text)
        XCTAssertTrue(textTypes.contains(UTType.plainText.identifier))
        XCTAssertTrue(textTypes.contains(UTType.utf8PlainText.identifier))
        XCTAssertFalse(textTypes.contains(UTType.url.identifier))
        XCTAssertFalse(textTypes.contains(UTType.image.identifier))

        let linkTypes = Self.registeredTypes(for: .link)
        XCTAssertTrue(linkTypes.contains(UTType.plainText.identifier))
        XCTAssertTrue(linkTypes.contains(UTType.url.identifier))
        XCTAssertFalse(linkTypes.contains(UTType.image.identifier))

        let imageTypes = Self.registeredTypes(for: .image)
        XCTAssertTrue(imageTypes.contains(UTType.plainText.identifier))
        XCTAssertTrue(imageTypes.contains(UTType.image.identifier))
        XCTAssertFalse(imageTypes.contains(UTType.url.identifier))

        let fileTypes = Self.registeredTypes(for: .file)
        XCTAssertTrue(fileTypes.contains(UTType.plainText.identifier))
        XCTAssertFalse(fileTypes.contains(UTType.url.identifier))
        XCTAssertFalse(fileTypes.contains(UTType.image.identifier))
    }

    @MainActor
    func testDirectProviderRetainsLazySessionAfterCreatorReturns() async throws {
        let provider: NSItemProvider = DragItemProvider.make(
            itemId: "ordinary",
            contentKind: .text,
            fetch: { itemID in
                Self.makeTextItem(id: itemID, text: "still available")
            }
        )

        // Match SwiftUI's `.onDrag` lifecycle: its provider-producing closure
        // has returned before UIKit asks the provider for promised data.
        await Task.yield()
        let loaded = try await Self.loadData(
            from: provider,
            typeIdentifier: UTType.utf8PlainText.identifier
        )

        XCTAssertEqual(loaded, Data("still available".utf8))
    }

    func testTextRepresentationFailsClosedForStaleDescriptorOrEmptyValue() {
        let text = Self.makeTextItem(id: "text", text: "hello")
        XCTAssertNil(
            DragItemProvider.textRepresentationData(from: text, expectedContentKind: .image)
        )

        let imageWithoutDescription = ClipboardItem(
            itemMetadata: text.itemMetadata,
            content: .image(data: Data([1]), description: "", isAnimated: false)
        )
        XCTAssertNil(
            DragItemProvider.textRepresentationData(
                from: imageWithoutDescription,
                expectedContentKind: .image
            )
        )
    }

    func testTransferFetchMustReturnTheRequestedItemID() async {
        let session = DragItemProvider.TransferSession()

        do {
            _ = try await session.loadRepresentation(
                itemID: "requested",
                typeIdentifier: UTType.utf8PlainText.identifier,
                fetch: { _ in Self.makeTextItem(id: "different", text: "wrong") },
                extract: Self.textDataResolver
            )
            XCTFail("Expected an id mismatch to fail closed")
        } catch {
            XCTAssertEqual(
                error as? DragItemProvider.LoadError,
                .unavailable(typeIdentifier: UTType.utf8PlainText.identifier)
            )
        }
    }

    func testSessionExpiryRequiresTheExactScheduledStateToken() {
        let scheduled = UUID()

        XCTAssertTrue(
            ExternalCopyDragSessionExpiryPolicy.shouldExpire(
                currentToken: scheduled,
                scheduledToken: scheduled
            )
        )
        XCTAssertFalse(
            ExternalCopyDragSessionExpiryPolicy.shouldExpire(
                currentToken: UUID(),
                scheduledToken: scheduled
            )
        )
        XCTAssertFalse(
            ExternalCopyDragSessionExpiryPolicy.shouldExpire(
                currentToken: nil,
                scheduledToken: scheduled
            )
        )
    }

    func testTransferBudgetIsSharedAcrossItems() async throws {
        let session = DragItemProvider.TransferSession(
            policy: .init(
                maximumItemCount: 50,
                maximumTransferByteCount: 5,
                maximumConcurrentLoads: 2
            )
        )

        let first = try await session.loadRepresentation(
            itemID: "first",
            typeIdentifier: UTType.utf8PlainText.identifier,
            fetch: { Self.makeTextItem(id: $0, text: "abc") },
            extract: Self.textDataResolver
        )
        XCTAssertEqual(first, Data("abc".utf8))

        do {
            _ = try await session.loadRepresentation(
                itemID: "second",
                typeIdentifier: UTType.utf8PlainText.identifier,
                fetch: { Self.makeTextItem(id: $0, text: "def") },
                extract: Self.textDataResolver
            )
            XCTFail("Expected the shared byte budget to reject the second item")
        } catch {
            XCTAssertEqual(error as? DragItemProvider.LoadError, .transferBudgetExceeded)
        }

        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.transferredByteCount, 3)
        XCTAssertEqual(snapshot.memoizedItemCount, 1)
    }

    func testSharedTransferBudgetIncludesRetainedImageDescriptionBytes() async throws {
        let session = DragItemProvider.TransferSession(
            policy: .init(
                maximumItemCount: 50,
                maximumTransferByteCount: 10,
                maximumConcurrentLoads: 2
            )
        )

        let imageData = Data([1, 2, 3])
        let first = try await session.loadRepresentation(
            itemID: "image",
            typeIdentifier: UTType.image.identifier,
            fetch: {
                Self.makeImageItem(
                    id: $0,
                    data: imageData,
                    description: "four"
                )
            },
            extract: { item in
                guard case let .image(data, _, _) = item.content else { return nil }
                return data
            }
        )
        XCTAssertEqual(first, imageData)

        do {
            _ = try await session.loadRepresentation(
                itemID: "text",
                typeIdentifier: UTType.utf8PlainText.identifier,
                fetch: { Self.makeTextItem(id: $0, text: "more") },
                extract: Self.textDataResolver
            )
            XCTFail("Expected image data plus its description to consume seven bytes")
        } catch {
            XCTAssertEqual(error as? DragItemProvider.LoadError, .transferBudgetExceeded)
        }

        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.transferredByteCount, 7)
        XCTAssertEqual(snapshot.memoizedItemCount, 1)
    }

    func testMaterializedImagePayloadUsesOverflowSafeAggregateAccounting() {
        let content = ClipboardContent.image(
            data: Data(count: iOSTransferLimits.maximumImageByteCount),
            description: "x",
            isAnimated: false
        )

        XCTAssertEqual(
            DragItemProvider.materializedPayloadByteCount(content),
            .failure(.aggregateTooLarge)
        )
    }

    func testMaterializedLinkPayloadIncludesSecureCodedURLRepresentation() async throws {
        let value = "https://example.com/a/path?query=clipkitty"
        let item = Self.makeLinkItem(id: "link", value: value)
        let archivedURL = try XCTUnwrap(
            DragItemProvider.urlRepresentationData(
                from: item,
                expectedContentKind: .link
            )
        )
        let expectedByteCount = value.utf8.count + archivedURL.count

        XCTAssertEqual(
            try? DragItemProvider.materializedPayloadByteCount(item.content).get(),
            expectedByteCount
        )

        let session = DragItemProvider.TransferSession(
            policy: .init(
                maximumItemCount: 1,
                maximumTransferByteCount: expectedByteCount - 1,
                maximumConcurrentLoads: 1
            )
        )
        do {
            _ = try await session.loadRepresentation(
                itemID: "link",
                typeIdentifier: UTType.utf8PlainText.identifier,
                fetch: { _ in item },
                extract: {
                    DragItemProvider.textRepresentationData(
                        from: $0,
                        expectedContentKind: .link
                    )
                }
            )
            XCTFail("Expected the URL archive to participate in the shared byte budget")
        } catch {
            XCTAssertEqual(error as? DragItemProvider.LoadError, .transferBudgetExceeded)
        }
    }

    func testSessionMemoizesOneFetchPerItem() async throws {
        let session = DragItemProvider.TransferSession()
        let probe = FetchProbe()

        async let first = session.loadRepresentation(
            itemID: "same",
            typeIdentifier: UTType.plainText.identifier,
            fetch: { itemID in
                await probe.beginFetch()
                try? await Task.sleep(nanoseconds: 50_000_000)
                await probe.endFetch()
                return Self.makeTextItem(id: itemID, text: "memoized")
            },
            extract: Self.textDataResolver
        )
        async let second = session.loadRepresentation(
            itemID: "same",
            typeIdentifier: UTType.utf8PlainText.identifier,
            fetch: { itemID in
                await probe.beginFetch()
                try? await Task.sleep(nanoseconds: 50_000_000)
                await probe.endFetch()
                return Self.makeTextItem(id: itemID, text: "memoized")
            },
            extract: Self.textDataResolver
        )

        let values = try await[first, second]
        let totalFetchCount = await probe.totalFetchCount
        let snapshot = await session.snapshot()
        XCTAssertEqual(values, [Data("memoized".utf8), Data("memoized".utf8)])
        XCTAssertEqual(totalFetchCount, 1)
        XCTAssertEqual(snapshot.memoizedItemCount, 1)
        XCTAssertEqual(snapshot.transferredByteCount, Data("memoized".utf8).count)
    }

    func testSessionAllowsAtMostTwoConcurrentLoads() async {
        let session = DragItemProvider.TransferSession(
            policy: .init(
                maximumItemCount: 50,
                maximumTransferByteCount: 1024,
                maximumConcurrentLoads: 2
            )
        )
        let probe = FetchProbe()

        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for index in 0 ..< 8 {
                group.addTask {
                    do {
                        _ = try await session.loadRepresentation(
                            itemID: "item-\(index)",
                            typeIdentifier: UTType.utf8PlainText.identifier,
                            fetch: { itemID in
                                await probe.beginFetch()
                                try? await Task.sleep(nanoseconds: 30_000_000)
                                await probe.endFetch()
                                return Self.makeTextItem(id: itemID, text: itemID)
                            },
                            extract: Self.textDataResolver
                        )
                        return true
                    } catch {
                        return false
                    }
                }
            }

            var values: [Bool] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(results.count, 8)
        XCTAssertTrue(results.allSatisfy { $0 })
        let maximumConcurrentFetchCount = await probe.maximumConcurrentFetchCount
        let snapshot = await session.snapshot()
        XCTAssertLessThanOrEqual(maximumConcurrentFetchCount, 2)
        XCTAssertEqual(snapshot.maximumObservedConcurrentLoads, 2)
    }

    func testCancellingDequeuedWaiterDoesNotRetainMarkerOrPermit() async throws {
        let firstFetchStarted = expectation(description: "first fetch started")
        let waiterDequeued = expectation(description: "queued waiter dequeued")
        let releaseFirstFetch = AppSessionWorkCompletion()
        let finishWaiterHandoff = DispatchSemaphore(value: 0)
        let session = DragItemProvider.TransferSession(
            policy: .init(
                maximumItemCount: 3,
                maximumTransferByteCount: 1024,
                maximumConcurrentLoads: 1
            ),
            _onWaiterDequeued: {
                waiterDequeued.fulfill()
                finishWaiterHandoff.wait()
            }
        )

        let first = Task {
            try await session.loadRepresentation(
                itemID: "first",
                typeIdentifier: UTType.utf8PlainText.identifier,
                fetch: { itemID in
                    firstFetchStarted.fulfill()
                    await releaseFirstFetch.wait()
                    return Self.makeTextItem(id: itemID, text: itemID)
                },
                extract: Self.textDataResolver
            )
        }
        await fulfillment(of: [firstFetchStarted], timeout: 2)

        let second = Task {
            try await session.loadRepresentation(
                itemID: "second",
                typeIdentifier: UTType.utf8PlainText.identifier,
                fetch: { Self.makeTextItem(id: $0, text: $0) },
                extract: Self.textDataResolver
            )
        }

        for _ in 0 ..< 200 {
            if (await session.snapshot()).queuedLoadCount == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let queued = await session.snapshot()
        XCTAssertEqual(queued.queuedLoadCount, 1)

        releaseFirstFetch.finish()
        await fulfillment(of: [waiterDequeued], timeout: 2)

        // The waiter is no longer in the queue, but its continuation has not
        // resumed. This is the ordering that used to leave its UUID forever in
        // `cancelledWaiterIDs` after the cancellation callback found no waiter.
        second.cancel()
        await Task.yield()
        finishWaiterHandoff.signal()

        _ = try await first.value
        do {
            _ = try await second.value
            XCTFail("Expected the dequeued waiter to observe cancellation")
        } catch {
            XCTAssertEqual(error as? DragItemProvider.LoadError, .cancelled)
        }

        let settled = await session.snapshot()
        XCTAssertEqual(settled.activeLoadCount, 0)
        XCTAssertEqual(settled.queuedLoadCount, 0)
        XCTAssertEqual(settled.pendingCancelledWaiterCount, 0)

        let third = try await session.loadRepresentation(
            itemID: "third",
            typeIdentifier: UTType.utf8PlainText.identifier,
            fetch: { Self.makeTextItem(id: $0, text: $0) },
            extract: Self.textDataResolver
        )
        XCTAssertEqual(third, Data("third".utf8))
        let final = await session.snapshot()
        XCTAssertEqual(final.activeLoadCount, 0)
    }

    func testCancellingSessionCancelsInFlightFetchAndLoad() async {
        let session = DragItemProvider.TransferSession()
        let load = Task {
            try await session.loadRepresentation(
                itemID: "slow",
                typeIdentifier: UTType.utf8PlainText.identifier,
                fetch: { itemID in
                    do {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                        return Self.makeTextItem(id: itemID, text: "late")
                    } catch {
                        return nil
                    }
                },
                extract: Self.textDataResolver
            )
        }

        try? await Task.sleep(nanoseconds: 30_000_000)
        await session.cancelAndWait()

        do {
            _ = try await load.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? DragItemProvider.LoadError, .cancelled)
        }
        let snapshot = await session.snapshot()
        XCTAssertTrue(snapshot.isCancelled)
    }

    @MainActor
    func testNormalPayloadFinishKeepsAppSuspensionPendingForBlockedProviderFetch() async throws {
        let appState = try makeAppState(named: "normal-provider-finish")
        let background = ExternalTransferBackgroundProbe(
            identifier: UIBackgroundTaskIdentifier(rawValue: 301)
        )
        let lease = try XCTUnwrap(
            appState.beginExternalTransfer(backgroundTaskClient: background.makeClient())
        )
        let fetchStarted = AppSessionWorkCompletion()
        let releaseFetch = AppSessionWorkCompletion()
        let payload = ExternalCopyDragPayload(
            descriptors: [ExternalCopyDragItemDescriptor(itemID: "slow", contentKind: .text)],
            externalTransferLease: lease,
            fetchSnapshot: { itemID in
                fetchStarted.finish()
                await releaseFetch.wait()
                return TransferItemSnapshot(
                    item: Self.makeTextItem(id: itemID, text: "late"),
                    deletionToken: "token"
                )
            }
        )
        let provider = try XCTUnwrap(payload.items.first?.itemProvider)
        let providerLoad = Task {
            try? await Self.loadData(from: provider, typeIdentifier: UTType.utf8PlainText.identifier)
        }
        await fetchStarted.wait()

        let join = try XCTUnwrap(suspensionJoin(for: appState))
        var didJoin = false
        let observer = Task { @MainActor in
            await join.value
            didJoin = true
        }
        payload.finish()
        await Task.yield()
        XCTAssertFalse(didJoin)
        XCTAssertTrue(background.endedIdentifiers.isEmpty)

        releaseFetch.finish()
        _ = await providerLoad.value
        await observer.value

        XCTAssertTrue(didJoin)
        XCTAssertEqual(background.endedIdentifiers, [UIBackgroundTaskIdentifier(rawValue: 301)])
    }

    @MainActor
    func testExpirationKeepsAppSuspensionPendingForBlockedProviderFetch() async throws {
        let appState = try makeAppState(named: "expired-provider-fetch")
        let identifier = UIBackgroundTaskIdentifier(rawValue: 302)
        let background = ExternalTransferBackgroundProbe(identifier: identifier)
        let lease = try XCTUnwrap(
            appState.beginExternalTransfer(backgroundTaskClient: background.makeClient())
        )
        let fetchStarted = AppSessionWorkCompletion()
        let releaseFetch = AppSessionWorkCompletion()
        let payload = ExternalCopyDragPayload(
            descriptors: [ExternalCopyDragItemDescriptor(itemID: "slow", contentKind: .text)],
            externalTransferLease: lease,
            fetchSnapshot: { itemID in
                fetchStarted.finish()
                await releaseFetch.wait()
                return TransferItemSnapshot(
                    item: Self.makeTextItem(id: itemID, text: "late"),
                    deletionToken: "token"
                )
            }
        )
        let provider = try XCTUnwrap(payload.items.first?.itemProvider)
        let providerLoad = Task {
            try? await Self.loadData(from: provider, typeIdentifier: UTType.utf8PlainText.identifier)
        }
        await fetchStarted.wait()

        let join = try XCTUnwrap(suspensionJoin(for: appState))
        var didJoin = false
        let observer = Task { @MainActor in
            await join.value
            didJoin = true
        }
        background.expire()
        XCTAssertEqual(background.endedIdentifiers, [identifier])
        await Task.yield()
        XCTAssertFalse(didJoin)

        releaseFetch.finish()
        _ = await providerLoad.value
        await observer.value

        XCTAssertTrue(didJoin)
        XCTAssertEqual(background.endedIdentifiers, [identifier])
    }

    @MainActor
    func testExpirationKeepsAppSuspensionPendingForBlockedConditionalDeleteFollowUp() async throws {
        let appState = try makeAppState(named: "expired-conditional-delete")
        let identifier = UIBackgroundTaskIdentifier(rawValue: 303)
        let background = ExternalTransferBackgroundProbe(identifier: identifier)
        let lease = try XCTUnwrap(
            appState.beginExternalTransfer(backgroundTaskClient: background.makeClient())
        )
        let payload = ExternalCopyDragPayload(
            itemIDs: [],
            externalTransferLease: lease,
            fetchSnapshot: { _ in nil }
        )
        let deleteStarted = AppSessionWorkCompletion()
        let allowDeleteToReturn = AppSessionWorkCompletion()
        var didReconcileCommittedDelete = false
        let followUp = ExternalCopyDragFollowUp.start(
            payload: payload,
            evidence: [ExternalCopyTransferEvidence(itemID: "item", deletionToken: "token")],
            completion: { _ in
                deleteStarted.finish()
                // Model a conditional delete that was admitted before expiry:
                // cancellation must not release the terminal store join until
                // its authoritative result has been reconciled.
                await allowDeleteToReturn.wait()
                didReconcileCommittedDelete = true
            }
        )
        await deleteStarted.wait()

        let join = try XCTUnwrap(suspensionJoin(for: appState))
        var didJoin = false
        let observer = Task { @MainActor in
            await join.value
            didJoin = true
        }
        background.expire()
        XCTAssertEqual(background.endedIdentifiers, [identifier])
        await Task.yield()
        XCTAssertFalse(didJoin)

        allowDeleteToReturn.finish()
        await followUp.value
        await observer.value

        XCTAssertTrue(didReconcileCommittedDelete)
        XCTAssertTrue(didJoin)
        XCTAssertEqual(background.endedIdentifiers, [identifier])
    }

    @MainActor
    func testImageRepresentationPreservesNativeJPEGBytesAndTruthfulUTI() async throws {
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).jpegData(
            withCompressionQuality: 0.8,
            actions: { context in
                UIColor.systemPink.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }
        )
        let payload = ExternalCopyDragPayload(
            descriptors: [
                ExternalCopyDragItemDescriptor(itemID: "jpeg", contentKind: .image),
            ],
            fetchSnapshot: { itemID in
                TransferItemSnapshot(
                    item: Self.makeImageItem(id: itemID, data: jpeg),
                    deletionToken: "jpeg-token"
                )
            }
        )
        let provider = try XCTUnwrap(payload.items.first?.itemProvider)

        XCTAssertTrue(provider.registeredTypeIdentifiers.contains(UTType.image.identifier))
        XCTAssertFalse(provider.registeredTypeIdentifiers.contains(UTType.png.identifier))

        let loaded = try await Self.loadData(
            from: provider,
            typeIdentifier: UTType.image.identifier
        )
        XCTAssertEqual(loaded, jpeg)
        XCTAssertEqual(DragItemProvider.nativeImageTypeIdentifier(for: loaded), UTType.jpeg.identifier)
    }

    func testNativeGIFTypeIsDetectedWithoutTranscoding() throws {
        let gif = try XCTUnwrap(
            Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")
        )

        XCTAssertEqual(DragItemProvider.nativeImageTypeIdentifier(for: gif), UTType.gif.identifier)
    }

    func testItemLoadStateRequiresTokenAndSuccessfulPublicRepresentation() {
        let state = ExternalCopyDragItemLoadState()

        XCTAssertNil(state.completedTransferEvidence(itemID: "item"))

        XCTAssertTrue(state.recordDeletionToken("token"))
        XCTAssertNil(state.completedTransferEvidence(itemID: "item"))
        state.recordRepresentationLoad(succeeded: true)
        XCTAssertEqual(
            state.completedTransferEvidence(itemID: "item"),
            ExternalCopyTransferEvidence(itemID: "item", deletionToken: "token")
        )
    }

    func testItemLoadStateFailsClosedAfterAnyRequestedRepresentationFails() {
        let state = ExternalCopyDragItemLoadState()

        XCTAssertTrue(state.recordDeletionToken("token"))
        state.recordRepresentationLoad(succeeded: true)
        state.recordRepresentationLoad(succeeded: false)

        XCTAssertNil(state.completedTransferEvidence(itemID: "item"))
    }

    func testItemLoadStateFailsClosedForMissingOrConflictingDeletionToken() {
        let missing = ExternalCopyDragItemLoadState()
        XCTAssertFalse(missing.recordDeletionToken(""))
        XCTAssertFalse(missing.recordDeletionToken("later-token"))
        missing.recordRepresentationLoad(succeeded: true)
        XCTAssertNil(missing.completedTransferEvidence(itemID: "item"))

        let conflicting = ExternalCopyDragItemLoadState()
        XCTAssertTrue(conflicting.recordDeletionToken("first-token"))
        XCTAssertFalse(conflicting.recordDeletionToken("different-token"))
        XCTAssertFalse(conflicting.recordDeletionToken("first-token"))
        conflicting.recordRepresentationLoad(succeeded: true)
        XCTAssertNil(conflicting.completedTransferEvidence(itemID: "item"))
    }

    @MainActor
    func testManagedPayloadEmitsExactSnapshotEvidenceOnlyAfterPublicLoad() async throws {
        let payload = ExternalCopyDragPayload(
            descriptors: [
                ExternalCopyDragItemDescriptor(itemID: "loaded", contentKind: .text),
                ExternalCopyDragItemDescriptor(itemID: "not-requested", contentKind: .text),
            ],
            fetchSnapshot: { itemID in
                TransferItemSnapshot(
                    item: Self.makeTextItem(id: itemID, text: itemID),
                    deletionToken: "token-\(itemID)"
                )
            }
        )
        let provider = try XCTUnwrap(payload.items.first?.itemProvider)

        XCTAssertTrue(payload.completedTransferEvidence.isEmpty)
        _ = try await Self.loadData(
            from: provider,
            typeIdentifier: UTType.utf8PlainText.identifier
        )

        XCTAssertEqual(
            payload.completedTransferEvidence,
            [
                ExternalCopyTransferEvidence(
                    itemID: "loaded",
                    deletionToken: "token-loaded"
                ),
            ]
        )
    }

    @MainActor
    func testManagedPayloadRejectsEmptySnapshotTokenWithoutEmittingEvidence() async throws {
        let payload = ExternalCopyDragPayload(
            descriptors: [
                ExternalCopyDragItemDescriptor(itemID: "item", contentKind: .text),
            ],
            fetchSnapshot: { itemID in
                TransferItemSnapshot(
                    item: Self.makeTextItem(id: itemID, text: "text"),
                    deletionToken: ""
                )
            }
        )
        let provider = try XCTUnwrap(payload.items.first?.itemProvider)

        do {
            _ = try await Self.loadData(
                from: provider,
                typeIdentifier: UTType.utf8PlainText.identifier
            )
            XCTFail("Expected an empty deletion token to make the managed load unavailable")
        } catch {
            XCTAssertNotNil(error)
        }
        XCTAssertTrue(payload.completedTransferEvidence.isEmpty)
    }

    func testPayloadPreservesItemOrder() {
        let items = ["third", "first", "second"].map { itemID in
            ExternalCopyDragItem(
                itemID: itemID,
                itemProvider: NSItemProvider(),
                loadState: ExternalCopyDragItemLoadState()
            )
        }

        XCTAssertEqual(ExternalCopyDragPayload(items: items).itemIDs, ["third", "first", "second"])
    }

    func testExternalCopyCompletesExactlyOnceAfterTransfer() {
        var gate = ExternalCopyTransferGate()
        gate.recordEnd(operation: .copy, isOutsideApplicationWindows: true)

        XCTAssertTrue(gate.observeDataTransferCompleted())
        XCTAssertFalse(gate.observeDataTransferCompleted())
    }

    func testCopyInsideApplicationRetainsItem() {
        var gate = ExternalCopyTransferGate()
        gate.recordEnd(operation: .copy, isOutsideApplicationWindows: false)

        XCTAssertFalse(gate.observeDataTransferCompleted())
    }

    func testCancelledDragRetainsItem() {
        var gate = ExternalCopyTransferGate()
        gate.recordEnd(operation: .cancel, isOutsideApplicationWindows: true)

        XCTAssertFalse(gate.observeDataTransferCompleted())
    }

    func testForbiddenDragRetainsItem() {
        var gate = ExternalCopyTransferGate()
        gate.recordEnd(operation: .forbidden, isOutsideApplicationWindows: true)

        XCTAssertFalse(gate.observeDataTransferCompleted())
    }

    func testMoveRetainsItemEvenOutsideApplicationGeometry() {
        var gate = ExternalCopyTransferGate()
        gate.recordEnd(operation: .move, isOutsideApplicationWindows: true)

        XCTAssertFalse(gate.observeDataTransferCompleted())
    }

    func testUnknownOperationRetainsItem() {
        var gate = ExternalCopyTransferGate()
        gate.recordEnd(operation: .unknown, isOutsideApplicationWindows: true)

        XCTAssertFalse(gate.observeDataTransferCompleted())
    }

    func testTransferBeforeTerminalResultFailsClosed() {
        var gate = ExternalCopyTransferGate()

        XCTAssertFalse(gate.observeDataTransferCompleted())
        gate.recordEnd(operation: .copy, isOutsideApplicationWindows: true)
        XCTAssertFalse(gate.observeDataTransferCompleted())
    }

    func testFirstTerminalResultWins() {
        var gate = ExternalCopyTransferGate()
        gate.recordEnd(operation: .cancel, isOutsideApplicationWindows: true)
        gate.recordEnd(operation: .copy, isOutsideApplicationWindows: true)

        XCTAssertFalse(gate.observeDataTransferCompleted())
    }

    func testUIKitOperationMapping() {
        XCTAssertEqual(ExternalCopyTransferGate.Operation(.cancel), .cancel)
        XCTAssertEqual(ExternalCopyTransferGate.Operation(.forbidden), .forbidden)
        XCTAssertEqual(ExternalCopyTransferGate.Operation(.copy), .copy)
        XCTAssertEqual(ExternalCopyTransferGate.Operation(.move), .move)
    }

    func testDropOutsideEveryApplicationWindowIsExternal() {
        let windows = [
            ExternalDropWindowGeometry(
                bounds: CGRect(x: 0, y: 0, width: 400, height: 800),
                dropLocation: CGPoint(x: 450, y: 200)
            ),
            ExternalDropWindowGeometry(
                bounds: CGRect(x: 0, y: 0, width: 300, height: 500),
                dropLocation: CGPoint(x: -20, y: 200)
            ),
        ]

        XCTAssertTrue(ExternalDropGeometryClassifier.isOutsideApplicationWindows(windows))
    }

    func testAllBackgroundScenesClassifyFullScreenDropAsExternal() {
        XCTAssertTrue(
            ExternalDragScenePolicy.isExternalDestination([
                .background,
                .background,
            ])
        )
    }

    func testForegroundWindowsTakePrecedenceOverBackgroundScenes() {
        XCTAssertFalse(
            ExternalDragScenePolicy.isExternalDestination([
                .background,
                .foreground(windows: [
                    ExternalDropWindowGeometry(
                        bounds: CGRect(x: 0, y: 0, width: 400, height: 800),
                        dropLocation: CGPoint(x: 200, y: 300)
                    ),
                ]),
            ])
        )
        XCTAssertTrue(
            ExternalDragScenePolicy.isExternalDestination([
                .background,
                .foreground(windows: [
                    ExternalDropWindowGeometry(
                        bounds: CGRect(x: 0, y: 0, width: 400, height: 800),
                        dropLocation: CGPoint(x: 450, y: 300)
                    ),
                ]),
            ])
        )
    }

    func testForegroundSceneWithoutVisibleGeometryFailsClosed() {
        XCTAssertFalse(
            ExternalDragScenePolicy.isExternalDestination([
                .background,
                .foreground(windows: []),
            ])
        )
    }

    func testAmbiguousOrMissingSceneStateFailsClosed() {
        let outsideWindow = ExternalDropWindowGeometry(
            bounds: CGRect(x: 0, y: 0, width: 400, height: 800),
            dropLocation: CGPoint(x: 450, y: 300)
        )

        XCTAssertFalse(ExternalDragScenePolicy.isExternalDestination([]))
        XCTAssertFalse(
            ExternalDragScenePolicy.isExternalDestination([.background, .unattached])
        )
        XCTAssertFalse(
            ExternalDragScenePolicy.isExternalDestination([.background, .unknown])
        )
        XCTAssertFalse(ExternalDragScenePolicy.isExternalDestination([.unattached]))
        XCTAssertFalse(ExternalDragScenePolicy.isExternalDestination([.unknown]))
        XCTAssertFalse(
            ExternalDragScenePolicy.isExternalDestination([
                .foreground(windows: [outsideWindow]),
                .unattached,
            ])
        )
        XCTAssertFalse(
            ExternalDragScenePolicy.isExternalDestination([
                .foreground(windows: [outsideWindow]),
                .unknown,
            ])
        )
    }

    func testDropInsideAnyApplicationWindowIsInternal() {
        let windows = [
            ExternalDropWindowGeometry(
                bounds: CGRect(x: 0, y: 0, width: 400, height: 800),
                dropLocation: CGPoint(x: 450, y: 200)
            ),
            ExternalDropWindowGeometry(
                bounds: CGRect(x: 0, y: 0, width: 300, height: 500),
                dropLocation: CGPoint(x: 150, y: 200)
            ),
        ]

        XCTAssertFalse(ExternalDropGeometryClassifier.isOutsideApplicationWindows(windows))
    }

    func testMissingWindowGeometryFailsClosed() {
        XCTAssertFalse(ExternalDropGeometryClassifier.isOutsideApplicationWindows([]))
    }

    func testNonFiniteWindowLocationsFailClosed() {
        let windows = [
            ExternalDropWindowGeometry(
                bounds: CGRect(x: 0, y: 0, width: 400, height: 800),
                dropLocation: CGPoint(x: CGFloat.nan, y: 200)
            ),
            ExternalDropWindowGeometry(
                bounds: CGRect(x: 0, y: 0, width: 300, height: 500),
                dropLocation: CGPoint(x: 500, y: CGFloat.infinity)
            ),
        ]

        XCTAssertFalse(ExternalDropGeometryClassifier.isOutsideApplicationWindows(windows))
    }

    private static func makeTextItem(id: String, text: String) -> ClipboardItem {
        ClipboardItem(
            itemMetadata: ItemMetadata(
                itemId: id,
                icon: .symbol(iconType: .text),
                sourceApp: nil,
                sourceAppBundleId: nil,
                timestampUnix: 0,
                tags: []
            ),
            content: .text(value: text)
        )
    }

    @MainActor
    private func makeAppState(named name: String) throws -> AppState {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipKittyExternalTransferTests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory
            .appendingPathComponent("\(name)-\(UUID().uuidString).db")
            .path
        guard case let .success(container) = AppContainer.bootstrap(databasePath: path) else {
            throw NSError(domain: "ExternalCopyTransferGateTests", code: 1)
        }
        return AppState(container: container)
    }

    @MainActor
    private func suspensionJoin(for appState: AppState) -> Task<Void, Never>? {
        switch appState.prepareForSuspension() {
        case .quiescent:
            return nil
        case let .awaiting(task):
            return task
        }
    }

    private static func makeImageItem(
        id: String,
        data: Data,
        description: String = "image"
    ) -> ClipboardItem {
        ClipboardItem(
            itemMetadata: ItemMetadata(
                itemId: id,
                icon: .symbol(iconType: .image),
                sourceApp: nil,
                sourceAppBundleId: nil,
                timestampUnix: 0,
                tags: []
            ),
            content: .image(data: data, description: description, isAnimated: false)
        )
    }

    private static func makeLinkItem(id: String, value: String) -> ClipboardItem {
        ClipboardItem(
            itemMetadata: ItemMetadata(
                itemId: id,
                icon: .symbol(iconType: .link),
                sourceApp: nil,
                sourceAppBundleId: nil,
                timestampUnix: 0,
                tags: []
            ),
            content: .link(url: value, metadataState: .pending)
        )
    }

    private static let textDataResolver: @Sendable (ClipboardItem) -> Data? = { item in
        guard case let .text(value) = item.content else { return nil }
        return Data(value.utf8)
    }

    private static func loadData(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(
                        throwing: error ?? DragItemProvider.LoadError.unavailable(
                            typeIdentifier: typeIdentifier
                        )
                    )
                }
            }
        }
    }

    @MainActor
    private static func registeredTypes(for contentKind: DragItemProvider.ContentKind) -> Set<String> {
        Set(
            DragItemProvider.make(
                itemId: "item",
                contentKind: contentKind,
                fetch: { _ in nil }
            ).registeredTypeIdentifiers
        )
    }
}

private actor FetchProbe {
    private var activeFetchCount = 0
    private(set) var maximumConcurrentFetchCount = 0
    private(set) var totalFetchCount = 0

    func beginFetch() {
        activeFetchCount += 1
        totalFetchCount += 1
        maximumConcurrentFetchCount = max(maximumConcurrentFetchCount, activeFetchCount)
    }

    func endFetch() {
        activeFetchCount -= 1
    }
}
