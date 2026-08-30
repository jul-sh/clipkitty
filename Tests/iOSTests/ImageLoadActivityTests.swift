@testable import ClipKittyiOS
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

/// Covers the settle debounce in `ImageLoadActivity`: the gauge must not
/// report settled while work is in flight, nor in the handoff gap between a
/// fetch ending and the decode it feeds beginning — that transient zero is
/// exactly when a screenshot capture polling the signal must not fire.
@MainActor
final class ImageLoadActivityTests: XCTestCase {
    private var activity: ImageLoadActivity!

    override func setUp() {
        super.setUp()
        activity = ImageLoadActivity()
    }

    func testBeginFlipsSettledFalseImmediately() {
        XCTAssertTrue(activity.isSettled)
        activity.begin()
        XCTAssertFalse(activity.isSettled)
    }

    func testEndDoesNotSettleSynchronously() {
        activity.begin()
        activity.end()
        XCTAssertFalse(activity.isSettled, "settling must wait out the debounce delay")
    }

    func testSettlesAfterDebounceDelay() async throws {
        activity.begin()
        activity.end()
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(activity.isSettled)
    }

    func testBeginDuringDebounceKeepsLoading() async throws {
        activity.begin()
        activity.end()
        // A new load starting inside the debounce window (the fetch -> decode
        // handoff) must cancel the pending settle.
        activity.begin()
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertFalse(activity.isSettled)
    }

    func testOverlappingLoadsSettleOnlyWhenAllFinish() async throws {
        activity.begin()
        activity.begin()
        activity.end()
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertFalse(activity.isSettled, "one load is still in flight")
        activity.end()
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(activity.isSettled)
    }

    func testDisplayDecodeRejectsHugeSourceDimensionBeforeRasterDecode() async throws {
        let data = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgABhqAAAAABAQAAAAB1BSt4AAAAI0lEQVR42u3BMQEAAADCoPVPbQwfoAAAAAAAAAAAAAAAAA4GMNUAAcmPjhAAAAAASUVORK5CYII="))
        let result = await Task.detached {
            DisplayImageDecoder.decode(data)
        }.value

        XCTAssertNil(result)
        XCTAssertNil(DisplayImageDecoder.thumbnailMaxPixelSize(
            sourceWidth: 100_000,
            sourceHeight: 1,
            policy: .standard
        ))
    }

    func testDisplayDecodeRejectsTruncatedImageData() async throws {
        let complete = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let truncated = Data(complete.prefix(20))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(truncated as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1, "header alone advertises a frame")

        let result = await Task.detached {
            DisplayImageDecoder.decode(truncated)
        }.value
        XCTAssertNil(result, "a frame that cannot actually downsample must be rejected")
    }

