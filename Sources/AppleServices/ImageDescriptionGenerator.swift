import Dispatch
import Foundation
import ImageIO
import Vision

struct ImageDescriptionWorkLimiterSnapshot: Equatable {
    let pendingCount: Int
    let hasActiveWork: Bool
    let isDrainScheduled: Bool
}

private protocol AnyImageDescriptionWorkJob: AnyObject, Sendable {
    var id: UUID { get }
    var canSubmit: Bool { get }
    func execute()
    func cancel()
}

/// Process-wide admission for the synchronous ImageIO/Vision work that cannot
/// always stop when its Swift caller is cancelled. The caller resumes promptly,
/// but the serial utility queue retains the real-work permit until that exact
/// function returns, preventing a new foreground session from overlapping it.
final class ImageDescriptionWorkLimiter: @unchecked Sendable {
    static let shared = ImageDescriptionWorkLimiter(
        label: "com.clipkitty.image-description.actual-work"
    )

    private final class Job<Value: Sendable>: AnyImageDescriptionWorkJob, @unchecked Sendable {
        private enum State {
            case pending(CheckedContinuation<Value, Never>?)
            case running(CheckedContinuation<Value, Never>)
            case cancelled
            case finished
        }

        let id = UUID()
        private let lock = NSLock()
        private let cancellationValue: Value
        private let onCancel: @Sendable () -> Void
        private let work: @Sendable () -> Value
        private var state: State = .pending(nil)

        init(
            cancellationValue: Value,
            onCancel: @escaping @Sendable () -> Void,
            work: @escaping @Sendable () -> Value
        ) {
            self.cancellationValue = cancellationValue
            self.onCancel = onCancel
            self.work = work
        }

        var canSubmit: Bool {
            lock.lock()
            defer { lock.unlock() }
            if case .pending = state { return true }
            return false
        }

        func install(_ continuation: CheckedContinuation<Value, Never>) -> Bool {
            let shouldSubmit: Bool
            let shouldResumeCancellation: Bool
            lock.lock()
            switch state {
            case .pending(nil):
                state = .pending(continuation)
                shouldSubmit = true
                shouldResumeCancellation = false
            case .cancelled:
                shouldSubmit = false
                shouldResumeCancellation = true
            case .pending(.some), .running, .finished:
                lock.unlock()
                preconditionFailure("work continuation installed more than once")
            }
            lock.unlock()

            if shouldResumeCancellation {
                continuation.resume(returning: cancellationValue)
            }
            return shouldSubmit
        }

        func execute() {
            let shouldRun: Bool
            lock.lock()
            switch state {
            case let .pending(.some(continuation)):
                state = .running(continuation)
                shouldRun = true
            case .cancelled:
                shouldRun = false
            case .pending(nil), .running, .finished:
                lock.unlock()
                preconditionFailure("work job entered an invalid execution state")
            }
            lock.unlock()
            guard shouldRun else { return }

            let value = autoreleasepool(invoking: work)
            let continuation: CheckedContinuation<Value, Never>?
            lock.lock()
            switch state {
            case let .running(waiter):
                state = .finished
                continuation = waiter
            case .cancelled:
                // Cancellation already resumed the caller. The actual work had
                // to finish to release the limiter, but its late value is stale.
                continuation = nil
            case .pending, .finished:
                lock.unlock()
                preconditionFailure("work job finished from an invalid state")
            }
            lock.unlock()
            continuation?.resume(returning: value)
        }

        func cancel() {
            let continuation: CheckedContinuation<Value, Never>?
            let shouldNotify: Bool
            lock.lock()
            switch state {
            case let .pending(waiter):
                state = .cancelled
                continuation = waiter
                shouldNotify = true
            case let .running(waiter):
                state = .cancelled
                continuation = waiter
                shouldNotify = true
            case .cancelled, .finished:
                continuation = nil
                shouldNotify = false
            }
            lock.unlock()

            if shouldNotify {
                continuation?.resume(returning: cancellationValue)
                onCancel()
            }
        }
    }

    private let lock = NSLock()
    private let workQueue: DispatchQueue
    private var pendingOrder: [UUID] = []
    private var pendingJobs: [UUID: any AnyImageDescriptionWorkJob] = [:]
    private var activeJobID: UUID?
    private var isDrainScheduled = false

    init(label: String) {
        workQueue = DispatchQueue(label: label, qos: .utility)
    }

