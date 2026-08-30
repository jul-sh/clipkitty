import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DisplayImageDecodePolicy: Equatable {
    static let standard = DisplayImageDecodePolicy(
        maximumSourceByteCount: iOSTransferLimits.maximumImageByteCount,
        maximumSourcePixelDimension: 32768,
        maximumSourcePixelCount: 64 * 1024 * 1024,
        maximumDecodedPixelDimension: 4096,
        maximumDecodedPixelCount: 8 * 1024 * 1024,
        maximumDecodedByteCount: 32 * 1024 * 1024,
        maximumAnimatedFrameCount: 500
    )

    let maximumSourceByteCount: Int
    let maximumSourcePixelDimension: UInt64
    let maximumSourcePixelCount: UInt64
    let maximumDecodedPixelDimension: UInt64
    let maximumDecodedPixelCount: UInt64
    let maximumDecodedByteCount: Int
    let maximumAnimatedFrameCount: Int
}

enum DisplayImageDecodeKind: Equatable {
    case staticDownsampled
    case animatedLegacy
}

struct DisplayImageDecodeResult: @unchecked Sendable {
    let image: UIImage
    let decodedByteCost: Int
    let kind: DisplayImageDecodeKind
}

/// Parses source geometry without allocating the full raster, then asks
/// ImageIO for a bounded display-ready thumbnail. Animated sources deliberately
/// retain the pre-existing UIKit path: downsampling them to a `CGImage` would
/// silently flatten the animation. They are accepted only when every frame and
/// their aggregate estimated raster fit the display policy.
enum DisplayImageDecoder {
    private struct PixelSize {
        let width: UInt64
        let height: UInt64

        var pixelCount: UInt64? {
            guard height > 0, width <= UInt64.max / height else { return nil }
            return width * height
        }
    }

