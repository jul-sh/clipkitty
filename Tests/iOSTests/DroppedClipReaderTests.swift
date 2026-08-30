@testable import ClipKittyiOS
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

/// Exercises the drop-to-add classification with synthetic providers shaped
/// like the ones UIKit hands over for real drags: plain text, web URLs, file
/// URLs, image data, and ClipKitty's own marked card drags.
@MainActor
final class DroppedClipReaderTests: XCTestCase {
    func testPlainTextLoadsAsText() async {
        let provider = NSItemProvider(object: "hello clip" as NSString)
        let payload = await DroppedClipReader.load(from: provider)
        XCTAssertEqual(payload, .text("hello clip"))
    }

    func testWhitespaceOnlyTextIsDeclined() async {
        let provider = NSItemProvider(object: "  \n " as NSString)
        let payload = await DroppedClipReader.load(from: provider)
        XCTAssertNil(payload)
    }

    func testWebURLLoadsAsURL() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/kitty"))
        let provider = NSItemProvider(object: url as NSURL)
        let payload = await DroppedClipReader.load(from: provider)
        XCTAssertEqual(payload, .url(url))
    }

    func testFileURLIsDeclined() async {
        let provider = NSItemProvider(object: URL(fileURLWithPath: "/tmp/notes.txt") as NSURL)
        let payload = await DroppedClipReader.load(from: provider)
        XCTAssertNil(payload)
    }

    func testImageDataLoadsAsImageAndBeatsText() async {
        let pngData = Self.tinyPNG()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(pngData, nil)
            return nil
        }
        // Real image drags often carry a text fallback too; the image must win.
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(Data("fallback".utf8), nil)
            return nil
        }
        let payload = await DroppedClipReader.load(from: provider)
        guard case let .image(data, analysis) = payload else {
            return XCTFail("Expected validated image payload")
        }
        XCTAssertEqual(data, pngData)
        XCTAssertFalse(analysis.isAnimated)
        XCTAssertNotNil(analysis.thumbnail)
    }

    func testGIFAnimationAndPreparedThumbnailArePreserved() async throws {
        let gifData = try Self.makeAnimatedGIF()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.gif.identifier, visibility: .all) { completion in
            completion(gifData, nil)
            return nil
        }
        let payload = await DroppedClipReader.load(from: provider)
        guard case let .image(data, analysis) = payload else {
            return XCTFail("Expected validated animated image payload")
        }
        XCTAssertEqual(data, gifData)
        XCTAssertTrue(analysis.isAnimated)
        XCTAssertNotNil(analysis.thumbnail)
    }

    func testStandardPolicyUsesSharedInboundLimits() {
        XCTAssertEqual(
            DroppedClipPolicy.standard.maximumItemCount,
            iOSTransferLimits.maximumItemCount
        )
        XCTAssertEqual(
            DroppedClipPolicy.standard.maximumTextByteCount,
            iOSTransferLimits.maximumTextByteCount
        )
        XCTAssertEqual(
            DroppedClipPolicy.standard.maximumImageByteCount,
            iOSTransferLimits.maximumImageByteCount
        )
        XCTAssertEqual(
            DroppedClipPolicy.standard.maximumAggregateByteCount,
            iOSTransferLimits.maximumAggregateByteCount
        )
    }

    func testTextOverConfiguredByteLimitIsDeclined() async {
        let provider = NSItemProvider(object: "hello" as NSString)

        let payload = await DroppedClipReader.load(
            from: provider,
            policy: Self.policy(maximumTextByteCount: 4)
        )

        XCTAssertNil(payload)
    }

    func testImageOverConfiguredByteLimitIsDeclined() async {
        let pngData = Self.tinyPNG()
        let provider = Self.imageProvider(data: pngData, type: .png)

        let payload = await DroppedClipReader.load(
            from: provider,
            policy: Self.policy(maximumImageByteCount: pngData.count - 1)
        )

        XCTAssertNil(payload)
    }

    func testOversizedFileRepresentationIsDeclinedAfterSizePreflight() async throws {
        let pngData = Self.tinyPNG()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try pngData.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(fileURL, false, nil)
            return nil
        }
        let payload = await DroppedClipReader.load(
            from: provider,
            policy: Self.policy(maximumImageByteCount: pngData.count - 1)
        )

        XCTAssertNil(payload)
    }

    func testTruncatedImageIsDeclinedAfterFrameValidation() async {
        let truncated = Data(Self.tinyPNG().prefix(20))
        let provider = Self.imageProvider(data: truncated, type: .png)

        let payload = await DroppedClipReader.load(from: provider)

        XCTAssertNil(payload)
    }

    func testExcessivePixelDimensionIsDeclined() async throws {
        let data = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgABhqAAAAABAQAAAAB1BSt4AAAAI0lEQVR42u3BMQEAAADCoPVPbQwfoAAAAAAAAAAAAAAAAA4GMNUAAcmPjhAAAAAASUVORK5CYII="))
        let provider = Self.imageProvider(data: data, type: .png)

        let payload = await DroppedClipReader.load(from: provider)

        XCTAssertNil(payload)
    }

    func testBatchBudgetRejectsAggregateOverflowWithoutChangingAcceptedCount() {
        var budget = DroppedClipBatchBudget(policy: Self.policy(maximumAggregateByteCount: 5))

        XCTAssertTrue(budget.admit(.text("abc")))
        XCTAssertFalse(budget.admit(.text("def")))
        XCTAssertEqual(budget.acceptedByteCount, 3)
    }

    func testNextPayloadPolicyClampsEveryPerItemLimitToAggregateRemainder() {
        var budget = DroppedClipBatchBudget(policy: DroppedClipPolicy(
            maximumItemCount: 7,
            maximumTextByteCount: 8,
            maximumImageByteCount: 10,
            maximumAggregateByteCount: 6
        ))

        XCTAssertTrue(budget.admit(.text("abcd")))
        XCTAssertEqual(budget.remainingByteCount, 2)
        XCTAssertEqual(budget.nextPayloadPolicy, DroppedClipPolicy(
            maximumItemCount: 7,
            maximumTextByteCount: 2,
            maximumImageByteCount: 2,
            maximumAggregateByteCount: 2
        ))
    }

    func testReaderDeclinesPayloadLargerThanRemainingAggregateBudget() async {
        var budget = DroppedClipBatchBudget(policy: Self.policy(
            maximumTextByteCount: 10,
            maximumAggregateByteCount: 5
        ))
        XCTAssertTrue(budget.admit(.text("abc")))

        let provider = NSItemProvider(object: "def" as NSString)
        let payload = await DroppedClipReader.load(
            from: provider,
            policy: budget.nextPayloadPolicy
        )

        XCTAssertNil(payload)
        XCTAssertEqual(budget.acceptedByteCount, 3)
    }

    func testRemainingAggregateBudgetPreflightsFileBeforeDataFallback() async throws {
        let pngData = Self.tinyPNG()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try pngData.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let dataProbe = DroppedClipProviderLoadProbe()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            dataProbe.begin(completion: completion)
            completion(pngData, nil)
            return nil
        }
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(fileURL, false, nil)
            return nil
        }
        var budget = DroppedClipBatchBudget(policy: Self.policy(
            maximumAggregateByteCount: pngData.count
        ))
        XCTAssertTrue(budget.admit(.text("x")))

        let payload = await DroppedClipReader.load(
            from: provider,
            policy: budget.nextPayloadPolicy
        )

        XCTAssertNil(payload)
        XCTAssertFalse(dataProbe.hasBegun)
    }

    func testIngestAdmissionIsSingleFlightAndIgnoresStaleCompletion() {
        let first = UUID()
        let second = UUID()
        let admission = DroppedClipIngestAdmission()

        XCTAssertTrue(admission.admit(requestID: first))
        XCTAssertFalse(admission.admit(requestID: second))
        XCTAssertTrue(admission.owns(requestID: first))

        XCTAssertFalse(admission.finish(requestID: second))
        XCTAssertTrue(admission.owns(requestID: first))

        XCTAssertTrue(admission.finish(requestID: first))
        XCTAssertTrue(admission.admit(requestID: second))
        XCTAssertTrue(admission.finish(requestID: second))
        XCTAssertNil(admission.activeRequestID)
    }

    func testProviderCountIsCappedBeforeMaterialization() {
        let providers = (0 ..< 4).map { _ in
            NSItemProvider(object: "clip" as NSString)
        }
        let policy = Self.policy(maximumItemCount: 2)

        let bounded = policy.boundedProviders(providers)

        XCTAssertEqual(bounded.count, 2)
        XCTAssertTrue(bounded[0] === providers[0])
        XCTAssertTrue(bounded[1] === providers[1])
    }

    func testPendingImageLoadCancellationCancelsProgressAndIgnoresLateCallback() async {
        let probe = DroppedClipProviderLoadProbe()
        let progress = Progress(totalUnitCount: 1)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            probe.begin(completion: completion)
            return progress
        }

        let task = Task { @MainActor in
            await DroppedClipReader.load(from: provider)
        }
        await eventually { probe.hasBegun }

        task.cancel()
        let payload = await task.value

        XCTAssertNil(payload)
        XCTAssertTrue(progress.isCancelled)

        // Some providers call back despite cancellation. The bridge must
        // discard that value instead of resuming its continuation twice.
        probe.complete(data: Self.tinyPNG())
        await Task.yield()
        XCTAssertNil(payload)
    }

    func testInternalCardDragIsRecognized() {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: DragItemProvider.internalDragMarker,
            visibility: .ownProcess
        ) { completion in
            completion(Data(), nil)
            return nil
        }
        XCTAssertTrue(DroppedClipReader.isInternalDrag(provider))
        XCTAssertFalse(DroppedClipReader.isInternalDrag(NSItemProvider(object: "text" as NSString)))
    }

    func testCardDragProviderCarriesInternalMarker() {
        let provider = DragItemProvider.make(itemId: "item-1") { _ in nil }
        XCTAssertTrue(DroppedClipReader.isInternalDrag(provider))
    }

    /// A 1x1 opaque PNG rendered at runtime, so the test needs no fixture.
    private static func tinyPNG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let image = renderer.image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return image.pngData() ?? Data()
    }

    private static func imageProvider(data: Data, type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: type.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private static func policy(
        maximumItemCount: Int = iOSTransferLimits.maximumItemCount,
        maximumTextByteCount: Int = iOSTransferLimits.maximumTextByteCount,
        maximumImageByteCount: Int = iOSTransferLimits.maximumImageByteCount,
        maximumAggregateByteCount: Int = iOSTransferLimits.maximumAggregateByteCount
    ) -> DroppedClipPolicy {
        DroppedClipPolicy(
            maximumItemCount: maximumItemCount,
            maximumTextByteCount: maximumTextByteCount,
            maximumImageByteCount: maximumImageByteCount,
            maximumAggregateByteCount: maximumAggregateByteCount
        )
    }

    private static func makeAnimatedGIF() throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output,
            UTType.gif.identifier as CFString,
            2,
            nil
        ))
        let first = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let second = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 0.1,
            ],
        ]
        try CGImageDestinationAddImage(
            destination,
            XCTUnwrap(first.cgImage),
            frameProperties as CFDictionary
        )
        try CGImageDestinationAddImage(
            destination,
            XCTUnwrap(second.cgImage),
            frameProperties as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Condition did not become true before timeout")
    }
}

private final class DroppedClipProviderLoadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didBegin = false
    private var completion: ((Data?, Error?) -> Void)?

    var hasBegun: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didBegin
    }

    func begin(completion: @escaping (Data?, Error?) -> Void) {
        lock.lock()
        didBegin = true
        self.completion = completion
        lock.unlock()
    }

    func complete(data: Data?) {
        let completion: ((Data?, Error?) -> Void)?
        lock.lock()
        completion = self.completion
        self.completion = nil
        lock.unlock()
        completion?(data, nil)
    }
}