    func run<Value: Sendable>(
        cancellationValue: Value,
        onCancel: @escaping @Sendable () -> Void = {},
        operation work: @escaping @Sendable () -> Value
    ) async -> Value {
        guard !Task.isCancelled else {
            onCancel()
            return cancellationValue
        }

        let job = Job(
            cancellationValue: cancellationValue,
            onCancel: onCancel,
            work: work
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard job.install(continuation) else { return }
                submit(job)
            }
        } onCancel: {
            cancel(job)
        }
    }

    func snapshot() -> ImageDescriptionWorkLimiterSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ImageDescriptionWorkLimiterSnapshot(
            pendingCount: pendingJobs.count,
            hasActiveWork: activeJobID != nil,
            isDrainScheduled: isDrainScheduled
        )
    }

    private func submit(_ job: any AnyImageDescriptionWorkJob) {
        let shouldScheduleDrain: Bool
        lock.lock()
        guard job.canSubmit else {
            lock.unlock()
            return
        }
        pendingOrder.append(job.id)
        pendingJobs[job.id] = job
        if isDrainScheduled {
            shouldScheduleDrain = false
        } else {
            isDrainScheduled = true
            shouldScheduleDrain = true
        }
        lock.unlock()

        if shouldScheduleDrain {
            workQueue.async { [weak self] in
                self?.drain()
            }
        }
    }

    private func cancel(_ job: any AnyImageDescriptionWorkJob) {
        job.cancel()
        lock.lock()
        pendingJobs[job.id] = nil
        pendingOrder.removeAll { $0 == job.id }
        lock.unlock()
    }

    private func drain() {
        while true {
            let job: (any AnyImageDescriptionWorkJob)?
            lock.lock()
            while let nextID = pendingOrder.first,
                  pendingJobs[nextID] == nil
            {
                pendingOrder.removeFirst()
            }
            if let nextID = pendingOrder.first,
               let nextJob = pendingJobs.removeValue(forKey: nextID)
            {
                pendingOrder.removeFirst()
                job = nextJob
                activeJobID = nextID
            } else {
                job = nil
                activeJobID = nil
                isDrainScheduled = false
            }
            lock.unlock()

            guard let job else { return }
            job.execute()

            lock.lock()
            if activeJobID == job.id {
                activeJobID = nil
            }
            lock.unlock()
        }
    }
}

public enum ImageDescriptionGenerator {
    /// Vision performs its own model-specific scaling, so decoding more than
    /// this only increases peak memory. A 2,048-square RGBA input is bounded to
    /// roughly 16 MiB instead of trusting potentially enormous source pixels.
    static let maximumVisionPixelDimension = 2048

    struct VisionInput: @unchecked Sendable {
        let image: CGImage
        let orientation: CGImagePropertyOrientation
    }

    private final class VisionCancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelled = false
        private var requests: [VNRequest] = []

        func install(_ requests: [VNRequest]) -> Bool {
            lock.lock()
            if isCancelled {
                lock.unlock()
                requests.forEach { $0.cancel() }
                return false
            }
            self.requests = requests
            lock.unlock()
            return true
        }

        func cancel() {
            let installedRequests: [VNRequest]
            lock.lock()
            isCancelled = true
            installedRequests = requests
            lock.unlock()
            installedRequests.forEach { $0.cancel() }
        }

        func clear() {
            lock.lock()
            requests = []
            lock.unlock()
        }