    nonisolated static func decode(
        _ data: Data,
        policy: DisplayImageDecodePolicy = .standard
    ) -> DisplayImageDecodeResult? {
        guard !data.isEmpty,
              data.count <= policy.maximumSourceByteCount,
              policy.maximumSourcePixelDimension > 0,
              policy.maximumSourcePixelCount > 0,
              policy.maximumDecodedPixelDimension > 0,
              policy.maximumDecodedPixelCount > 0,
              policy.maximumDecodedByteCount > 0,
              policy.maximumAnimatedFrameCount > 0
        else { return nil }

        return autoreleasepool {
            let sourceOptions: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
            ]
            guard let source = CGImageSourceCreateWithData(
                data as CFData,
                sourceOptions as CFDictionary
            ),
                CGImageSourceGetCount(source) > 0,
                let typeIdentifier = CGImageSourceGetType(source) as String?,
                UTType(typeIdentifier)?.conforms(to: .image) == true
            else { return nil }

            if CGImageSourceGetCount(source) > 1 {
                return decodeAnimated(
                    data,
                    source: source,
                    sourceOptions: sourceOptions,
                    policy: policy
                )
            }
            return decodeStatic(
                source,
                sourceOptions: sourceOptions,
                policy: policy
            )
        }
    }

    nonisolated static func thumbnailMaxPixelSize(
        sourceWidth: UInt64,
        sourceHeight: UInt64,
        policy: DisplayImageDecodePolicy
    ) -> Int? {
        guard sourceWidth > 0,
              sourceHeight > 0,
              let sourcePixelCount = pixelCount(width: sourceWidth, height: sourceHeight),
              sourceWidth <= policy.maximumSourcePixelDimension,
              sourceHeight <= policy.maximumSourcePixelDimension,
              sourcePixelCount <= policy.maximumSourcePixelCount,
              policy.maximumDecodedPixelDimension > 0,
              policy.maximumDecodedPixelCount > 0
        else { return nil }

        let longestSide = max(sourceWidth, sourceHeight)
        let dimensionScale = min(
            1,
            Double(policy.maximumDecodedPixelDimension) / Double(longestSide)
        )
        let pixelScale = min(
            1,
            (Double(policy.maximumDecodedPixelCount) / Double(sourcePixelCount)).squareRoot()
        )
        let target = floor(Double(longestSide) * min(dimensionScale, pixelScale))
        guard target.isFinite, target >= 1, target <= Double(Int.max) else { return nil }
        return Int(target)
    }

    nonisolated static func decodedByteCost(bytesPerRow: Int, height: Int) -> Int? {
        guard bytesPerRow > 0, height > 0 else { return nil }
        let (cost, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !overflow, cost > 0 else { return nil }
        return cost
    }

    nonisolated static func decodedByteCost(for image: UIImage) -> Int? {
        let frames = image.images ?? [image]
        var total = 0
        for frame in frames {
            guard let cgImage = frame.cgImage,
                  let frameCost = decodedByteCost(
                      bytesPerRow: cgImage.bytesPerRow,
                      height: cgImage.height
                  )
            else { return nil }
            let (newTotal, overflow) = total.addingReportingOverflow(frameCost)
            guard !overflow else { return nil }
            total = newTotal
        }
        return total > 0 ? total : nil
    }

    private nonisolated static func decodeStatic(
        _ source: CGImageSource,
        sourceOptions: [CFString: Any],
        policy: DisplayImageDecodePolicy
    ) -> DisplayImageDecodeResult? {
        guard let sourceSize = pixelSize(
            source: source,
            index: 0,
            sourceOptions: sourceOptions
        ),
            let targetSize = thumbnailMaxPixelSize(
                sourceWidth: sourceSize.width,
                sourceHeight: sourceSize.height,
                policy: policy
            )
        else { return nil }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetSize,
            kCGImageSourceShouldAllowFloat: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ),
            cgImage.width > 0,
            cgImage.height > 0,
            UInt64(cgImage.width) <= policy.maximumDecodedPixelDimension,
            UInt64(cgImage.height) <= policy.maximumDecodedPixelDimension,
            let actualPixelCount = pixelCount(
                width: UInt64(cgImage.width),
                height: UInt64(cgImage.height)
            ),
            actualPixelCount <= policy.maximumDecodedPixelCount,
            let decodedByteCost = decodedByteCost(
                bytesPerRow: cgImage.bytesPerRow,
                height: cgImage.height
            ),
            decodedByteCost <= policy.maximumDecodedByteCount
        else { return nil }

        return DisplayImageDecodeResult(
            image: UIImage(cgImage: cgImage),
            decodedByteCost: decodedByteCost,
            kind: .staticDownsampled
        )
    }

    private nonisolated static func decodeAnimated(
        _ data: Data,
        source: CGImageSource,
        sourceOptions: [CFString: Any],
        policy: DisplayImageDecodePolicy
    ) -> DisplayImageDecodeResult? {
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount <= policy.maximumAnimatedFrameCount else { return nil }
        let maximumEstimatedPixels = UInt64(policy.maximumDecodedByteCount / 4)
        var estimatedTotalPixels: UInt64 = 0
        for index in 0 ..< frameCount {
            guard let size = pixelSize(
                source: source,
                index: index,
                sourceOptions: sourceOptions
            ),
                let framePixelCount = size.pixelCount,
                size.width <= policy.maximumSourcePixelDimension,
                size.height <= policy.maximumSourcePixelDimension,
                framePixelCount <= policy.maximumSourcePixelCount,
                size.width <= policy.maximumDecodedPixelDimension,
                size.height <= policy.maximumDecodedPixelDimension,
                framePixelCount <= policy.maximumDecodedPixelCount,
                estimatedTotalPixels <= maximumEstimatedPixels,
                framePixelCount <= maximumEstimatedPixels - estimatedTotalPixels
            else { return nil }
            estimatedTotalPixels += framePixelCount
        }

        // Keep this byte-for-byte equivalent to the former display decode for
        // accepted animated sources. ImageIO thumbnail creation would return a
        // single frame and change visible behavior.
        guard let image = UIImage(data: data) else { return nil }
        let prepared = image.preparingForDisplay() ?? image
        guard let decodedByteCost = decodedByteCost(for: prepared),
              decodedByteCost <= policy.maximumDecodedByteCount
        else { return nil }
        return DisplayImageDecodeResult(
            image: prepared,
            decodedByteCost: decodedByteCost,
            kind: .animatedLegacy
        )
    }

    private nonisolated static func pixelSize(
        source: CGImageSource,
        index: Int,
        sourceOptions: [CFString: Any]
    ) -> PixelSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            index,
            sourceOptions as CFDictionary
        ) as? [CFString: Any],
            let width = pixelDimension(properties[kCGImagePropertyPixelWidth]),
            let height = pixelDimension(properties[kCGImagePropertyPixelHeight])
        else { return nil }
        return PixelSize(width: width, height: height)
    }

    private nonisolated static func pixelDimension(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        let dimension = number.doubleValue
        guard dimension.isFinite,
              dimension > 0,
              dimension.rounded(.towardZero) == dimension,
              dimension < Double(UInt64.max)
        else { return nil }
        return UInt64(dimension)
    }

    private nonisolated static func pixelCount(width: UInt64, height: UInt64) -> UInt64? {
        guard width > 0, height > 0, width <= UInt64.max / height else { return nil }
        return width * height
    }
}

