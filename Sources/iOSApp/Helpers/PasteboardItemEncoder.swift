import ClipKittyCore
import ClipKittyRust
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shared safety ceilings for multi-item pasteboard and drag transfers.
///
/// Selection and deletion remain unlimited. These limits apply only when full
/// clip payloads leave the app, where eagerly materializing thousands of large
/// images could otherwise exhaust memory or stall the main actor.
enum iOSTransferLimits {
    static let maximumItemCount = PendingShareQueue.Limits.maximumItemCount
    static let maximumTextByteCount = PendingShareQueue.Limits.maximumTextByteCount
    static let maximumImageByteCount = PendingShareQueue.Limits.maximumImageByteCount
    static let maximumAggregateByteCount = PendingShareQueue.Limits.maximumAggregateByteCount

    enum Rejection: Error, Equatable {
        case tooManyItems
        case itemTooLarge
        case aggregateTooLarge
        case unsupported
    }

    static func validateItemCount(_ count: Int) -> Rejection? {
        count > 0 && count <= maximumItemCount ? nil : .tooManyItems
    }

    static func payloadByteCount(_ content: ClipboardContent) -> Result<Int, Rejection> {
        switch content {
        case let .text(value), let .color(value):
            let count = value.utf8.count
            return count <= maximumTextByteCount ? .success(count) : .failure(.itemTooLarge)
        case let .link(value, _):
            let count = value.utf8.count
            return count <= maximumTextByteCount ? .success(count) : .failure(.itemTooLarge)
        case let .image(data, _, _):
            return data.count <= maximumImageByteCount
                ? .success(data.count)
                : .failure(.itemTooLarge)
        case let .file(displayName, files):
            let filename = files.first?.filename ?? displayName
            guard !filename.isEmpty else { return .failure(.unsupported) }
            let count = filename.utf8.count
            return count <= maximumTextByteCount ? .success(count) : .failure(.itemTooLarge)
        }
    }

    static func adding(
        _ byteCount: Int,
        to aggregateByteCount: Int
    ) -> Result<Int, Rejection> {
        guard byteCount >= 0,
              aggregateByteCount >= 0,
              aggregateByteCount <= maximumAggregateByteCount,
              byteCount <= maximumAggregateByteCount - aggregateByteCount
        else {
            return .failure(.aggregateTooLarge)
        }
        return .success(aggregateByteCount + byteCount)
    }
}

/// A native image accepted for an outbound pasteboard or drag transfer.
/// Validation preserves the original bytes; the thumbnail is thrown away and
/// exists only to prove that ImageIO can decode a bounded frame.
enum TransferImageValidator {
    struct Policy: Equatable {
        static let outbound = Policy(
            maximumPixelDimension: 32768,
            maximumPixelCount: 64 * 1024 * 1024,
            validationThumbnailDimension: 64
        )

        let maximumPixelDimension: UInt64
        let maximumPixelCount: UInt64
        let validationThumbnailDimension: Int
    }

    /// This work may parse and downsample compressed image data. Callers that
    /// can originate on the main actor must use `PasteboardItemEncoder.prepareAll`,
    /// which dispatches image validation to a detached worker.
    static func nativeTypeIdentifier(
        for data: Data,
        policy: Policy = .outbound
    ) -> String? {
        guard !data.isEmpty,
              data.count <= iOSTransferLimits.maximumImageByteCount,
              policy.maximumPixelDimension > 0,
              policy.maximumPixelCount > 0,
              policy.validationThumbnailDimension > 0
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
                UTType(typeIdentifier)?.conforms(to: .image) == true,
                let properties = CGImageSourceCopyPropertiesAtIndex(
                    source,
                    0,
                    sourceOptions as CFDictionary
                ) as? [CFString: Any],
                let width = pixelDimension(properties[kCGImagePropertyPixelWidth]),
                let height = pixelDimension(properties[kCGImagePropertyPixelHeight]),
                width <= policy.maximumPixelDimension,
                height <= policy.maximumPixelDimension,
                width <= policy.maximumPixelCount / height
            else {
                return nil
            }

            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: policy.validationThumbnailDimension,
                kCGImageSourceShouldAllowFloat: false,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let decodedFrame = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                thumbnailOptions as CFDictionary
            ),
                decodedFrame.width > 0,
                decodedFrame.height > 0
            else {
                return nil
            }
            return typeIdentifier
        }
    }

    private static func pixelDimension(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        let dimension = number.doubleValue
        guard dimension.isFinite,
              dimension > 0,
              dimension.rounded(.towardZero) == dimension,
              dimension < Double(UInt64.max)
        else { return nil }
        return UInt64(dimension)
    }
}

/// Prepares untrusted PhotosPicker bytes for persistence without decoding them
/// on the main actor. The shared inspector performs the bounded
/// `TransferImageValidator` decode probe before generating the thumbnail and
/// classifies animation from the source frame count.
enum PhotoImportImagePreparer {
    typealias Inspector = @Sendable (Data) async -> PasteboardImageAnalysis?

    static func prepare(
        _ data: Data,
        inspector: Inspector = {
            await PasteboardImageInspector.analyzeCancellable($0)
        }
    ) async -> PasteboardImageAnalysis? {
        guard !Task.isCancelled,
              !data.isEmpty,
              data.count <= iOSTransferLimits.maximumImageByteCount,
              let analysis = await inspector(data),
              !Task.isCancelled
        else { return nil }
        return analysis
    }
}

/// Sendable output from the potentially expensive preparation phase. Turning
/// this into UIKit's `[String: Any]` dictionaries is cheap and happens only
/// after the caller returns to the main actor.
struct PreparedPasteboardBatch {
    fileprivate let items: [PreparedPasteboardItem]

