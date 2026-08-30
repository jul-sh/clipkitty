import ClipKittyRust
import Foundation

#if ENABLE_LINK_PREVIEWS
    import CoreGraphics
    import Darwin
    import ImageIO
    @preconcurrency import LinkPresentation
    import UniformTypeIdentifiers

    struct LinkMetadataImagePolicy: Equatable {
        static let standard = LinkMetadataImagePolicy(
            maximumSourceByteCount: 10 * 1024 * 1024,
            maximumSourcePixelDimension: 32768,
            maximumSourcePixelCount: 64 * 1024 * 1024,
            maximumNativeFrameCount: 120,
            maximumNativeAggregatePixelCount: 8 * 1024 * 1024,
            maximumOutputPixelDimension: 1600,
            maximumOutputPixelCount: 2 * 1024 * 1024,
            maximumOutputByteCount: 2 * 1024 * 1024,
            validationThumbnailDimension: 64
        )

        let maximumSourceByteCount: Int
        let maximumSourcePixelDimension: UInt64
        let maximumSourcePixelCount: UInt64
        let maximumNativeFrameCount: Int
        let maximumNativeAggregatePixelCount: UInt64
        let maximumOutputPixelDimension: UInt64
        let maximumOutputPixelCount: UInt64
        let maximumOutputByteCount: Int
        let validationThumbnailDimension: Int
    }

    struct LinkMetadataFetchDriver {
        let fetch: @MainActor @Sendable (URL) async throws -> LPLinkMetadata
        let cancel: @Sendable () -> Void
    }

    private final class LiveLinkMetadataFetchSession: @unchecked Sendable {
        private let provider: LPMetadataProvider

        @MainActor
        init() {
            provider = LPMetadataProvider()
            // Title/basic metadata only. Disabling subresources cuts the
            // tracking-beacon and subresource-SSRF surface.
            provider.shouldFetchSubresources = false
        }

        @MainActor
        func fetch(_ url: URL) async throws -> LPLinkMetadata {
            try await provider.startFetchingMetadata(for: url)
        }

        nonisolated func cancel() {
            provider.cancel()
        }
    }

    private final class LinkMetadataAsyncLoad<Value>: @unchecked Sendable {
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
            start: @escaping (@escaping @Sendable (Value?) -> Void) -> Progress?
        ) async -> Value? {
            await withCheckedContinuation { continuation in
                guard install(continuation) else { return }
                install(start { [self] value in
                    finish(value)
                })
            }
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
                preconditionFailure("link metadata load installed twice")
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

        private func finish(_ value: Value?) {
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
    }

    private final class LinkMetadataWorkCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var progress: Progress?

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            let progress: Progress?
            lock.lock()
            cancelled = true
            progress = self.progress
            lock.unlock()
            progress?.cancel()
        }

        func install(_ progress: Progress?) {
            let shouldCancel: Bool
            lock.lock()
            self.progress = progress
            shouldCancel = cancelled
            lock.unlock()
            if shouldCancel {
                progress?.cancel()
            }
        }
    }

    final class LinkMetadataImageWorkLimiter: @unchecked Sendable {
        struct Snapshot: Equatable {
            let activeCount: Int
            let pendingCount: Int
            let maximumObservedActiveCount: Int
        }

        private struct Entry {
            let id: UUID
            let cancelPending: @Sendable () -> Void
            let work: @Sendable () -> Void
        }

        private let lock = NSLock()
        private let maximumConcurrentWork: Int
        private let queue: DispatchQueue
        private var activeIDs: Set<UUID> = []
        private var pending: [Entry] = []
        private var maximumObservedActiveCount = 0

        init(
            maximumConcurrentWork: Int,
            queue: DispatchQueue = DispatchQueue(
                label: "com.clipkitty.link-metadata-image",
                qos: .utility,
                attributes: .concurrent
            )
        ) {
            precondition(maximumConcurrentWork > 0)
            self.maximumConcurrentWork = maximumConcurrentWork
            self.queue = queue
        }

        func submit(
            id: UUID,
            shouldSubmit: @escaping @Sendable () -> Bool = { true },
            cancelPending: @escaping @Sendable () -> Void = {},
            work: @escaping @Sendable () -> Void
        ) {
            let entry = Entry(
                id: id,
                cancelPending: cancelPending,
                work: work
            )
            var shouldStart = false
            lock.lock()
            guard shouldSubmit() else {
                lock.unlock()
                cancelPending()
                return
            }
            if activeIDs.count < maximumConcurrentWork {
                activeIDs.insert(id)
                maximumObservedActiveCount = max(
                    maximumObservedActiveCount,
                    activeIDs.count
                )
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
            let cancelPending: (@Sendable () -> Void)?
            lock.lock()
            if let index = pending.firstIndex(where: { $0.id == id }) {
                // Removing the entry releases its Data/processor closure even
                // if all running codecs remain non-cooperatively wedged.
                cancelPending = pending.remove(at: index).cancelPending
            } else {
                cancelPending = nil
            }
            lock.unlock()
            cancelPending?()
        }

        func snapshot() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return Snapshot(
                activeCount: activeIDs.count,
                pendingCount: pending.count,
                maximumObservedActiveCount: maximumObservedActiveCount
            )
        }

        private func start(_ entry: Entry) {
            queue.async { [self] in
                entry.work()
                complete(id: entry.id)
            }
        }

        private func complete(id: UUID) {
            var next: Entry?
            lock.lock()
            activeIDs.remove(id)
            if !pending.isEmpty {
                next = pending.removeFirst()
                if let next {
                    activeIDs.insert(next.id)
                    maximumObservedActiveCount = max(
                        maximumObservedActiveCount,
                        activeIDs.count
                    )
                }
            }
            lock.unlock()

            if let next {
                start(next)
            }
        }
    }

    enum LinkMetadataImagePreparer {
        typealias Processor = @Sendable (Data, LinkMetadataImagePolicy) -> Data?

        static let processWideLimiter = LinkMetadataImageWorkLimiter(
            maximumConcurrentWork: 2
        )

        static func prepare(
            _ data: Data,
            policy: LinkMetadataImagePolicy = .standard,
            limiter: LinkMetadataImageWorkLimiter = processWideLimiter,
            processor: @escaping Processor = { data, policy in
                process(data, policy: policy)
            }
        ) async -> Data? {
            guard !Task.isCancelled,
                  !data.isEmpty,
                  data.count <= policy.maximumSourceByteCount
            else { return nil }

            let load = LinkMetadataAsyncLoad<Data>()
            let id = UUID()
            return await withTaskCancellationHandler {
                await load.value { completion in
                    let cancellation = LinkMetadataWorkCancellation()
                    let progress = Progress(totalUnitCount: 1)
                    progress.cancellationHandler = {
                        cancellation.cancel()
                        limiter.cancel(id: id)
                    }
                    limiter.submit(
                        id: id,
                        shouldSubmit: { !cancellation.isCancelled }
                    ) {
                        guard !cancellation.isCancelled else {
                            completion(nil)
                            return
                        }
                        let result = processor(data, policy)
                        completion(cancellation.isCancelled ? nil : result)
                        progress.completedUnitCount = 1
                    }
                    return progress
                }
            } onCancel: {
                load.cancel()
            }
        }

        static func process(
            _ data: Data,
            policy: LinkMetadataImagePolicy = .standard
        ) -> Data? {
            guard !data.isEmpty,
                  data.count <= policy.maximumSourceByteCount,
                  policy.maximumSourcePixelDimension > 0,
                  policy.maximumSourcePixelCount > 0,
                  policy.maximumNativeFrameCount > 0,
                  policy.maximumNativeAggregatePixelCount > 0,
                  policy.maximumOutputPixelDimension > 0,
                  policy.maximumOutputPixelCount > 0,
                  policy.maximumOutputByteCount > 0,
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
                    let typeIdentifier = CGImageSourceGetType(source) as String?,
                    UTType(typeIdentifier)?.conforms(to: .image) == true,
                    let firstSize = pixelSize(
                        source: source,
                        index: 0,
                        sourceOptions: sourceOptions
                    ),
                    sourceSizeIsAllowed(firstSize, policy: policy)
                else { return nil }

                let frameCount = CGImageSourceGetCount(source)
                let canPreserveNative = frameCount > 0
                    && frameCount <= policy.maximumNativeFrameCount
                    && allFramesFitNativeBudget(
                        source: source,
                        sourceOptions: sourceOptions,
                        frameCount: frameCount,
                        policy: policy
                    )
                    && firstSize.width <= policy.maximumOutputPixelDimension
                    && firstSize.height <= policy.maximumOutputPixelDimension
                    && (firstSize.pixelCount ?? UInt64.max) <= policy.maximumOutputPixelCount
                    && Double(firstSize.width) / Double(firstSize.height) >= 1.5

                if canPreserveNative {
                    return data
                }

                guard let targetSize = thumbnailMaxPixelSize(
                    sourceSize: firstSize,
                    policy: policy
                ) else { return nil }
                let thumbnailOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: targetSize,
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
                    UInt64(thumbnail.width) <= policy.maximumOutputPixelDimension,
                    UInt64(thumbnail.height) <= policy.maximumOutputPixelDimension,
                    let thumbnailPixelCount = pixelCount(
                        width: UInt64(thumbnail.width),
                        height: UInt64(thumbnail.height)
                    ),
                    thumbnailPixelCount <= policy.maximumOutputPixelCount
                else { return nil }

                let outputImage: CGImage
                let ratio = Double(thumbnail.width) / Double(thumbnail.height)
                if ratio < 1.5 {
                    let croppedHeight = max(1, Int(floor(Double(thumbnail.width) / 1.5)))
                    let y = max(0, (thumbnail.height - croppedHeight) / 2)
                    guard let cropped = thumbnail.cropping(to: CGRect(
                        x: 0,
                        y: y,
                        width: thumbnail.width,
                        height: croppedHeight
                    )) else { return nil }
                    outputImage = cropped
                } else {
                    outputImage = thumbnail
                }
                return encodeJPEG(outputImage, policy: policy)
            }
        }

        private struct PixelSize {
            let width: UInt64
            let height: UInt64

            var pixelCount: UInt64? {
                LinkMetadataImagePreparer.pixelCount(width: width, height: height)
            }
        }

        private static func allFramesFitNativeBudget(
            source: CGImageSource,
            sourceOptions: [CFString: Any],
            frameCount: Int,
            policy: LinkMetadataImagePolicy
        ) -> Bool {
            let validationOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: policy.validationThumbnailDimension,
                kCGImageSourceShouldAllowFloat: false,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            var aggregatePixels: UInt64 = 0
            for index in 0 ..< frameCount {
                guard let size = pixelSize(
                    source: source,
                    index: index,
                    sourceOptions: sourceOptions
                ),
                    sourceSizeIsAllowed(size, policy: policy),
                    let pixels = size.pixelCount,
                    aggregatePixels <= policy.maximumNativeAggregatePixelCount,
                    pixels <= policy.maximumNativeAggregatePixelCount - aggregatePixels,
                    CGImageSourceCreateThumbnailAtIndex(
                        source,
                        index,
                        validationOptions as CFDictionary
                    ) != nil
                else { return false }
                aggregatePixels += pixels
            }
            return true
        }

        private static func sourceSizeIsAllowed(
            _ size: PixelSize,
            policy: LinkMetadataImagePolicy
        ) -> Bool {
            guard size.width <= policy.maximumSourcePixelDimension,
                  size.height <= policy.maximumSourcePixelDimension,
                  let pixels = size.pixelCount,
                  pixels <= policy.maximumSourcePixelCount
            else { return false }
            return true
        }

        private static func thumbnailMaxPixelSize(
            sourceSize: PixelSize,
            policy: LinkMetadataImagePolicy
        ) -> Int? {
            guard let sourcePixels = sourceSize.pixelCount else { return nil }
            let longestSide = max(sourceSize.width, sourceSize.height)
            let dimensionScale = min(
                1,
                Double(policy.maximumOutputPixelDimension) / Double(longestSide)
            )
            let pixelScale = min(
                1,
                (Double(policy.maximumOutputPixelCount) / Double(sourcePixels)).squareRoot()
            )
            let target = floor(Double(longestSide) * min(dimensionScale, pixelScale))
            guard target.isFinite, target >= 1, target <= Double(Int.max) else { return nil }
            return Int(target)
        }

        private static func pixelSize(
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
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
            return if let orientation, (5 ... 8).contains(orientation) {
                PixelSize(width: height, height: width)
            } else {
                PixelSize(width: width, height: height)
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

        private static func pixelCount(width: UInt64, height: UInt64) -> UInt64? {
            guard width > 0, height > 0, width <= UInt64.max / height else { return nil }
            return width * height
        }

        private static func encodeJPEG(
            _ image: CGImage,
            policy: LinkMetadataImagePolicy
        ) -> Data? {
            for quality in [0.82, 0.65, 0.45] {
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
                    [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
                )
                guard CGImageDestinationFinalize(destination) else { return nil }
                if output.length <= policy.maximumOutputByteCount {
                    return output as Data
                }
            }
            return nil
        }
    }

    private enum LinkMetadataFileLoadResult {
        case content(Data)
        case unavailable
        case oversized
        case failed
    }

    private enum LinkMetadataImageProviderLoader {
        private static let unavailableCoercionErrorCode = -1200
        private static let fileReadLimiter = LinkMetadataImageWorkLimiter(
            maximumConcurrentWork: 2,
            queue: DispatchQueue(
                label: "com.clipkitty.link-metadata-file-read",
                qos: .utility,
                attributes: .concurrent
            )
        )

        static func load(
            from provider: NSItemProvider,
            policy: LinkMetadataImagePolicy = .standard
        ) async -> Data? {
            let advertised = provider.registeredTypeIdentifiers.filter {
                UTType($0)?.conforms(to: .image) == true
            }
            let identifiers = advertised.filter { $0 != UTType.image.identifier }
                + advertised.filter { $0 == UTType.image.identifier }
            guard !identifiers.isEmpty else { return nil }

            for identifier in identifiers {
                guard !Task.isCancelled else { return nil }
                let data: Data?
                switch await loadFile(
                    from: provider,
                    typeIdentifier: identifier,
                    maximumByteCount: policy.maximumSourceByteCount
                ) {
                case let .content(value):
                    data = value
                case .unavailable:
                    data = await loadData(
                        from: provider,
                        typeIdentifier: identifier,
                        maximumByteCount: policy.maximumSourceByteCount
                    )
                case .oversized, .failed:
                    data = nil
                }
                guard !Task.isCancelled else { return nil }
                if let data,
                   let prepared = await LinkMetadataImagePreparer.prepare(data, policy: policy),
                   !Task.isCancelled
                {
                    return prepared
                }
            }
            return nil
        }

        private static func loadFile(
            from provider: NSItemProvider,
            typeIdentifier: String,
            maximumByteCount: Int
        ) async -> LinkMetadataFileLoadResult {
            guard provider.hasRepresentationConforming(
                toTypeIdentifier: typeIdentifier,
                fileOptions: []
            ) else { return .unavailable }

            return await load { completion in
                let cancellation = LinkMetadataWorkCancellation()
                let readID = UUID()
                let progress = Progress(totalUnitCount: 1)
                progress.cancellationHandler = {
                    cancellation.cancel()
                    fileReadLimiter.cancel(id: readID)
                }
                let providerProgress = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                    guard !cancellation.isCancelled else {
                        completion(.failed)
                        return
                    }
                    guard let url else {
                        let cocoaError = error as NSError?
                        let unavailable = cocoaError?.domain == NSItemProvider.errorDomain
                            && cocoaError?.code == unavailableCoercionErrorCode
                        completion(unavailable ? .unavailable : .failed)
                        return
                    }
                    // The provider owns this temporary URL only for the
                    // callback. Open it here, then keep the descriptor alive so
                    // the bounded seek/read can run away from the UI actor.
                    guard let handle = try? FileHandle(forReadingFrom: url) else {
                        completion(.failed)
                        return
                    }
                    fileReadLimiter.submit(
                        id: readID,
                        shouldSubmit: { !cancellation.isCancelled },
                        cancelPending: { try? handle.close() }
                    ) {
                        completion(readFile(
                            from: handle,
                            maximumByteCount: maximumByteCount,
                            cancellation: cancellation
                        ))
                    }
                }
                cancellation.install(providerProgress)
                return progress
            } ?? .failed
        }

        private static func readFile(
            from handle: FileHandle,
            maximumByteCount: Int,
            cancellation: LinkMetadataWorkCancellation
        ) -> LinkMetadataFileLoadResult {
            defer { try? handle.close() }
            guard maximumByteCount >= 0,
                  !cancellation.isCancelled
            else { return .oversized }
            do {
                let size = try handle.seekToEnd()
                guard size <= UInt64(maximumByteCount),
                      !cancellation.isCancelled
                else { return .oversized }
                try handle.seek(toOffset: 0)
                let limit = maximumByteCount == Int.max ? Int.max : maximumByteCount + 1
                let data = try handle.read(upToCount: limit) ?? Data()
                guard !cancellation.isCancelled else { return .failed }
                return data.count <= maximumByteCount ? .content(data) : .oversized
            } catch {
                return .failed
            }
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

        private static func load<Value>(
            start: @escaping (@escaping @Sendable (Value?) -> Void) -> Progress?
        ) async -> Value? {
            let load = LinkMetadataAsyncLoad<Value>()
            return await withTaskCancellationHandler {
                await load.value(start: start)
            } onCancel: {
                load.cancel()
            }
        }
    }

    /// Fetches link metadata using Apple's LinkPresentation framework
    @MainActor
    public final class LinkMetadataFetcher {
        private static let maximumTitleByteCount = 256 * 1024
        private let driverFactory: @MainActor @Sendable () -> LinkMetadataFetchDriver

        public init() {
            driverFactory = {
                let session = LiveLinkMetadataFetchSession()
                return LinkMetadataFetchDriver(
                    fetch: { url in try await session.fetch(url) },
                    cancel: { session.cancel() }
                )
            }
        }

        init(
            driverFactory: @escaping @MainActor @Sendable () -> LinkMetadataFetchDriver
        ) {
            self.driverFactory = driverFactory
        }

        /// Fetch metadata for a URL. The request stays structurally owned by its
        /// caller so terminal session cancellation reaches LPMetadataProvider.
        public func fetchMetadata(for url: String, itemId _: String) async -> LinkMetadataPayload? {
            guard let urlObj = URL(string: url) else { return nil }

            // SSRF guard: refuse to fetch previews for URLs that resolve, at the
            // literal/hostname layer, to private, loopback, link-local, or
            // cloud-metadata endpoints. LPMetadataProvider exposes no resolve hook,
            // so DNS-rebinding / resolved-IP SSRF (a hostname that resolves to an
            // internal address at fetch time) remains a residual limitation; this
            // blocks the obvious literal-IP and .local/localhost cases only.
            guard LinkMetadataHostGuard.isFetchable(urlObj) else { return nil }

            let driver = driverFactory()
            do {
                let metadata = try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    let metadata = try await driver.fetch(urlObj)
                    try Task.checkCancellation()
                    return metadata
                } onCancel: {
                    driver.cancel()
                }
                let result = await Self.convert(metadata)
                guard !Task.isCancelled else { return nil }
                return result
            } catch {
                return nil
            }
        }

        private static func convert(_ metadata: LPLinkMetadata) async -> LinkMetadataPayload? {
            let title = metadata.title.flatMap { title in
                title.utf8.count <= maximumTitleByteCount ? title : nil
            }

            // LPMetadataProvider doesn't directly expose og:description
            let description: String? = nil

            let imageData: Data? = if let imageProvider = metadata.imageProvider {
                await LinkMetadataImageProviderLoader.load(from: imageProvider)
            } else {
                nil
            }

            // Return nil if we got nothing useful
            switch (title, imageData) {
            case (nil, nil):
                return nil
            case (let t?, nil):
                return .titleOnly(title: t, description: description)
            case (nil, let img?):
                return .imageOnly(imageData: img, description: description)
            case let (t?, img?):
                return .titleAndImage(title: t, imageData: img, description: description)
            }
        }
    }

    /// Blocks link-preview fetches whose host is a private/loopback/link-local/
    /// unique-local address or a `.local`/loopback/cloud-metadata hostname.
    ///
    /// This is an SSRF mitigation for the preview fetcher: it prevents a copied
    /// URL from steering `LPMetadataProvider` at internal services (e.g. the
    /// cloud-metadata endpoint or a LAN device). It inspects the literal host in
    /// the URL only. Because `LPMetadataProvider` offers no resolve hook, a
    /// hostname that resolves to an internal address at fetch time
    /// (DNS-rebinding / resolved-IP SSRF) is not caught here and remains a
    /// residual limitation.
    enum LinkMetadataHostGuard {
        /// Returns `false` when the URL's host looks internal and must not be fetched.
        static func isFetchable(_ url: URL) -> Bool {
            guard let host = url.host, !host.isEmpty else {
                // No host to reason about (e.g. a bare path); nothing to fetch.
                return false
            }
            return !isBlockedHost(host)
        }

        private static func isBlockedHost(_ rawHost: String) -> Bool {
            // Normalise: strip IPv6 literal brackets and a trailing dot, lowercase.
            var host = rawHost.lowercased()
            if host.hasPrefix("["), host.hasSuffix("]") {
                host = String(host.dropFirst().dropLast())
            }
            if host.hasSuffix(".") {
                host = String(host.dropLast())
            }

            // Literal IP addresses: check numeric ranges directly.
            if let v4 = ipv4Octets(host) {
                return isPrivateIPv4(v4)
            }
            if let v6 = ipv6Bytes(host) {
                return isPrivateIPv6(v6)
            }

            // Hostnames: block the obvious internal names. Full DNS-resolution-time
            // SSRF is out of scope (see type doc).
            if host == "localhost" || host.hasSuffix(".localhost") {
                return true
            }
            if host.hasSuffix(".local") {
                return true
            }
            return false
        }

        // MARK: - IPv4

        /// Parses a dotted-quad IPv4 literal into four octets, or nil if not one.
        private static func ipv4Octets(_ host: String) -> (UInt8, UInt8, UInt8, UInt8)? {
            var addr = in_addr()
            guard host.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else {
                return nil
            }
            let raw = addr.s_addr.bigEndian
            return (
                UInt8((raw >> 24) & 0xFF),
                UInt8((raw >> 16) & 0xFF),
                UInt8((raw >> 8) & 0xFF),
                UInt8(raw & 0xFF)
            )
        }

        private static func isPrivateIPv4(_ octets: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
            let (a, b, _, _) = octets
            // 0.0.0.0/8 (this-network / unspecified)
            if a == 0 { return true }
            // 127.0.0.0/8 (loopback)
            if a == 127 { return true }
            // 10.0.0.0/8 (private)
            if a == 10 { return true }
            // 172.16.0.0/12 (private)
            if a == 172, (16 ... 31).contains(b) { return true }
            // 192.168.0.0/16 (private)
            if a == 192, b == 168 { return true }
            // 169.254.0.0/16 (link-local, includes 169.254.169.254 cloud metadata)
            if a == 169, b == 254 { return true }
            return false
        }

        // MARK: - IPv6

        /// Parses an IPv6 literal into its 16 bytes, or nil if not one.
        private static func ipv6Bytes(_ host: String) -> [UInt8]? {
            var addr = in6_addr()
            guard host.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else {
                return nil
            }
            return withUnsafeBytes(of: &addr) { Array($0) }
        }

        private static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
            guard bytes.count == 16 else { return false }

            // ::1 loopback
            if bytes[0 ..< 15].allSatisfy({ $0 == 0 }), bytes[15] == 1 {
                return true
            }
            // :: unspecified
            if bytes.allSatisfy({ $0 == 0 }) {
                return true
            }
            // fc00::/7 unique local (first 7 bits == 1111110)
            if bytes[0] & 0xFE == 0xFC {
                return true
            }
            // fe80::/10 link-local (first 10 bits == 1111111010)
            if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 {
                return true
            }
            // IPv4-mapped ::ffff:0:0/96 — validate the embedded IPv4 against v4 rules.
            let mappedPrefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]
            if Array(bytes[0 ..< 12]) == mappedPrefix {
                return isPrivateIPv4((bytes[12], bytes[13], bytes[14], bytes[15]))
            }
            // IPv4-compatible ::0:0/96 (deprecated) with an embedded internal v4.
            if bytes[0 ..< 12].allSatisfy({ $0 == 0 }) {
                return isPrivateIPv4((bytes[12], bytes[13], bytes[14], bytes[15]))
            }
            return false
        }
    }
#endif
