import ClipKittyCore
import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ShareItemPayload {
    case text(String)
    case url(URL)
    case image(data: Data, thumbnail: Data?, isAnimated: Bool)

    var byteCount: Int {
        switch self {
        case let .text(text):
            text.utf8.count
        case let .url(url):
            url.absoluteString.utf8.count
        case let .image(data, thumbnail, _):
            data.count + (thumbnail?.count ?? 0)
        }
    }
}

private struct ShareBatchBudget {
    private(set) var acceptedByteCount = 0

    var remainingByteCount: Int {
        PendingShareQueue.Limits.maximumAggregateByteCount - acceptedByteCount
    }

    mutating func admit(_ payload: ShareItemPayload) -> Bool {
        let byteCount = payload.byteCount
        guard byteCount >= 0,
              byteCount <= remainingByteCount
        else { return false }
        acceptedByteCount += byteCount
        return true
    }
}

private struct ShareImageAnalysis {
    let thumbnail: Data
    let isAnimated: Bool
}

/// Validates compressed image metadata and proves that the first frame can be
/// decoded without ever constructing a full-resolution `UIImage`. ImageIO
/// downsamples directly into the small thumbnail used by the main app.
private enum ShareImageInspector {
    private static let maximumPixelDimension: UInt64 = 32768
    private static let maximumPixelCount: UInt64 = 64 * 1024 * 1024

    static func analyzeCancellable(_ data: Data) async -> ShareImageAnalysis? {
        let operation = ShareAsyncOperation<ShareImageAnalysis>()
        let worker = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else {
                operation.finish(nil)
                return
            }
            operation.finish(analyze(data))
        }
        return await withTaskCancellationHandler {
            await operation.value()
        } onCancel: {
            worker.cancel()
            operation.cancel()
        }
    }

    private static func analyze(_ data: Data) -> ShareImageAnalysis? {
        guard !Task.isCancelled,
              !data.isEmpty,
              data.count <= PendingShareQueue.Limits.maximumImageByteCount
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
                !Task.isCancelled,
                width <= maximumPixelDimension,
                height <= maximumPixelDimension,
                width <= maximumPixelCount / height
            else { return nil }

            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 200,
                kCGImageSourceShouldAllowFloat: false,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                thumbnailOptions as CFDictionary
            ),
                thumbnail.width > 0,
                thumbnail.height > 0,
                !Task.isCancelled,
                let thumbnailData = encodeJPEG(thumbnail),
                !Task.isCancelled
            else { return nil }

            return ShareImageAnalysis(
                thumbnail: thumbnailData,
                isAnimated: CGImageSourceGetCount(source) > 1
            )
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

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination),
              output.length <= PendingShareQueue.Limits.maximumThumbnailByteCount
        else { return nil }
        return output as Data
    }
}

private enum ShareFileLoadResult {
    case content(Data)
    case unavailable
    case oversized
    case failed
}

private enum ShareBoundedFileReader {
    static func read(from url: URL, maximumByteCount: Int) -> ShareFileLoadResult {
        guard maximumByteCount >= 0 else { return .oversized }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let fileSize = try handle.seekToEnd()
            guard fileSize <= UInt64(maximumByteCount) else { return .oversized }
            try handle.seek(toOffset: 0)
            let readLimit = maximumByteCount == Int.max
                ? Int.max
                : maximumByteCount + 1
            let data = try handle.read(upToCount: readLimit) ?? Data()
            guard data.count <= maximumByteCount else { return .oversized }
            return .content(data)
        } catch {
            return .failed
        }
    }
}

/// Reads one provider representation at a time with structured cancellation.
/// A canceled task resumes immediately, cancels the provider's `Progress`, and
/// ignores any callback that arrives after the share sheet has gone away.
enum ShareItemProviderLoader {
    private static let unavailableCoercionErrorCode = -1200

    static func load(
        from provider: NSItemProvider,
        maximumAggregateByteCount: Int
    ) async -> ShareItemPayload? {
        guard !Task.isCancelled,
              maximumAggregateByteCount > 0
        else { return nil }

        let identifiers = provider.registeredTypeIdentifiers
        let imageIdentifiers = identifiers.filter {
            UTType($0)?.conforms(to: .image) == true && $0 != UTType.image.identifier
        } + identifiers.filter { $0 == UTType.image.identifier }
        if !imageIdentifiers.isEmpty {
            return await loadImage(
                from: provider,
                typeIdentifiers: imageIdentifiers,
                maximumByteCount: min(
                    PendingShareQueue.Limits.maximumImageByteCount,
                    maximumAggregateByteCount
                )
            )
        }

        if identifiers.contains(where: { UTType($0)?.conforms(to: .url) == true }) {
            return await loadURL(
                from: provider,
                maximumByteCount: min(
                    PendingShareQueue.Limits.maximumTextByteCount,
                    maximumAggregateByteCount
                )
            )
        }

        if identifiers.contains(where: { UTType($0)?.conforms(to: .text) == true }) {
            return await loadText(
                from: provider,
                maximumByteCount: min(
                    PendingShareQueue.Limits.maximumTextByteCount,
                    maximumAggregateByteCount
                )
            )
        }

        return nil
    }

