@testable import ClipKittyContentServices
@testable import ClipKittyiOS
import ClipKittyRust
import ImageIO
import LinkPresentation
import UIKit
import UniformTypeIdentifiers
import XCTest

@MainActor
final class iOSClipboardServiceBulkCopyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var originalPasteboardItems: [[String: Any]] = []

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "iOSClipboardServiceBulkCopyTests")!
        defaults.removePersistentDomain(forName: "iOSClipboardServiceBulkCopyTests")
        originalPasteboardItems = UIPasteboard.general.items
    }

    override func tearDown() {
        UIPasteboard.general.items = originalPasteboardItems
        defaults.removePersistentDomain(forName: "iOSClipboardServiceBulkCopyTests")
        defaults = nil
        super.tearDown()
    }

    func testBulkCopyWritesOrderedNativeItemsAndAcknowledgesOnce() async {
        let settings = iOSSettingsStore(defaults: defaults)
        let service = iOSClipboardService(settings: settings)

        let copied = await service.copy(contents: [
            .text(value: "first"),
            .text(value: "second"),
        ])

        XCTAssertTrue(copied)
        XCTAssertEqual(UIPasteboard.general.strings, ["first", "second"])
        XCTAssertEqual(
            settings.lastIngestedPasteboardChangeCount,
            UIPasteboard.general.changeCount
        )
    }

    func testFailedBulkEncodingLeavesExistingClipboardUntouched() async {
        UIPasteboard.general.string = "keep me"
        let settings = iOSSettingsStore(defaults: defaults)
        let service = iOSClipboardService(settings: settings)

        let copied = await service.copy(contents: [
            .text(value: "replacement"),
            .image(data: Data(), description: "invalid", isAnimated: false),
        ])

        XCTAssertFalse(copied)
        XCTAssertEqual(UIPasteboard.general.string, "keep me")
    }

    func testFailedSingleImageCopyLeavesClipboardAndAcknowledgementUntouched() async {
        UIPasteboard.general.string = "keep me"
        let settings = iOSSettingsStore(defaults: defaults)
        settings.lastIngestedPasteboardChangeCount = 12345
        let service = iOSClipboardService(settings: settings)

        let copied = await service.copy(content: .image(
            data: Data("not an image".utf8),
            description: "invalid",
            isAnimated: false
        ))

        XCTAssertFalse(copied)
        XCTAssertEqual(UIPasteboard.general.string, "keep me")
        XCTAssertEqual(settings.lastIngestedPasteboardChangeCount, 12345)
    }

    func testCancelledImageCopyLeavesClipboardAndAcknowledgementUntouched() async {
        UIPasteboard.general.string = "keep me"
        let settings = iOSSettingsStore(defaults: defaults)
        settings.lastIngestedPasteboardChangeCount = 12345
        let service = iOSClipboardService(settings: settings)

        // This test itself owns the main actor, so the child cannot begin
        // before cancellation is recorded and the test yields at `task.value`.
        let task = Task { @MainActor in
            await service.copy(content: .image(
                data: Self.onePixelPNG,
                description: "pixel",
                isAnimated: false
            ))
        }
        task.cancel()
        let copied = await task.value

        XCTAssertFalse(copied)
        XCTAssertEqual(UIPasteboard.general.string, "keep me")
        XCTAssertEqual(settings.lastIngestedPasteboardChangeCount, 12345)
    }

    func testSingleAnimatedImageCopyPreservesNativeBytes() async throws {
        let gif = try Self.makeAnimatedGIF()
        let settings = iOSSettingsStore(defaults: defaults)
        let service = iOSClipboardService(settings: settings)

        let copied = await service.copy(content: .image(
            data: gif,
            description: "animated",
            isAnimated: true
        ))

        XCTAssertTrue(copied)
        XCTAssertEqual(
            UIPasteboard.general.data(forPasteboardType: UTType.gif.identifier),
            gif
        )
        XCTAssertEqual(
            settings.lastIngestedPasteboardChangeCount,
            UIPasteboard.general.changeCount
        )
    }

    func testSharePreparationPreservesAnimatedNativeImageBytesAndType() async throws {
        let gif = try Self.makeAnimatedGIF()
        let item = Self.makeItem(content: .image(
            data: gif,
            description: "animated",
            isAnimated: true
        ))

        let prepared = await SharePresenter.prepare(item: item)
        let payload = try XCTUnwrap(prepared)

        guard case let .image(image) = payload else {
            return XCTFail("Expected a native image share payload")
        }
        XCTAssertEqual(image.data, gif)
        XCTAssertEqual(image.typeIdentifier, UTType.gif.identifier)
    }

    func testSharePreparationRejectsMalformedImage() async {
        let item = Self.makeItem(content: .image(
            data: Data("not an image".utf8),
            description: "invalid",
            isAnimated: false
        ))

        let payload = await SharePresenter.prepare(item: item)

        XCTAssertNil(payload)
    }

    func testCancelledSharePreparationReturnsWithoutPayload() async {
        let item = Self.makeItem(content: .image(
            data: Self.onePixelPNG,
            description: "pixel",
            isAnimated: false
        ))
        let task = Task { @MainActor in
            await SharePresenter.prepare(item: item)
        }
        task.cancel()

        let payload = await task.value

        XCTAssertNil(payload)
    }

    func testSharePreparationUsesURLAndMalformedLinkTextFallback() async throws {
        let valid = Self.makeItem(content: .link(
            url: "https://example.com/path",
            metadataState: .pending
        ))
        let malformed = Self.makeItem(content: .link(
            url: "not a URL",
            metadataState: .pending
        ))

        let validPayload = await SharePresenter.prepare(item: valid)
        let malformedPayload = await SharePresenter.prepare(item: malformed)

        XCTAssertEqual(validPayload, try .url(XCTUnwrap(URL(string: "https://example.com/path"))))
        XCTAssertEqual(malformedPayload, .text("not a URL"))
    }

    func testLinkMetadataCancellationCancelsProviderAndIgnoresLateCompletion() async {
        let probe = LinkMetadataFetchDriverProbe()
        let fetcher = LinkMetadataFetcher(driverFactory: {
            probe.driver
        })
        let task = Task { @MainActor in
            await fetcher.fetchMetadata(
                for: "https://example.com",
                itemId: "cancelled-preview"
            )
        }
        await eventually { probe.hasStarted }

        task.cancel()
        let result = await task.value

        XCTAssertNil(result)
        XCTAssertTrue(probe.wasCancelled)
        probe.complete(LPLinkMetadata())
        XCTAssertEqual(probe.completionAfterCancellationCount, 1)
    }

    func testLinkMetadataImagePreparationRejectsOversizedAndMalformedData() async {
        let policy = Self.linkImagePolicy(maximumSourceByteCount: 4)

        let oversized = await LinkMetadataImagePreparer.prepare(
            Data(repeating: 1, count: 5),
            policy: policy
        )
        let malformed = await LinkMetadataImagePreparer.prepare(
            Data(repeating: 1, count: 4),
            policy: policy
        )

        XCTAssertNil(oversized)
        XCTAssertNil(malformed)
    }

    func testLinkMetadataImagePreparationSuspendsMainActorAndCancelsPromptly() async {
        let probe = BlockingLinkMetadataImageProcessorProbe()
        let limiter = LinkMetadataImageWorkLimiter(maximumConcurrentWork: 1)
        let task = Task { @MainActor in
            await LinkMetadataImagePreparer.prepare(
                Data([1]),
                policy: Self.linkImagePolicy(maximumSourceByteCount: 1),
                limiter: limiter,
                processor: { data, policy in
                    probe.process(data, policy: policy)
                }
            )
        }
        await eventually { probe.hasStarted }

        // Reaching this assertion proves the injected codec is not occupying
        // the main actor. Cancellation must resume before that codec returns.
        XCTAssertFalse(task.isCancelled)
        task.cancel()
        let result = await task.value

        XCTAssertNil(result)
        XCTAssertFalse(probe.hasFinished)
        XCTAssertEqual(limiter.snapshot().activeCount, 1)
        probe.release()
        await eventually {
            probe.hasFinished && limiter.snapshot().activeCount == 0
        }
    }

    func testLinkMetadataImageLimiterReleasesCancelledQueuedPayload() async throws {
        let limiter = LinkMetadataImageWorkLimiter(maximumConcurrentWork: 1)
        let blocker = BlockingLinkMetadataLimiterWorkProbe()
        let activeID = UUID()
        limiter.submit(id: activeID) {
            blocker.run()
        }
        await eventually { blocker.hasStarted }

        let queuedID = UUID()
        var retained: LinkMetadataRetainedWorkProbe? = LinkMetadataRetainedWorkProbe()
        let weakRetained = WeakLinkMetadataRetainedWorkProbe(retained)
        let cancellation = LinkMetadataLimiterCancellationProbe()
        try Self.submitRetainedLinkMetadataWork(
            retained: XCTUnwrap(retained),
            id: queuedID,
            limiter: limiter,
            cancellation: cancellation
        )
        XCTAssertEqual(limiter.snapshot().pendingCount, 1)
        retained = nil

        limiter.cancel(id: queuedID)

        XCTAssertEqual(limiter.snapshot().pendingCount, 0)
        XCTAssertTrue(cancellation.wasCalled)
        XCTAssertNil(weakRetained.value)
        blocker.release()
        await eventually { limiter.snapshot().activeCount == 0 }
    }

    func testLocalWriteAcknowledgementRequiresExactlyOneGenerationAdvance() {
        XCTAssertEqual(
            PasteboardLocalWriteAcknowledgement.generation(before: 10, after: 11),
            11
        )
        XCTAssertNil(PasteboardLocalWriteAcknowledgement.generation(before: 10, after: 10))
        XCTAssertNil(PasteboardLocalWriteAcknowledgement.generation(before: 10, after: 12))
        XCTAssertNil(PasteboardLocalWriteAcknowledgement.generation(before: Int.max, after: Int.min))
    }

    func testOverLimitBulkCopyLeavesClipboardAndAcknowledgementUntouched() async {
        UIPasteboard.general.string = "keep me"
        let settings = iOSSettingsStore(defaults: defaults)
        settings.lastIngestedPasteboardChangeCount = 12345
        let service = iOSClipboardService(settings: settings)
        let contents = (0 ... iOSTransferLimits.maximumItemCount).map { index in
            ClipboardContent.text(value: "item-\(index)")
        }

        let copied = await service.copy(contents: contents)
        XCTAssertFalse(copied)
        XCTAssertEqual(UIPasteboard.general.string, "keep me")
        XCTAssertEqual(settings.lastIngestedPasteboardChangeCount, 12345)
    }

    func testPasteboardImageAnalysisRejectsMalformedAdvertisedBytes() {
        XCTAssertNil(PasteboardImageInspector.analyze(Data("not an image".utf8)))
    }

    func testPasteboardImageAnalysisAcceptsDecodableImage() throws {
        let png = try XCTUnwrap(
            Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        )

        let analysis = try XCTUnwrap(PasteboardImageInspector.analyze(png))
        XCTAssertFalse(analysis.isAnimated)
    }

    func testAutomaticReadUsesOnlyTheFirstPasteboardItem() async {
        UIPasteboard.general.items = [
            [UTType.plainText.identifier: "first"],
            [UTType.plainText.identifier: "second"],
        ]
        let service = iOSClipboardService(
            settings: iOSSettingsStore(defaults: defaults)
        )

        let result = await readAutomaticClipboardEventually(using: service)

        XCTAssertEqual(result, .content(.text("first")))
    }

    func testAutomaticReadIgnoresConcealedFirstItemByDefault() async {
        UIPasteboard.general.items = [[
            "org.nspasteboard.ConcealedType": Data(),
            UTType.plainText.identifier: "secret",
        ]]
        let service = iOSClipboardService(
            settings: iOSSettingsStore(defaults: defaults)
        )

        let result = await service.readCurrentClipboardForAutomaticIngest()

        XCTAssertEqual(result, .ignored)
    }

    func testAutomaticReadAllowsConcealedFirstItemAfterOptIn() async {
        UIPasteboard.general.items = [[
            "org.nspasteboard.ConcealedType": Data(),
            UTType.plainText.identifier: "secret",
        ]]
        let settings = iOSSettingsStore(defaults: defaults)
        settings.captureSensitiveClips = true
        let service = iOSClipboardService(settings: settings)

        let result = await service.readCurrentClipboardForAutomaticIngest()

        XCTAssertEqual(result, .content(.text("secret")))
    }

    func testAutomaticLoaderPrioritizesConcreteNativeImageBytes() async {
        let expected = Self.onePixelPNG
        let coerced = Data("coerced image".utf8)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.image.identifier,
            visibility: .all
        ) { completion in
            completion(coerced, nil)
            return nil
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            completion(expected, nil)
            return nil
        }

        let result = await load(
            provider: provider,
            typeIdentifiers: [UTType.image.identifier, UTType.png.identifier]
        )

        assertImageContent(result, equals: expected)
    }

    func testAutomaticLoaderPreservesNativeAnimatedImageBytes() async throws {
        let expected = try Self.makeAnimatedGIF()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.gif.identifier,
            visibility: .all
        ) { completion in
            completion(expected, nil)
            return nil
        }

        let result = await load(
            provider: provider,
            typeIdentifiers: [UTType.gif.identifier]
        )

        assertImageContent(result, equals: expected, isAnimated: true)
    }

    func testAutomaticLoaderFallsThroughFailedConcreteImageTypes() async {
        let expected = Self.onePixelPNG
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            completion(nil, TestProviderError.unavailable)
            return nil
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.jpeg.identifier,
            visibility: .all
        ) { completion in
            completion(expected, nil)
            return nil
        }

        let result = await load(
            provider: provider,
            typeIdentifiers: [UTType.png.identifier, UTType.jpeg.identifier]
        )

        assertImageContent(result, equals: expected)
    }

    func testAutomaticLoaderPreservesURLAndTextSemantics() async throws {
        let url = try XCTUnwrap(URL(string: "https://clipkitty.app/path?q=one"))
        let urlProvider = NSItemProvider(object: url as NSURL)
        let textProvider = NSItemProvider(object: "hello" as NSString)

        let urlResult = await load(
            provider: urlProvider,
            typeIdentifiers: [UTType.url.identifier]
        )
        let textResult = await load(
            provider: textProvider,
            typeIdentifiers: [UTType.plainText.identifier]
        )

        XCTAssertEqual(urlResult, .content(.link(url)))
        XCTAssertEqual(textResult, .content(.text("hello")))
    }

    func testAutomaticLoaderIgnoresRepresentationsOverTheirLimit() async {
        let provider = NSItemProvider(
            item: Data(repeating: 1, count: 5) as NSData,
            typeIdentifier: UTType.png.identifier
        )

        let result = await load(
            provider: provider,
            typeIdentifiers: [UTType.png.identifier],
            maximumImageByteCount: 4
        )

        XCTAssertEqual(result, .ignored)
    }

    func testAutomaticLoaderPreflightsFileRepresentationBeforeBoundedRead() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try Data(repeating: 7, count: 5).write(to: fileURL, options: .atomic)
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

        let result = await load(
            provider: provider,
            typeIdentifiers: [UTType.png.identifier],
            maximumImageByteCount: 4
        )

        XCTAssertEqual(result, .ignored)
    }

    func testAutomaticLoaderPreservesBoundedFileRepresentationBytes() async throws {
        let expected = Self.onePixelPNG
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try expected.write(to: fileURL, options: .atomic)
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

        let result = await load(
            provider: provider,
            typeIdentifiers: [UTType.png.identifier],
            maximumImageByteCount: expected.count
        )

        assertImageContent(result, equals: expected)
    }

    func testAutomaticLoaderReturnsTemporarilyUnavailableForAdvertisedFailure() async {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            completion(nil, TestProviderError.unavailable)
            return nil
        }

        let result = await load(
            provider: provider,
            typeIdentifiers: [UTType.png.identifier]
        )

        XCTAssertEqual(result, .temporarilyUnavailable)
    }

    func testTransientImageRepresentationWinsOverOversizedSibling() async {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            completion(Data(repeating: 1, count: 5), nil)
            return nil
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.jpeg.identifier,
            visibility: .all
        ) { completion in
            completion(nil, TestProviderError.unavailable)
            return nil
        }

        let result = await load(
            provider: provider,
            typeIdentifiers: [UTType.png.identifier, UTType.jpeg.identifier],
            maximumImageByteCount: 4
        )

        XCTAssertEqual(result, .temporarilyUnavailable)
    }

    func testAutomaticLoaderIgnoresTextThatCannotVendAString() async {
        let provider = NSItemProvider(
            item: Data("{\\rtf1 unsupported}".utf8) as NSData,
            typeIdentifier: UTType.rtf.identifier
        )

        let result = await load(
            provider: provider,
            typeIdentifiers: [UTType.rtf.identifier]
        )

        XCTAssertEqual(result, .ignored)
    }

    func testAutomaticLoaderSuspendsMainActorAndCancelsProviderProgress() async {
        let probe = ProviderLoadProbe()
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
            await self.load(
                provider: provider,
                typeIdentifiers: [UTType.png.identifier]
            )
        }
        await eventually { probe.hasBegun }

        // Reaching this main-actor line while the representation is pending is
        // the regression check: Auto-Add suspended instead of blocking UIKit.
        XCTAssertFalse(task.isCancelled)
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, .temporarilyUnavailable)
        XCTAssertTrue(progress.isCancelled)
    }

    private func load(
        provider: NSItemProvider,
        typeIdentifiers: [String],
        maximumTextByteCount: Int = 1024,
        maximumImageByteCount: Int = 1024
    ) async -> AutomaticPasteboardReadResult {
        await AutomaticPasteboardLoader.load(
            snapshot: AutomaticPasteboardSnapshot(
                typeIdentifiers: typeIdentifiers,
                itemProvider: provider
            ),
            limits: AutomaticPasteboardLimits(
                maximumTextByteCount: maximumTextByteCount,
                maximumImageByteCount: maximumImageByteCount
            )
        )
    }

    private func assertImageContent(
        _ result: AutomaticPasteboardReadResult,
        equals expectedData: Data,
        isAnimated: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .content(.image(data, analysis)) = result else {
            return XCTFail("Expected image content, got \(result)", file: file, line: line)
        }
        XCTAssertEqual(data, expectedData, file: file, line: line)
        XCTAssertEqual(analysis.isAnimated, isAnimated, file: file, line: line)
    }

    private func readAutomaticClipboardEventually(
        using service: iOSClipboardService,
        timeout: Duration = .seconds(1)
    ) async -> AutomaticPasteboardReadResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var result = await service.readCurrentClipboardForAutomaticIngest()
        while result == .temporarilyUnavailable, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            result = await service.readCurrentClipboardForAutomaticIngest()
        }
        return result
    }

    private static func makeItem(content: ClipboardContent) -> ClipboardItem {
        ClipboardItem(
            itemMetadata: ItemMetadata(
                itemId: UUID().uuidString,
                icon: .symbol(iconType: .text),
                sourceApp: nil,
                sourceAppBundleId: nil,
                timestampUnix: 0,
                tags: []
            ),
            content: content
        )
    }

    private static func linkImagePolicy(
        maximumSourceByteCount: Int
    ) -> LinkMetadataImagePolicy {
        LinkMetadataImagePolicy(
            maximumSourceByteCount: maximumSourceByteCount,
            maximumSourcePixelDimension: 64,
            maximumSourcePixelCount: 4096,
            maximumNativeFrameCount: 2,
            maximumNativeAggregatePixelCount: 4096,
            maximumOutputPixelDimension: 64,
            maximumOutputPixelCount: 4096,
            maximumOutputByteCount: 4096,
            validationThumbnailDimension: 8
        )
    }

    private static func submitRetainedLinkMetadataWork(
        retained: LinkMetadataRetainedWorkProbe,
        id: UUID,
        limiter: LinkMetadataImageWorkLimiter,
        cancellation: LinkMetadataLimiterCancellationProbe
    ) {
        limiter.submit(id: id, cancelPending: {
            cancellation.call()
        }) {
            retained.touch()
        }
    }

    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

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

