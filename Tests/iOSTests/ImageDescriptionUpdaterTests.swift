@testable import ClipKittyContentServices
import ClipKittyRust
import ClipKittyStore
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class ImageDescriptionUpdaterTests: TemporaryDirectoryTestCase {
    func testVisionInputDecodeDoesNotBlockMainActor() async {
        let decodeStarted = expectation(description: "utility-queue ImageIO decode started")
        let mainActorResponded = expectation(description: "main actor remained responsive")
        let releaseDecode = DispatchSemaphore(value: 0)
        let threadProbe = VisionDecodeThreadProbe()

        let decode = Task { @MainActor in
            await ImageDescriptionGenerator.decodeVisionInput {
                let isMainThread = Thread.isMainThread
                threadProbe.record(isMainThread: isMainThread)
                decodeStarted.fulfill()
                guard !isMainThread else { return nil }
                releaseDecode.wait()
                return nil
            }
        }

        await fulfillment(of: [decodeStarted], timeout: 2)
        XCTAssertEqual(threadProbe.isMainThread, false)
        let mainActorProbe = Task { @MainActor in
            mainActorResponded.fulfill()
        }
        await fulfillment(of: [mainActorResponded], timeout: 1)

        releaseDecode.signal()
        _ = await decode.value
        _ = await mainActorProbe.value
    }

    func testCancellingVisionInputDecodePromptlyStopsAwaitingImageIO() async {
        let decodeStarted = expectation(description: "utility-queue ImageIO decode started")
        let callerResumed = expectation(description: "cancelled decode caller resumed")
        let decodeFinished = expectation(description: "late ImageIO decode finished safely")
        let releaseDecode = DispatchSemaphore(value: 0)
        let threadProbe = VisionDecodeThreadProbe()

        let decode = Task {
            await ImageDescriptionGenerator.decodeVisionInput {
                let isMainThread = Thread.isMainThread
                threadProbe.record(isMainThread: isMainThread)
                decodeStarted.fulfill()
                guard !isMainThread else { return nil }
                releaseDecode.wait()
                decodeFinished.fulfill()
                return nil
            }
        }
        await fulfillment(of: [decodeStarted], timeout: 2)
        XCTAssertEqual(threadProbe.isMainThread, false)

        decode.cancel()
        let waiter = Task {
            let result = await decode.value
            XCTAssertNil(result)
            callerResumed.fulfill()
        }
        await fulfillment(of: [callerResumed], timeout: 1)

        // The deliberately uncooperative worker finishes after its caller has
        // already resumed; its late result must be ignored safely.
        releaseDecode.signal()
        await fulfillment(of: [decodeFinished], timeout: 2)
        _ = await waiter.value
    }

    func testWorkLimiterKeepsConcurrencyAtOneUntilCancelledWorkActuallyReturns() async {
        let limiter = ImageDescriptionWorkLimiter(label: "test.image-description.serial.\(UUID())")
        let probe = ImageDescriptionWorkProbe()
        let firstStarted = expectation(description: "first actual worker started")
        let cancelledCallerReturned = expectation(description: "cancelled caller returned")
        let secondStarted = expectation(description: "second actual worker started")
        let releaseFirstWorker = DispatchSemaphore(value: 0)
        defer { releaseFirstWorker.signal() }

        let first = Task {
            await limiter.run(cancellationValue: -1) {
                probe.begin("first")
                defer { probe.finish("first") }
                firstStarted.fulfill()
                releaseFirstWorker.wait()
                return 99
            }
        }
        await fulfillment(of: [firstStarted], timeout: 2)

        first.cancel()
        let firstResult = ImageDescriptionValueProbe<Int>()
        let cancelledCaller = Task {
            firstResult.record(await first.value)
            cancelledCallerReturned.fulfill()
        }
        await fulfillment(of: [cancelledCallerReturned], timeout: 1)
        XCTAssertEqual(firstResult.value, -1)

        let second = Task {
            await limiter.run(cancellationValue: -2) {
                probe.begin("second")
                defer { probe.finish("second") }
                secondStarted.fulfill()
                return 2
            }
        }
        let secondQueued = await waitUntil {
            let snapshot = limiter.snapshot()
            return snapshot.hasActiveWork && snapshot.pendingCount == 1
        }
        XCTAssertTrue(secondQueued)
        XCTAssertEqual(probe.snapshot.activeCount, 1)
        XCTAssertEqual(probe.snapshot.maximumActiveCount, 1)
        XCTAssertEqual(probe.snapshot.startedIDs, ["first"])

        releaseFirstWorker.signal()
        await fulfillment(of: [secondStarted], timeout: 2)
        let secondResult = await second.value
        XCTAssertEqual(secondResult, 2)
        _ = await cancelledCaller.value

        let drained = await waitUntil {
            limiter.snapshot() == ImageDescriptionWorkLimiterSnapshot(
                pendingCount: 0,
                hasActiveWork: false,
                isDrainScheduled: false
            )
        }
        XCTAssertTrue(drained)
        XCTAssertEqual(probe.snapshot.maximumActiveCount, 1)
        XCTAssertEqual(probe.snapshot.startedIDs, ["first", "second"])
        XCTAssertEqual(probe.snapshot.finishedIDs, ["first", "second"])
    }

    func testWorkLimiterRemovesCancelledQueuedWorkBeforeExecution() async {
        let limiter = ImageDescriptionWorkLimiter(label: "test.image-description.queued.\(UUID())")
        let probe = ImageDescriptionWorkProbe()
        let activeStarted = expectation(description: "active worker started")
        let releaseActiveWorker = DispatchSemaphore(value: 0)
        defer { releaseActiveWorker.signal() }

        let active = Task {
            await limiter.run(cancellationValue: -1) {
                probe.begin("active")
                defer { probe.finish("active") }
                activeStarted.fulfill()
                releaseActiveWorker.wait()
                return 1
            }
        }
        await fulfillment(of: [activeStarted], timeout: 2)

        let queued = Task {
            await limiter.run(cancellationValue: -2) {
                probe.begin("queued")
                defer { probe.finish("queued") }
                return 2
            }
        }
        let didQueue = await waitUntil {
            limiter.snapshot().pendingCount == 1
        }
        XCTAssertTrue(didQueue)

        queued.cancel()
        let queuedResult = await queued.value
        XCTAssertEqual(queuedResult, -2)
        XCTAssertEqual(
            limiter.snapshot(),
            ImageDescriptionWorkLimiterSnapshot(
                pendingCount: 0,
                hasActiveWork: true,
                isDrainScheduled: true
            )
        )

        releaseActiveWorker.signal()
        let activeResult = await active.value
        XCTAssertEqual(activeResult, 1)
        let drained = await waitUntil { !limiter.snapshot().isDrainScheduled }
        XCTAssertTrue(drained)
        XCTAssertEqual(probe.snapshot.startedIDs, ["active"])
        XCTAssertEqual(probe.snapshot.maximumActiveCount, 1)
    }

    func testWorkLimiterPreCancelledCallLeavesNoSubmissionMarker() async {
        let limiter = ImageDescriptionWorkLimiter(label: "test.image-description.pre-submit.\(UUID())")
        let gate = ImageDescriptionAsyncGate()
        let probe = ImageDescriptionWorkProbe()

        let operation = Task {
            await gate.wait()
            return await limiter.run(
                cancellationValue: -1,
                onCancel: { probe.recordCancellation() }
            ) {
                probe.begin("unexpected")
                probe.finish("unexpected")
                return 1
            }
        }
        operation.cancel()
        await gate.open()

        let result = await operation.value
        XCTAssertEqual(result, -1)
        XCTAssertEqual(probe.snapshot.cancellationCount, 1)
        XCTAssertTrue(probe.snapshot.startedIDs.isEmpty)
        XCTAssertEqual(
            limiter.snapshot(),
            ImageDescriptionWorkLimiterSnapshot(
                pendingCount: 0,
                hasActiveWork: false,
                isDrainScheduled: false
            )
        )
    }

    func testVisionInputDownsamplesLargeEncodedDimensionsBeforeDecode() throws {
        let sourceWidth = 16384
        let imageData = try makePNG(width: sourceWidth, height: 1)

        let input = try XCTUnwrap(ImageDescriptionGenerator.makeVisionInput(from: imageData))

        XCTAssertLessThan(imageData.count, 1024 * 1024)
        XCTAssertEqual(input.image.width, ImageDescriptionGenerator.maximumVisionPixelDimension)
        XCTAssertEqual(input.image.height, 1)
        XCTAssertLessThan(input.image.width, sourceWidth)
    }

    func testVisionInputBoundsHighlyCompressedLargePixelArea() throws {
        let sourceDimension = 4096
        let imageData = try makePNG(
            width: sourceDimension,
            height: sourceDimension
        )

        let input = try XCTUnwrap(ImageDescriptionGenerator.makeVisionInput(from: imageData))

        XCTAssertLessThan(imageData.count, 1024 * 1024)
        XCTAssertEqual(input.image.width, ImageDescriptionGenerator.maximumVisionPixelDimension)
        XCTAssertEqual(input.image.height, ImageDescriptionGenerator.maximumVisionPixelDimension)
        XCTAssertLessThan(
            input.image.width * input.image.height,
            sourceDimension * sourceDimension
        )
    }

    func testVisionInputHonorsSmallerExplicitPixelBound() throws {
        let imageData = try makePNG(width: 1024, height: 2)

        let input = try XCTUnwrap(ImageDescriptionGenerator.makeVisionInput(
            from: imageData,
            maximumPixelDimension: 128
        ))

        XCTAssertEqual(input.image.width, 128)
        XCTAssertEqual(input.image.height, 1)
    }

    func testUpdaterStoresGeneratedImageDescription() async throws {
        let store = try ClipKittyRust.ClipboardStore(dbPath: databasePath())
        let repository = ClipboardRepository(store: store)
        let saveResult = await repository.saveImage(
            imageData: Data([0x01, 0x02, 0x03]),
            thumbnail: nil,
            sourceApp: "Test",
            sourceAppBundleId: nil,
            isAnimated: false
        )
        let itemId = try saveResult.get()

        let updater = ImageDescriptionUpdater(repository: repository) { _ in
            "  red bicycle  "
        }
        let didUpdate = try await updater.update(itemId: itemId, imageData: Data([0xFF])).get()

        XCTAssertTrue(didUpdate)
        let item = await repository.fetchItem(id: itemId)
        guard case let .image(_, description, _) = item?.content else {
            XCTFail("Expected saved item to be an image")
            return
        }
        XCTAssertEqual(description, "Image: red bicycle")
    }

    func testUpdaterFetchesPersistedImageBytesForItemID() async throws {
        let store = try ClipKittyRust.ClipboardStore(dbPath: databasePath())
        let repository = ClipboardRepository(store: store)
        let expectedImageData = Data([0x10, 0x20, 0x30, 0x40])
        let saveResult = await repository.saveImage(
            imageData: expectedImageData,
            thumbnail: nil,
            sourceApp: "Test",
            sourceAppBundleId: nil,
            isAnimated: false
        )
        let itemId = try saveResult.get()
        let receivedData = ImageDescriptionDataProbe()
        let updater = ImageDescriptionUpdater(repository: repository) { data in
            await receivedData.record(data)
            return "persisted bytes"
        }

        let didUpdate = try await updater.update(itemId: itemId).get()

        XCTAssertTrue(didUpdate)
        let generatorData = await receivedData.value
        XCTAssertEqual(generatorData, expectedImageData)
        let item = await repository.fetchItem(id: itemId)
        guard case let .image(_, description, _) = item?.content else {
            return XCTFail("Expected saved item to be an image")
        }
        XCTAssertEqual(description, "Image: persisted bytes")
    }

    func testUpdaterSkipsEmptyGeneratedDescription() async throws {
        let store = try ClipKittyRust.ClipboardStore(dbPath: databasePath())
        let repository = ClipboardRepository(store: store)
        let saveResult = await repository.saveImage(
            imageData: Data([0x01, 0x02, 0x03]),
            thumbnail: nil,
            sourceApp: "Test",
            sourceAppBundleId: nil,
            isAnimated: false
        )
        let itemId = try saveResult.get()

        let updater = ImageDescriptionUpdater(repository: repository) { _ in
            "   "
        }
        let didUpdate = try await updater.update(itemId: itemId, imageData: Data([0xFF])).get()

        XCTAssertFalse(didUpdate)
        let item = await repository.fetchItem(id: itemId)
        guard case let .image(_, description, _) = item?.content else {
            XCTFail("Expected saved item to be an image")
            return
        }
        XCTAssertEqual(description, "Image")
    }

    func testCancelledFetchedUpdaterDoesNotWriteGeneratedDescription() async throws {
        let store = try ClipKittyRust.ClipboardStore(dbPath: databasePath())
        let repository = ClipboardRepository(store: store)
        let saveResult = await repository.saveImage(
            imageData: Data([0x01, 0x02, 0x03]),
            thumbnail: nil,
            sourceApp: "Test",
            sourceAppBundleId: nil,
            isAnimated: false
        )
        let itemId = try saveResult.get()

        let generatorStarted = expectation(description: "fetched image reached generator")
        let updater = ImageDescriptionUpdater(repository: repository) { _ in
            generatorStarted.fulfill()
            try? await Task.sleep(for: .seconds(5))
            return "must not be stored"
        }
        let update = Task {
            await updater.update(itemId: itemId)
        }
        await fulfillment(of: [generatorStarted], timeout: 2)
        update.cancel()

        let didUpdate = try await update.value.get()
        XCTAssertFalse(didUpdate)
        let item = await repository.fetchItem(id: itemId)
        guard case let .image(_, description, _) = item?.content else {
            return XCTFail("Expected saved item to be an image")
        }
        XCTAssertEqual(description, "Image")
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let bytesPerRow = width * 4
        let pixels = Data(repeating: 0x7F, count: bytesPerRow * height)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))

        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
        return condition()
    }
}