/// A process-wide admission controller for real ImageIO/UIKit decode work.
/// Cancellation can remove queued work, but an already-running codec owns its
/// slot until it truly returns; releasing the slot at the caller timeout would
/// allow wedged late workers to accumulate without bound.
final class DisplayImageDecodeLimiter: @unchecked Sendable {
    struct Snapshot: Equatable {
        let activeCount: Int
        let pendingCount: Int
        let maximumObservedActiveCount: Int
        let cancellationMarkerCount: Int
    }

    private struct Entry {
        let id: UUID
        let work: @Sendable () -> Void
    }

    private let lock = NSLock()
    private let maximumConcurrentDecodes: Int
    private let queue: DispatchQueue
    private var activeIDs: Set<UUID> = []
    private var pending: [Entry] = []
    private var cancelledBeforeSubmission: Set<UUID> = []
    private var maximumObservedActiveCount = 0

    init(
        maximumConcurrentDecodes: Int,
        queue: DispatchQueue = DispatchQueue(
            label: "com.clipkitty.display-image-decode",
            qos: .utility,
            attributes: .concurrent
        )
    ) {
        precondition(maximumConcurrentDecodes > 0)
        self.maximumConcurrentDecodes = maximumConcurrentDecodes
        self.queue = queue
    }

    func submit(id: UUID, work: @escaping @Sendable () -> Void) {
        let entry = Entry(id: id, work: work)
        var shouldStart = false
        lock.lock()
        if cancelledBeforeSubmission.remove(id) != nil {
            lock.unlock()
            return
        }
        if activeIDs.count < maximumConcurrentDecodes {
            activeIDs.insert(id)
            maximumObservedActiveCount = max(maximumObservedActiveCount, activeIDs.count)
            shouldStart = true
        } else {
            pending.append(entry)
        }
        lock.unlock()

        if shouldStart {
            start(entry)
        }
    }

    func cancel(id: UUID) {
        lock.lock()
        if let pendingIndex = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: pendingIndex)
        } else if !activeIDs.contains(id) {
            // The cancellation handler can run between continuation install
            // and submission. Remember that race so submission becomes a no-op.
            cancelledBeforeSubmission.insert(id)
        }
        lock.unlock()
    }

    /// Clears the pre-submission tombstone when the operation was already
    /// cancelled and therefore intentionally never calls `submit`.
    func discardCancellationMarker(id: UUID) {
        lock.lock()
        cancelledBeforeSubmission.remove(id)
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            activeCount: activeIDs.count,
            pendingCount: pending.count,
            maximumObservedActiveCount: maximumObservedActiveCount,
            cancellationMarkerCount: cancelledBeforeSubmission.count
        )
    }

    private func start(_ entry: Entry) {
        queue.async { [self] in
            entry.work()
            complete(id: entry.id)
        }
    }

    private func complete(id: UUID) {
        var nextEntry: Entry?
        lock.lock()
        activeIDs.remove(id)
        if !pending.isEmpty {
            nextEntry = pending.removeFirst()
            if let nextEntry {
                activeIDs.insert(nextEntry.id)
                maximumObservedActiveCount = max(maximumObservedActiveCount, activeIDs.count)
            }
        }
        lock.unlock()

        if let nextEntry {
            start(nextEntry)
        }
    }
}