        var cancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isCancelled
        }
    }

    private enum VisionProcessingResult {
        case success(labels: [String], recognizedText: String?)
        case cancelled
        case failed
    }

    public struct Configuration: Sendable {
        /// Minimum confidence to accept a label (0.0 - 1.0).
        public var minConfidence: Float = 0.35

        /// Maximum number of classification labels to include.
        public var maxLabelCount: Int = 100

        /// Maximum number of characters for the recognized text before truncating.
        public var maxTextLength: Int = 50000

        public init(
            minConfidence: Float = 0.35,
            maxLabelCount: Int = 100,
            maxTextLength: Int = 50000
        ) {
            self.minConfidence = minConfidence
            self.maxLabelCount = maxLabelCount
            self.maxTextLength = maxTextLength
        }
    }

    public static func generateDescription(from imageData: Data, config: Configuration = .init()) async -> String? {
        guard !Task.isCancelled else { return nil }
        guard let input = await decodeVisionInput(using: {
            makeVisionInput(from: imageData)
        }) else { return nil }
        guard !Task.isCancelled else { return nil }

        return await processImage(
            input.image,
            orientation: input.orientation,
            config: config
        )
    }

    /// Runs a synchronous ImageIO decode away from the caller's executor. The
    /// closure is injectable so cancellation and executor behavior can be
    /// regression-tested without relying on device-specific decode timing.
    nonisolated static func decodeVisionInput(
        using decode: @escaping @Sendable () -> VisionInput?
    ) async -> VisionInput? {
        guard !Task.isCancelled else { return nil }
        let result: VisionInput? = await runCancellableWorker(
            cancellationValue: VisionInput?.none
        ) { () -> VisionInput? in
            return decode()
        }
        guard !Task.isCancelled else { return nil }
        return result
    }

    private nonisolated static func runCancellableWorker<Value: Sendable>(
        cancellationValue: Value,
        onCancel: @escaping @Sendable () -> Void = {},
        operation work: @escaping @Sendable () -> Value
    ) async -> Value {
        await ImageDescriptionWorkLimiter.shared.run(
            cancellationValue: cancellationValue,
            onCancel: onCancel,
            operation: work
        )
    }

    /// Builds a bounded first-frame decode for Vision. ImageIO's thumbnail path
    /// downsamples during decode, unlike `CGImageSourceCreateImageAtIndex`, which
    /// can allocate the source's full decompressed pixel dimensions even when
    /// the encoded payload itself is small.
    nonisolated static func makeVisionInput(
        from imageData: Data,
        maximumPixelDimension: Int = maximumVisionPixelDimension
    ) -> VisionInput? {
        guard maximumPixelDimension > 0, !Task.isCancelled else { return nil }
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithData(
            imageData as CFData,
            sourceOptions as CFDictionary
        ) else { return nil }
        guard !Task.isCancelled else { return nil }

        let orientation = CGImagePropertyOrientation(source: source)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ), !Task.isCancelled else { return nil }

        return VisionInput(image: image, orientation: orientation)
    }

    private static func processImage(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation,
        config: Configuration
    ) async -> String? {
        let cancellation = VisionCancellationState()
        let result = await runCancellableWorker(
            cancellationValue: VisionProcessingResult.cancelled,
            onCancel: {
                cancellation.cancel()
            }
        ) {
            if cancellation.cancelled { return .cancelled }
            let labelRequest = VNClassifyImageRequest()
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            let requests: [VNRequest] = [labelRequest, textRequest]
            guard cancellation.install(requests) else { return .cancelled }
            defer { cancellation.clear() }

            let handler = VNImageRequestHandler(
                cgImage: image,
                orientation: orientation,
                options: [:]
            )

            do {
                try handler.perform(requests)

                if cancellation.cancelled { return .cancelled }

                let labels = (labelRequest.results ?? [])
                    .filter { $0.confidence >= config.minConfidence }
                    .map { $0.identifier }
                    .prefix(config.maxLabelCount)

                let strings = (textRequest.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let text = strings.isEmpty ? nil : strings.joined(separator: " ")

                return .success(labels: Array(labels), recognizedText: text)
            } catch {
                return cancellation.cancelled ? .cancelled : .failed
            }
        }

        guard !Task.isCancelled else { return nil }
        switch result {
        case let .success(labels, recognizedText):
            return formatOutput(labels: labels, text: recognizedText, config: config)
        case .cancelled:
            return nil
        case .failed:
            return nil
        }
    }

    private static func formatOutput(labels: [String], text: String?, config: Configuration) -> String {
        var parts: [String] = []

        // Format Labels
        if !labels.isEmpty {
            let list = labels.formatted(.list(type: .and, width: .standard))
            parts.append(list)
        }

        // Format Text with Truncation
        if let text, !text.isEmpty {
            let truncated: String
            if text.count > config.maxTextLength {
                truncated = "\(text.prefix(config.maxTextLength))…"
            } else {
                truncated = text
            }
            parts.append(truncated)
        }

        return parts.joined(separator: ". ")
    }
}

// MARK: - Helpers

public extension CGImagePropertyOrientation {
    init(source: CGImageSource) {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        if let rawValue = properties?[kCGImagePropertyOrientation] as? UInt32,
           let orientation = CGImagePropertyOrientation(rawValue: rawValue)
        {
            self = orientation
        } else {
            self = .up
        }
    }
}