private actor ImageDescriptionDataProbe {
    private(set) var value: Data?

    func record(_ data: Data) {
        value = data
    }
}

private final class VisionDecodeThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValue: Bool?

    var isMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return recordedValue
    }

    func record(isMainThread: Bool) {
        lock.lock()
        recordedValue = isMainThread
        lock.unlock()
    }
}

private actor ImageDescriptionAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}

private final class ImageDescriptionValueProbe<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func record(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

private struct ImageDescriptionWorkProbeSnapshot {
    let activeCount: Int
    let maximumActiveCount: Int
    let startedIDs: [String]
    let finishedIDs: [String]
    let cancellationCount: Int
}

private final class ImageDescriptionWorkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var startedIDs: [String] = []
    private var finishedIDs: [String] = []
    private var cancellationCount = 0

    var snapshot: ImageDescriptionWorkProbeSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ImageDescriptionWorkProbeSnapshot(
            activeCount: activeCount,
            maximumActiveCount: maximumActiveCount,
            startedIDs: startedIDs,
            finishedIDs: finishedIDs,
            cancellationCount: cancellationCount
        )
    }

    func begin(_ id: String) {
        lock.lock()
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        startedIDs.append(id)
        lock.unlock()
    }

    func finish(_ id: String) {
        lock.lock()
        activeCount -= 1
        finishedIDs.append(id)
        lock.unlock()
    }

    func recordCancellation() {
        lock.lock()
        cancellationCount += 1
        lock.unlock()
    }
}