private final class DisplayImageDecodeOperation: @unchecked Sendable {
    private enum State {
        case idle
        case awaiting(CheckedContinuation<DisplayImageDecodeResult?, Never>)
        case finished(DisplayImageDecodeResult?)
        case cancelled
    }

    private let lock = NSLock()
    private var state: State = .idle

    @discardableResult
    func install(
        _ continuation: CheckedContinuation<DisplayImageDecodeResult?, Never>
    ) -> Bool {
        let immediateResult: DisplayImageDecodeResult??
        let shouldStart: Bool
        lock.lock()
        switch state {
        case .idle:
            state = .awaiting(continuation)
            immediateResult = nil
            shouldStart = true
        case let .finished(result):
            immediateResult = .some(result)
            shouldStart = false
        case .cancelled:
            immediateResult = .some(nil)
            shouldStart = false
        case .awaiting:
            lock.unlock()
            preconditionFailure("display decode continuation installed more than once")
        }
        lock.unlock()
        if let immediateResult {
            continuation.resume(returning: immediateResult)
        }
        return shouldStart
    }

    func finish(_ result: DisplayImageDecodeResult?) {
        let continuation: CheckedContinuation<DisplayImageDecodeResult?, Never>?
        lock.lock()
        switch state {
        case .idle:
            state = .finished(result)
            continuation = nil
        case let .awaiting(awaitingContinuation):
            state = .finished(result)
            continuation = awaitingContinuation
        case .finished, .cancelled:
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: result)
    }

    @discardableResult
    func cancel(beforeTransition: () -> Void) -> Bool {
        let continuation: CheckedContinuation<DisplayImageDecodeResult?, Never>?
        let didCancel: Bool
        lock.lock()
        switch state {
        case .idle:
            // Publish limiter cancellation before publishing `.cancelled`.
            // Otherwise continuation installation can observe cancellation,
            // discard no marker yet, and race with a later marker insertion.
            beforeTransition()
            state = .cancelled
            continuation = nil
            didCancel = true
        case let .awaiting(awaitingContinuation):
            beforeTransition()
            state = .cancelled
            continuation = awaitingContinuation
            didCancel = true
        case .finished, .cancelled:
            continuation = nil
            didCancel = false
        }
        lock.unlock()
        continuation?.resume(returning: nil)
        return didCancel
    }
}

enum DisplayImageDecodeCoordinator {
    static let processWideLimiter = DisplayImageDecodeLimiter(maximumConcurrentDecodes: 2)

    nonisolated static func decode(
        _ data: Data,
        policy: DisplayImageDecodePolicy = .standard,
        timeout: TimeInterval = 60,
        limiter: DisplayImageDecodeLimiter = processWideLimiter
    ) async -> DisplayImageDecodeResult? {
        await run(timeout: timeout, limiter: limiter) {
            DisplayImageDecoder.decode(data, policy: policy)
        }
    }

    /// Internal injection point keeps cancellation/late-result behavior
    /// directly testable without constructing a deliberately wedged codec.
    nonisolated static func run(
        timeout: TimeInterval,
        limiter: DisplayImageDecodeLimiter,
        work: @escaping @Sendable () -> DisplayImageDecodeResult?
    ) async -> DisplayImageDecodeResult? {
        let id = UUID()
        let operation = DisplayImageDecodeOperation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard operation.install(continuation) else {
                    limiter.discardCancellationMarker(id: id)
                    return
                }
                limiter.submit(id: id) {
                    operation.finish(work())
                }
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + max(0, timeout)
                ) {
                    operation.cancel {
                        limiter.cancel(id: id)
                    }
                }
            }
        } onCancel: {
            operation.cancel {
                limiter.cancel(id: id)
            }
        }
    }
}