    var pasteboardItems: [[String: Any]] {
        items.map(\.pasteboardItem)
    }

    /// Exposes the validated native bytes for consumers that need one image
    /// without first erasing its type through a UIKit `[String: Any]` value.
    /// The share sheet uses this to preserve GIF/APNG/WebP animation while
    /// keeping ImageIO validation on the detached preparation worker above.
    var singleNativeImage: PreparedNativeImage? {
        guard items.count == 1,
              case let .image(data, typeIdentifier) = items[0]
        else { return nil }
        return PreparedNativeImage(data: data, typeIdentifier: typeIdentifier)
    }
}

struct PreparedNativeImage: Equatable {
    let data: Data
    let typeIdentifier: String
}

private enum PreparedPasteboardItem {
    case plainText(String)
    case link(url: URL, text: String)
    case image(data: Data, typeIdentifier: String)

    var pasteboardItem: [String: Any] {
        switch self {
        case let .plainText(value):
            return [UTType.utf8PlainText.identifier: value]
        case let .link(url, text):
            return [
                UTType.url.identifier: url as NSURL,
                UTType.utf8PlainText.identifier: text,
            ]
        case let .image(data, typeIdentifier):
            return [typeIdentifier: data]
        }
    }
}

/// Converts stored clips into a fully validated, native pasteboard batch.
///
/// Every item is prepared before `UIPasteboard.items` is mutated, so a missing
/// or malformed selected clip can never replace the clipboard with a partial
/// batch. Image parsing and the bounded decode probe always run off-main.
enum PasteboardItemEncoder {
    static func prepareAll(_ contents: [ClipboardContent]) async -> PreparedPasteboardBatch? {
        if !contents.contains(where: \.isImageForPasteboardPreparation) {
            return prepareAllSynchronously(contents)
        }

        let operation = DetachedPasteboardPreparation()
        let worker = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else {
                operation.finish(nil)
                return
            }
            operation.finish(prepareAllSynchronously(contents))
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operation.install(continuation)
            }
        } onCancel: {
            worker.cancel()
            operation.cancel()
        }
    }

    private static func prepare(_ content: ClipboardContent) -> PreparedPasteboardItem? {
        switch content {
        case let .text(value), let .color(value):
            return .plainText(value)

        case let .link(value, _):
            guard let url = URL(string: value), url.scheme != nil else {
                return .plainText(value)
            }
            return .link(url: url, text: value)

        case let .image(data, _, _):
            guard let typeIdentifier = TransferImageValidator.nativeTypeIdentifier(for: data)
            else { return nil }
            return .image(data: data, typeIdentifier: typeIdentifier)

        case let .file(displayName, files):
            let filename = files.first?.filename ?? displayName
            guard !filename.isEmpty else { return nil }
            return .plainText(filename)
        }
    }

    private static func prepareAllSynchronously(
        _ contents: [ClipboardContent]
    ) -> PreparedPasteboardBatch? {
        guard !Task.isCancelled,
              iOSTransferLimits.validateItemCount(contents.count) == nil
        else { return nil }
        var aggregateByteCount = 0
        for content in contents {
            guard !Task.isCancelled,
                  case let .success(byteCount) = iOSTransferLimits.payloadByteCount(content),
                  case let .success(nextAggregate) = iOSTransferLimits.adding(
                      byteCount,
                      to: aggregateByteCount
                  )
            else {
                return nil
            }
            aggregateByteCount = nextAggregate
        }

        var preparedItems: [PreparedPasteboardItem] = []
        preparedItems.reserveCapacity(contents.count)
        for content in contents {
            guard !Task.isCancelled,
                  let item = prepare(content)
            else { return nil }
            preparedItems.append(item)
        }
        return PreparedPasteboardBatch(items: preparedItems)
    }
}

private extension ClipboardContent {
    var isImageForPasteboardPreparation: Bool {
        if case .image = self { return true }
        return false
    }
}

/// Cancellation stops the UI task awaiting non-cooperative ImageIO work. The
/// detached worker is stateless and may safely finish later; its result is
/// ignored after cancellation.
private final class DetachedPasteboardPreparation: @unchecked Sendable {
    private enum State {
        case idle
        case awaiting(CheckedContinuation<PreparedPasteboardBatch?, Never>)
        case finished(PreparedPasteboardBatch?)
        case cancelled
    }

    private let lock = NSLock()
    private var state = State.idle

    func install(_ continuation: CheckedContinuation<PreparedPasteboardBatch?, Never>) {
        lock.lock()
        switch state {
        case .idle:
            state = .awaiting(continuation)
            lock.unlock()
        case let .finished(result):
            lock.unlock()
            continuation.resume(returning: result)
        case .cancelled:
            lock.unlock()
            continuation.resume(returning: nil)
        case .awaiting:
            lock.unlock()
            preconditionFailure("Pasteboard preparation installed twice")
        }
    }

    func finish(_ result: PreparedPasteboardBatch?) {
        lock.lock()
        switch state {
        case .idle:
            state = .finished(result)
            lock.unlock()
        case let .awaiting(continuation):
            state = .finished(result)
            lock.unlock()
            continuation.resume(returning: result)
        case .cancelled, .finished:
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        switch state {
        case .idle:
            state = .cancelled
            lock.unlock()
        case let .awaiting(continuation):
            state = .cancelled
            lock.unlock()
            continuation.resume(returning: nil)
        case .cancelled, .finished:
            lock.unlock()
        }
    }
}