    private static func loadImage(
        from provider: NSItemProvider,
        typeIdentifiers: [String],
        maximumByteCount: Int
    ) async -> ShareItemPayload? {
        for typeIdentifier in typeIdentifiers {
            guard !Task.isCancelled else { return nil }

            let data: Data?
            switch await loadFile(
                from: provider,
                typeIdentifier: typeIdentifier,
                maximumByteCount: maximumByteCount
            ) {
            case let .content(fileData):
                data = fileData
            case .unavailable:
                data = await loadData(
                    from: provider,
                    typeIdentifier: typeIdentifier,
                    maximumByteCount: maximumByteCount
                )
            case .oversized, .failed:
                // Do not ask the same provider to allocate the advertised file
                // again through its data API after a definite file outcome.
                data = nil
            }

            guard !Task.isCancelled else { return nil }
            guard let data,
                  let analysis = await ShareImageInspector.analyzeCancellable(data),
                  !Task.isCancelled
            else { continue }
            return .image(
                data: data,
                thumbnail: analysis.thumbnail,
                isAnimated: analysis.isAnimated
            )
        }
        return nil
    }

    private static func loadURL(
        from provider: NSItemProvider,
        maximumByteCount: Int
    ) async -> ShareItemPayload? {
        guard provider.canLoadObject(ofClass: NSURL.self),
              let url = await loadURLObject(from: provider),
              !Task.isCancelled,
              !url.isFileURL,
              url.absoluteString.utf8.count <= maximumByteCount
        else { return nil }
        return .url(url)
    }

    private static func loadText(
        from provider: NSItemProvider,
        maximumByteCount: Int
    ) async -> ShareItemPayload? {
        let typeIdentifier = UTType.plainText.identifier
        let fileResult = await loadFile(
            from: provider,
            typeIdentifier: typeIdentifier,
            maximumByteCount: maximumByteCount
        )
        let fileData: Data?
        let allowsObjectFallback: Bool
        switch fileResult {
        case let .content(data):
            fileData = data
            allowsObjectFallback = false
        case .unavailable:
            fileData = await loadData(
                from: provider,
                typeIdentifier: typeIdentifier,
                maximumByteCount: maximumByteCount
            )
            allowsObjectFallback = true
        case .oversized, .failed:
            // A definite file result must never be bypassed by asking the
            // provider to allocate the same value as an NSString.
            return nil
        }
        if let fileData,
           let text = String(data: fileData, encoding: .utf8),
           !text.isEmpty,
           !Task.isCancelled
        {
            return .text(text)
        }

        // Some NSString providers expose only the object representation. Keep
        // this compatibility fallback bounded immediately after materializing.
        guard allowsObjectFallback,
              provider.canLoadObject(ofClass: NSString.self),
              let text = await loadStringObject(from: provider),
              !Task.isCancelled
        else { return nil }
        guard !text.isEmpty,
              text.utf8.count <= maximumByteCount
        else { return nil }
        return .text(text)
    }

    private static func loadFile(
        from provider: NSItemProvider,
        typeIdentifier: String,
        maximumByteCount: Int
    ) async -> ShareFileLoadResult {
        guard provider.hasRepresentationConforming(
            toTypeIdentifier: typeIdentifier,
            fileOptions: []
        ) else { return .unavailable }

        return await load { completion in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else {
                    let cocoaError = error as NSError?
                    let isUnavailable = cocoaError?.domain == NSItemProvider.errorDomain
                        && cocoaError?.code == unavailableCoercionErrorCode
                    completion(isUnavailable ? .unavailable : .failed)
                    return
                }
                completion(ShareBoundedFileReader.read(
                    from: url,
                    maximumByteCount: maximumByteCount
                ))
            }
        } ?? .failed
    }

    private static func loadData(
        from provider: NSItemProvider,
        typeIdentifier: String,
        maximumByteCount: Int
    ) async -> Data? {
        guard let data: Data = await load(start: { completion in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                completion(data)
            }
        }),
            data.count <= maximumByteCount
        else { return nil }
        return data
    }

    private static func loadURLObject(from provider: NSItemProvider) async -> URL? {
        await load { completion in
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                completion((object as? NSURL).map { $0 as URL })
            }
        }
    }

    private static func loadStringObject(from provider: NSItemProvider) async -> String? {
        await load { completion in
            provider.loadObject(ofClass: NSString.self) { object, _ in
                completion((object as? NSString).map { $0 as String })
            }
        }
    }

    private static func load<Value>(
        start: @escaping (@escaping (Value?) -> Void) -> Progress?
    ) async -> Value? {
        let operation = ShareAsyncOperation<Value>()
        return await withTaskCancellationHandler {
            await operation.value(start: start)
        } onCancel: {
            operation.cancel()
        }
    }
}