    func testDisplayDecodeDownsamplesAndChargesDecodedRasterBytes() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200))
        let data = try XCTUnwrap(renderer.image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }.pngData())
        let policy = DisplayImageDecodePolicy(
            maximumSourceByteCount: 1024 * 1024,
            maximumSourcePixelDimension: 1000,
            maximumSourcePixelCount: 1_000_000,
            maximumDecodedPixelDimension: 100,
            maximumDecodedPixelCount: 10000,
            maximumDecodedByteCount: 100_000,
            maximumAnimatedFrameCount: 10
        )

        let result = await Task.detached {
            DisplayImageDecoder.decode(data, policy: policy)
        }.value
        let decoded = try XCTUnwrap(result)
        let cgImage = try XCTUnwrap(decoded.image.cgImage)

        XCTAssertEqual(decoded.kind, .staticDownsampled)
        XCTAssertLessThanOrEqual(cgImage.width, 100)
        XCTAssertLessThanOrEqual(cgImage.height, 100)
        XCTAssertEqual(
            decoded.decodedByteCost,
            DisplayImageDecoder.decodedByteCost(
                bytesPerRow: cgImage.bytesPerRow,
                height: cgImage.height
            )
        )
        XCTAssertLessThanOrEqual(decoded.decodedByteCost, policy.maximumDecodedByteCount)
    }

    func testDecodedByteCostRejectsIntegerOverflow() {
        XCTAssertEqual(
            DisplayImageDecoder.decodedByteCost(bytesPerRow: 400, height: 200),
            80000
        )
        XCTAssertNil(DisplayImageDecoder.decodedByteCost(bytesPerRow: Int.max, height: 2))
        XCTAssertNil(DisplayImageDecoder.decodedByteCost(bytesPerRow: 0, height: 2))
    }

    func testAnimatedDisplayDecodeKeepsLegacyUIKitSemantics() async throws {
        let data = try Self.makeAnimatedGIF()
        let legacyImage = try XCTUnwrap(UIImage(data: data))
        let legacyPrepared = legacyImage.preparingForDisplay() ?? legacyImage
        let result = await Task.detached {
            DisplayImageDecoder.decode(data)
        }.value
        let decoded = try XCTUnwrap(result)

        XCTAssertEqual(decoded.kind, .animatedLegacy)
        XCTAssertEqual(decoded.image.images?.count, legacyPrepared.images?.count)
        XCTAssertEqual(decoded.image.duration, legacyPrepared.duration, accuracy: 0.001)
        XCTAssertEqual(decoded.image.size, legacyPrepared.size)
    }

    func testAnimatedDisplayDecodeRejectsAggregateFramesBeyondRasterBudget() async throws {
        let data = try Self.makeAnimatedGIF()
        let policy = DisplayImageDecodePolicy(
            maximumSourceByteCount: 1024 * 1024,
            maximumSourcePixelDimension: 100,
            maximumSourcePixelCount: 10000,
            maximumDecodedPixelDimension: 100,
            maximumDecodedPixelCount: 10000,
            maximumDecodedByteCount: 4,
            maximumAnimatedFrameCount: 2
        )

        let result = await Task.detached {
            DisplayImageDecoder.decode(data, policy: policy)
        }.value
        XCTAssertNil(result, "two one-pixel RGBA frames exceed a four-byte raster budget")
    }

    func testAnimatedDisplayDecodeRejectsFrameCountAbovePolicy() async throws {
        let data = try Self.makeAnimatedGIF()
        let policy = DisplayImageDecodePolicy(
            maximumSourceByteCount: 1024 * 1024,
            maximumSourcePixelDimension: 100,
            maximumSourcePixelCount: 10000,
            maximumDecodedPixelDimension: 100,
            maximumDecodedPixelCount: 10000,
            maximumDecodedByteCount: 1024,
            maximumAnimatedFrameCount: 1
        )

        let result = await Task.detached {
            DisplayImageDecoder.decode(data, policy: policy)
        }.value
        XCTAssertNil(result, "the two-frame source exceeds the one-frame policy boundary")
    }

    func testDecodeLimiterNeverRunsMoreThanConfiguredConcurrency() async {
        let limiter = DisplayImageDecodeLimiter(maximumConcurrentDecodes: 2)
        let probe = DecodeConcurrencyProbe()
        let release = DispatchSemaphore(value: 0)

        for _ in 0 ..< 3 {
            limiter.submit(id: UUID()) {
                probe.started()
                release.wait()
                probe.finished()
            }
        }

        await eventually { probe.snapshot().startedCount == 2 }
        XCTAssertEqual(limiter.snapshot().activeCount, 2)
        XCTAssertEqual(limiter.snapshot().pendingCount, 1)
        XCTAssertEqual(probe.snapshot().maximumActiveCount, 2)

        release.signal()
        await eventually { probe.snapshot().startedCount == 3 }
        XCTAssertEqual(probe.snapshot().maximumActiveCount, 2)

        release.signal()
        release.signal()
        await eventually { limiter.snapshot().activeCount == 0 }
        XCTAssertEqual(limiter.snapshot().maximumObservedActiveCount, 2)
    }

    func testCancellingActiveDecodeReturnsPromptlyAndIgnoresLateResult() async {
        let limiter = DisplayImageDecodeLimiter(maximumConcurrentDecodes: 1)
        let probe = DecodeConcurrencyProbe()
        let release = DispatchSemaphore(value: 0)
        let returned = expectation(description: "cancelled decode returned")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let lateResult = DisplayImageDecodeResult(
            image: image,
            decodedByteCost: 4,
            kind: .staticDownsampled
        )
        let task = Task {
            let result = await DisplayImageDecodeCoordinator.run(
                timeout: 60,
                limiter: limiter
            ) {
                probe.started()
                release.wait()
                probe.finished()
                return lateResult
            }
            returned.fulfill()
            return result
        }

        await eventually { probe.snapshot().startedCount == 1 }
        task.cancel()
        await fulfillment(of: [returned], timeout: 1)
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(limiter.snapshot().activeCount, 1, "actual worker still owns its slot")

        release.signal()
        await eventually { limiter.snapshot().activeCount == 0 }
    }

    func testCancellingQueuedDecodeRemovesItBeforeWorkStarts() async {
        let limiter = DisplayImageDecodeLimiter(maximumConcurrentDecodes: 1)
        let blockerRelease = DispatchSemaphore(value: 0)
        let blocker = DecodeConcurrencyProbe()
        limiter.submit(id: UUID()) {
            blocker.started()
            blockerRelease.wait()
            blocker.finished()
        }
        await eventually { blocker.snapshot().startedCount == 1 }

        let queuedWork = DecodeConcurrencyProbe()
        let returned = expectation(description: "queued decode cancellation returned")
        let task = Task {
            let result = await DisplayImageDecodeCoordinator.run(
                timeout: 60,
                limiter: limiter
            ) {
                queuedWork.started()
                return nil
            }
            returned.fulfill()
            return result
        }
        await eventually { limiter.snapshot().pendingCount == 1 }

        task.cancel()
        await fulfillment(of: [returned], timeout: 1)
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(limiter.snapshot().pendingCount, 0)

        blockerRelease.signal()
        await eventually { limiter.snapshot().activeCount == 0 }
        XCTAssertEqual(queuedWork.snapshot().startedCount, 0)
    }

    func testAlreadyCancelledDecodeDoesNotLeakLimiterCancellationMarker() async {
        let limiter = DisplayImageDecodeLimiter(maximumConcurrentDecodes: 1)
        let work = DecodeConcurrencyProbe()
        let task = Task {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                // Continue while the task remains cancelled, exercising the
                // cancellation-before-continuation-install race.
            }
            return await DisplayImageDecodeCoordinator.run(
                timeout: 60,
                limiter: limiter
            ) {
                work.started()
                return nil
            }
        }

        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(work.snapshot().startedCount, 0)
        XCTAssertEqual(limiter.snapshot().cancellationMarkerCount, 0)
    }

    func testDecodeTimeoutReturnsPromptlyAndIgnoresLateWorkerResult() async {
        let limiter = DisplayImageDecodeLimiter(maximumConcurrentDecodes: 1)
        let probe = DecodeConcurrencyProbe()
        let release = DispatchSemaphore(value: 0)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let lateResult = DisplayImageDecodeResult(
            image: image,
            decodedByteCost: 4,
            kind: .staticDownsampled
        )
        let task = Task {
            await DisplayImageDecodeCoordinator.run(
                timeout: 0.05,
                limiter: limiter
            ) {
                probe.started()
                release.wait()
                probe.finished()
                return lateResult
            }
        }

        await eventually { probe.snapshot().startedCount == 1 }
        let clock = ContinuousClock()
        let start = clock.now
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
        XCTAssertEqual(limiter.snapshot().activeCount, 1, "timed-out worker retains its permit")

        release.signal()
        await eventually { limiter.snapshot().activeCount == 0 }
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
        XCTAssertTrue(condition())
    }
}

private final class DecodeConcurrencyProbe: @unchecked Sendable {
    struct Snapshot {
        let activeCount: Int
        let startedCount: Int
        let maximumActiveCount: Int
    }

    private let lock = NSLock()
    private var activeCount = 0
    private var startedCount = 0
    private var maximumActiveCount = 0

    func started() {
        lock.lock()
        activeCount += 1
        startedCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        lock.unlock()
    }

    func finished() {
        lock.lock()
        activeCount -= 1
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            activeCount: activeCount,
            startedCount: startedCount,
            maximumActiveCount: maximumActiveCount
        )
    }
}