private enum TestProviderError: Error {
    case unavailable
}

private final class ProviderLoadProbe: @unchecked Sendable {
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
}

private final class LinkMetadataFetchDriverProbe: @unchecked Sendable {
    private enum State {
        case idle
        case awaiting(CheckedContinuation<LPLinkMetadata, Error>)
        case cancelled
        case completed
    }

    private let lock = NSLock()
    private var state = State.idle
    private var started = false
    private var cancelled = false
    private var lateCompletionCount = 0

    var driver: LinkMetadataFetchDriver {
        LinkMetadataFetchDriver(
            fetch: { [self] _ in
                try await fetch()
            },
            cancel: { [self] in
                cancel()
            }
        )
    }

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var completionAfterCancellationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lateCompletionCount
    }

    func complete(_ metadata: LPLinkMetadata) {
        let continuation: CheckedContinuation<LPLinkMetadata, Error>?
        lock.lock()
        switch state {
        case let .awaiting(waiter):
            state = .completed
            continuation = waiter
        case .cancelled:
            lateCompletionCount += 1
            continuation = nil
        case .idle, .completed:
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: metadata)
    }

    private func fetch() async throws -> LPLinkMetadata {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            started = true
            switch state {
            case .idle:
                state = .awaiting(continuation)
                lock.unlock()
            case .cancelled:
                lock.unlock()
                continuation.resume(throwing: CancellationError())
            case .awaiting, .completed:
                lock.unlock()
                preconditionFailure("metadata driver fetched more than once")
            }
        }
    }

    private func cancel() {
        let continuation: CheckedContinuation<LPLinkMetadata, Error>?
        lock.lock()
        cancelled = true
        switch state {
        case .idle:
            state = .cancelled
            continuation = nil
        case let .awaiting(waiter):
            state = .cancelled
            continuation = waiter
        case .cancelled, .completed:
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

private final class BlockingLinkMetadataImageProcessorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var started = false
    private var finished = false

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var hasFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func process(_ data: Data, policy _: LinkMetadataImagePolicy) -> Data? {
        lock.lock()
        started = true
        lock.unlock()
        gate.wait()
        lock.lock()
        finished = true
        lock.unlock()
        return data
    }

    func release() {
        gate.signal()
    }
}

private final class BlockingLinkMetadataLimiterWorkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var started = false

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func run() {
        lock.lock()
        started = true
        lock.unlock()
        gate.wait()
    }

    func release() {
        gate.signal()
    }
}

private final class LinkMetadataRetainedWorkProbe: @unchecked Sendable {
    func touch() {}
}

private final class LinkMetadataLimiterCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false

    var wasCalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return called
    }

    func call() {
        lock.lock()
        called = true
        lock.unlock()
    }
}

private final class WeakLinkMetadataRetainedWorkProbe {
    private(set) weak var value: LinkMetadataRetainedWorkProbe?

    init(_ value: LinkMetadataRetainedWorkProbe?) {
        self.value = value
    }
}