private enum DecodedImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func key(namespace: String, itemId: String, data: Data) -> String {
        var hasher = Hasher()
        hasher.combine(namespace)
        hasher.combine(itemId)
        hasher.combine(data.count)
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for byte in bytes.prefix(16) {
                hasher.combine(byte)
            }
            if bytes.count > 16 {
                for byte in bytes.suffix(16) {
                    hasher.combine(byte)
                }
            }
        }
        return "\(namespace)-\(itemId)-\(data.count)-\(hasher.finalize())"
    }

    static func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    static func setImage(_ image: UIImage, forKey key: String, cost: Int) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

/// Counts image cards currently rendering their placeholder, aggregated by
/// the feed into its load-state accessibility identifier.
///
/// This closes a gap `ImageLoadActivity` cannot: the gauge only turns busy
/// once a card's `.task` runs, which is at least one frame after the card
/// first draws its placeholder. When a filter's rows land while the gauge is
/// already settled, that frame reads "settled" with placeholders on screen —
/// exactly the frame a marketing capture must not take (an App Store iPhone
/// screenshot shipped a placeholder whale card this way). A preference is
/// computed in the same render pass that draws the placeholder, so the feed
/// flips back to "loading" as soon as SwiftUI processes the pass.
struct PendingImagePlaceholderCount: PreferenceKey {
    static let defaultValue = 0

    static func reduce(value: inout Int, nextValue: () -> Int) {
        value += nextValue()
    }
}

struct DecodedImageView<Placeholder: View>: View {
    let namespace: String
    let itemId: String
    let data: Data
    let contentMode: ContentMode
    let placeholder: () -> Placeholder

    @State private var decodedImage: UIImage?

    private var cacheKey: String {
        DecodedImageCache.key(namespace: namespace, itemId: itemId, data: data)
    }

    init(
        namespace: String,
        itemId: String,
        data: Data,
        contentMode: ContentMode = .fit,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.namespace = namespace
        self.itemId = itemId
        self.data = data
        self.contentMode = contentMode
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image = decodedImage ?? DecodedImageCache.image(forKey: cacheKey) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(image.size, contentMode: contentMode)
            } else {
                placeholder()
                    .preference(key: PendingImagePlaceholderCount.self, value: 1)
            }
        }
        .task(id: cacheKey) {
            await decodeImage(cacheKey: cacheKey, data: data)
        }
    }

    @MainActor
    private func decodeImage(cacheKey: String, data: Data) async {
        if let cachedImage = DecodedImageCache.image(forKey: cacheKey) {
            decodedImage = cachedImage
            return
        }

        ImageLoadActivity.shared.begin()
        defer { ImageLoadActivity.shared.end() }

        // Deliberately keep the previous image (typically the small
        // thumbnail) on screen while the replacement decodes: blanking here
        // regresses the card to the gray placeholder for the whole decode,
        // and on a loaded CI runner the marketing capture shipped exactly
        // that — four placeholder cards in the Images-filter screenshot
        // (run 28795788433). A stale thumbnail is always a better frame
        // than an empty box, and the decode result overwrites it on arrival.
        let result = await DisplayImageDecodeCoordinator.decode(data)
        guard let result else { return }
        DecodedImageCache.setImage(
            result.image,
            forKey: cacheKey,
            cost: result.decodedByteCost
        )

        // A cancelled task here almost always means the data was re-keyed
        // mid-decode: CardImagePreview's thumbnail -> full-resolution upgrade
        // lands, cancelling the thumbnail decode. This result is still the
        // best frame available until the replacement decode finishes, so
        // publish it unless a newer image already got there first. Discarding
        // it is how iPhone captures shipped placeholder cards: the cancelled
        // 64px thumbnail decode left nothing on screen for the full-res
        // decode's entire queue-plus-decode latency.
        if Task.isCancelled {
            if decodedImage == nil { decodedImage = result.image }
        } else {
            decodedImage = result.image
        }
    }
}