/// File encoding and App Group writes may be tens of megabytes. Keep them off
/// the main actor while retaining and joining the exact child task. If
/// cancellation races a write that has already started, its committed result
/// is still returned; the view suppresses all later UI work.
private enum ShareQueueWriter {
    static func enqueue(_ payload: ShareItemPayload) async -> Bool {
        guard !Task.isCancelled else { return false }
        let writeTask = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return false }
            do {
                switch payload {
                case let .text(text):
                    try PendingShareQueue.enqueueText(text)
                case let .url(url):
                    try PendingShareQueue.enqueueURL(url.absoluteString)
                case let .image(data, thumbnail, isAnimated):
                    try PendingShareQueue.enqueueImage(
                        imageData: data,
                        thumbnail: thumbnail,
                        isAnimated: isAnimated
                    )
                }
                return true
            } catch {
                return false
            }
        }
        return await withTaskCancellationHandler {
            await writeTask.value
        } onCancel: {
            writeTask.cancel()
        }
    }
}

private final class ShareAsyncOperation<Value>: @unchecked Sendable {
    private enum State {
        case idle
        case awaiting(CheckedContinuation<Value?, Never>)
        case finished(Value?)
        case cancelled
    }

    private let lock = NSLock()
    private var state = State.idle
    private var progress: Progress?

    func value(
        start: ((@escaping (Value?) -> Void) -> Progress?)? = nil
    ) async -> Value? {
        await withCheckedContinuation { continuation in
            guard install(continuation) else { return }
            guard let start else { return }
            install(start { value in
                self.finish(value)
            })
        }
    }

    func finish(_ value: Value?) {
        let continuation: CheckedContinuation<Value?, Never>?
        lock.lock()
        switch state {
        case .idle:
            state = .finished(value)
            continuation = nil
        case let .awaiting(waiter):
            state = .finished(value)
            continuation = waiter
        case .finished, .cancelled:
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func cancel() {
        let continuation: CheckedContinuation<Value?, Never>?
        let progress: Progress?
        lock.lock()
        switch state {
        case .idle:
            state = .cancelled
            continuation = nil
        case let .awaiting(waiter):
            state = .cancelled
            continuation = waiter
        case .finished, .cancelled:
            continuation = nil
        }
        progress = self.progress
        lock.unlock()
        progress?.cancel()
        continuation?.resume(returning: nil)
    }

    private func install(_ continuation: CheckedContinuation<Value?, Never>) -> Bool {
        let immediateValue: Value??
        let shouldStart: Bool
        lock.lock()
        switch state {
        case .idle:
            state = .awaiting(continuation)
            immediateValue = nil
            shouldStart = true
        case let .finished(value):
            immediateValue = .some(value)
            shouldStart = false
        case .cancelled:
            immediateValue = .some(nil)
            shouldStart = false
        case .awaiting:
            lock.unlock()
            preconditionFailure("share provider continuation installed twice")
        }
        lock.unlock()
        if let immediateValue {
            continuation.resume(returning: immediateValue)
        }
        return shouldStart
    }

    private func install(_ progress: Progress?) {
        let shouldCancel: Bool
        lock.lock()
        self.progress = progress
        if case .cancelled = state {
            shouldCancel = true
        } else {
            shouldCancel = false
        }
        lock.unlock()
        if shouldCancel {
            progress?.cancel()
        }
    }
}

/// Minimal share-sheet UI: saves shared items, shows brief confirmation, then dismisses.
@MainActor
struct ShareView: View {
    let items: [NSItemProvider]
    let onComplete: () -> Void

    @State private var state: ShareState = .saving

    enum ShareState: Equatable {
        case saving
        case succeeded(Int)
        case failed(String)
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                switch state {
                case .saving:
                    ProgressView()
                        .controlSize(.large)
                    Text(String(localized: "Saving to ClipKitty…"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                case let .succeeded(count):
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                    Text(count == 1
                        ? String(localized: "Saved to ClipKitty")
                        : String(localized: "Saved \(count) items to ClipKitty"))
                        .font(.subheadline.weight(.medium))

                case let .failed(message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            .animation(.snappy, value: state)
        }
        .task {
            await saveItems()
        }
    }

    private func saveItems() async {
        var savedCount = 0
        var budget = ShareBatchBudget()

        for provider in items.prefix(PendingShareQueue.Limits.maximumItemCount) {
            guard !Task.isCancelled,
                  budget.remainingByteCount > 0,
                  let payload = await ShareItemProviderLoader.load(
                      from: provider,
                      maximumAggregateByteCount: budget.remainingByteCount
                  ),
                  !Task.isCancelled,
                  budget.admit(payload)
            else { continue }

            let didEnqueue = await ShareQueueWriter.enqueue(payload)
            if didEnqueue {
                savedCount += 1
            }
        }

        guard !Task.isCancelled else { return }
        if savedCount > 0 {
            state = .succeeded(savedCount)
            dismissAfterDelay(seconds: 0.6)
        } else {
            state = .failed(String(localized: "Nothing to save"))
            dismissAfterDelay(seconds: 1.5)
        }
    }

    private func dismissAfterDelay(seconds: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            onComplete()
        }
    }
}
