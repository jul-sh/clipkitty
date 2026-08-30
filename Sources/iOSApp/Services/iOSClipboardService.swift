import ClipKittyRust
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

// MARK: - Clipboard Reading Result

enum PasteboardContent {
    case image(UIImage)
    case link(URL)
    case text(String)
}

enum AutomaticPasteboardContent: Equatable {
    case image(data: Data, analysis: PasteboardImageAnalysis)
    case link(URL)
    case text(String)
}

struct PasteboardImageAnalysis: Equatable {
    let thumbnail: Data?
    let isAnimated: Bool
}

enum PasteboardImageInspector {
    /// Uses ImageIO rather than filename/type guesses so animated GIF, APNG,
    /// WebP, and HEIF representations are classified from their frames. Making
    /// a bounded thumbnail also proves the advertised bytes are decodable before
    /// Rust persistence accepts them as an image.
    nonisolated static func analyze(_ data: Data) -> PasteboardImageAnalysis? {
        guard !Task.isCancelled else { return nil }
        // Validate actual dimensions and a decodable frame before creating the
        // larger persisted thumbnail. This rejects truncated headers and image
        // bombs consistently for pasteboard, photo, and drop ingestion.
        guard TransferImageValidator.nativeTypeIdentifier(for: data) != nil,
              !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 200,
        ]
        guard let thumbnailImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ), !Task.isCancelled else { return nil }

        return PasteboardImageAnalysis(
            thumbnail: UIImage(cgImage: thumbnailImage).jpegData(compressionQuality: 0.7),
            isAnimated: CGImageSourceGetCount(source) > 1
        )
    }

    /// ImageIO itself is not cooperatively cancellable. This bridge lets the
    /// session teardown stop awaiting it immediately; the stateless detached
    /// worker may safely finish later and its result is discarded.
    nonisolated static func analyzeCancellable(
        _ data: Data
    ) async -> PasteboardImageAnalysis? {
        let operation = AutomaticPasteboardAsyncLoad<PasteboardImageAnalysis>()
        let worker = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else {
                operation.finish(nil)
                return
            }
            operation.finish(analyze(data))
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                _ = operation.install(continuation)
            }
        } onCancel: {
            worker.cancel()
            operation.cancel()
        }
    }
}

enum AutomaticPasteboardReadResult: Equatable {
    /// A supported, bounded representation was read successfully.
    case content(AutomaticPasteboardContent)
    /// Empty, unsupported, concealed, or oversized content should not be retried.
    case ignored
    /// The pasteboard advertises supported content but it is not readable yet.
    /// This includes paste permission denial and a lazily arriving Universal
    /// Clipboard payload, so callers must not permanently acknowledge it.
    case temporarilyUnavailable
}

/// A local write is safe to acknowledge only when it caused the sole observed
/// pasteboard generation advance. If another process writes before or after
/// ClipKitty's mutation, failing closed may cause a harmless later re-read of
/// ClipKitty's value; acknowledging the foreign generation would lose data.
enum PasteboardLocalWriteAcknowledgement {
    static func generation(before: Int, after: Int) -> Int? {
        let (expected, overflow) = before.addingReportingOverflow(1)
        guard !overflow, after == expected else { return nil }
        return after
    }
}

/// A metadata-only view of the first pasteboard item. `NSItemProvider` keeps
/// the actual value lazy, allowing Auto-Add to release the main actor before a
/// remote or cross-process owner materializes its representation.
struct AutomaticPasteboardSnapshot: @unchecked Sendable {
    let typeIdentifiers: [String]
    let itemProvider: NSItemProvider
}

struct AutomaticPasteboardLimits {
    static let standardInbound = AutomaticPasteboardLimits(
        maximumTextByteCount: iOSTransferLimits.maximumTextByteCount,
        maximumImageByteCount: iOSTransferLimits.maximumImageByteCount
    )

    let maximumTextByteCount: Int
    let maximumImageByteCount: Int
}

/// Bridges an `NSItemProvider` progress operation into structured
/// cancellation. Cancellation resumes the awaiting task immediately and also
/// cancels the provider operation; a late provider callback is ignored.
private final class AutomaticPasteboardAsyncLoad<Value>: @unchecked Sendable {
    private enum State {
        case idle
        case awaiting(CheckedContinuation<Value?, Never>)
        case finished(Value?)
        case cancelled
    }

    private let lock = NSLock()
    private var state: State = .idle
    private var progress: Progress?

    @discardableResult
    func install(_ continuation: CheckedContinuation<Value?, Never>) -> Bool {
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
            preconditionFailure("async load continuation installed more than once")
        }
        lock.unlock()
        if let immediateValue {
            continuation.resume(returning: immediateValue)
        }
        return shouldStart
    }

    func install(_ progress: Progress?) {
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
}

private enum AutomaticPasteboardFileLoadResult {
    case content(Data)
    case oversized
    case representationUnavailable
    case temporarilyUnavailable
}

private extension NSItemProvider.ErrorCode {
    /// `NSItemProviderUnavailableCoercionError`; the SDK does not currently
    /// import a Swift case name for this public Objective-C enum value.
    static let clipKittyUnavailableCoercionRawValue = -1200
}

private enum AutomaticPasteboardBoundedFileReader {
    nonisolated static func read(
        from url: URL,
        maximumByteCount: Int
    ) -> AutomaticPasteboardFileLoadResult {
        guard maximumByteCount >= 0 else { return .oversized }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            // Check the file length before allocating a Data buffer. The later
            // read remains bounded as defense against a provider changing the
            // file between this preflight and the read.
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
            return .temporarilyUnavailable
        }
    }
}

/// Loads the first-item representation without synchronously asking
/// `UIPasteboard` to materialize it on the main actor.
enum AutomaticPasteboardLoader {
    static func load(
        snapshot: AutomaticPasteboardSnapshot,
        limits: AutomaticPasteboardLimits
    ) async -> AutomaticPasteboardReadResult {
        let advertisedImageTypes = snapshot.typeIdentifiers.filter { identifier in
            UTType(identifier)?.conforms(to: .image) == true
        }
        // Ask concrete UTIs first so PNG/GIF/JPEG bytes stay in their native
        // representation. `public.image` is an abstract fallback and can cause
        // providers to coerce or re-encode an otherwise concrete payload.
        let imageTypeIdentifiers = advertisedImageTypes.filter {
            $0 != UTType.image.identifier
        } + advertisedImageTypes.filter {
            $0 == UTType.image.identifier
        }
        if !imageTypeIdentifiers.isEmpty {
            return await loadImage(
                from: snapshot.itemProvider,
                typeIdentifiers: imageTypeIdentifiers,
                maximumByteCount: limits.maximumImageByteCount
            )
        }

        if snapshot.typeIdentifiers.contains(where: { identifier in
            UTType(identifier)?.conforms(to: .url) == true
        }) {
            guard snapshot.itemProvider.canLoadObject(ofClass: URL.self) else {
                return .ignored
            }
            guard let url = await loadURL(from: snapshot.itemProvider) else {
                return .temporarilyUnavailable
            }
            guard !Task.isCancelled else { return .temporarilyUnavailable }
            guard url.absoluteString.utf8.count <= limits.maximumTextByteCount else {
                return .ignored
            }
            return .content(.link(url))
        }

        if snapshot.typeIdentifiers.contains(where: { identifier in
            UTType(identifier)?.conforms(to: .text) == true
        }) {
            // Rich text UTIs conform to `public.text`, but an RTF-only provider
            // is not necessarily able to vend an NSString. Unsupported
            // conversion is deterministic and should not consume retry budget.
            guard snapshot.itemProvider.canLoadObject(ofClass: NSString.self) else {
                return .ignored
            }
            guard let string = await loadString(from: snapshot.itemProvider) else {
                return .temporarilyUnavailable
            }
            guard !Task.isCancelled else { return .temporarilyUnavailable }
            guard !string.isEmpty else { return .ignored }
            guard string.utf8.count <= limits.maximumTextByteCount else {
                return .ignored
            }
            return .content(.text(string))
        }

        return .ignored
    }

    private static func loadImage(
        from provider: NSItemProvider,
        typeIdentifiers: [String],
        maximumByteCount: Int
    ) async -> AutomaticPasteboardReadResult {
        var sawOversizedRepresentation = false
        var sawMalformedRepresentation = false
        var sawTemporarilyUnavailableRepresentation = false
        for identifier in typeIdentifiers {
            guard !Task.isCancelled else { return .temporarilyUnavailable }
            let fileResult = await loadFile(
                from: provider,
                typeIdentifier: identifier,
                maximumByteCount: maximumByteCount
            )
            guard !Task.isCancelled else { return .temporarilyUnavailable }
            switch fileResult {
            case let .content(data):
                guard let analysis = await PasteboardImageInspector
                    .analyzeCancellable(data)
                else {
                    guard !Task.isCancelled else { return .temporarilyUnavailable }
                    sawMalformedRepresentation = true
                    continue
                }
                return .content(.image(data: data, analysis: analysis))
            case .oversized:
                sawOversizedRepresentation = true
                continue
            case .temporarilyUnavailable:
                // A promised file that cannot currently be read may represent
                // denied paste access or a lazy Universal Clipboard transfer.
                // Do not request the same bytes again through the data API.
                sawTemporarilyUnavailableRepresentation = true
                continue
            case .representationUnavailable:
                break
            }

            guard let data = await loadData(from: provider, typeIdentifier: identifier) else {
                // A provider without a file representation may still vend
                // bounded data asynchronously. A nil value for an advertised
                // representation can also be a lazy Universal Clipboard value,
                // so it must win over a malformed/oversized sibling below.
                sawTemporarilyUnavailableRepresentation = true
                continue
            }
            guard !Task.isCancelled else { return .temporarilyUnavailable }
            guard data.count <= maximumByteCount else {
                sawOversizedRepresentation = true
                continue
            }
            guard let analysis = await PasteboardImageInspector
                .analyzeCancellable(data)
            else {
                guard !Task.isCancelled else { return .temporarilyUnavailable }
                sawMalformedRepresentation = true
                continue
            }
            return .content(.image(data: data, analysis: analysis))
        }
        if sawTemporarilyUnavailableRepresentation {
            return .temporarilyUnavailable
        }
        return sawOversizedRepresentation || sawMalformedRepresentation
            ? .ignored
            : .temporarilyUnavailable
    }

    private static func loadFile(
        from provider: NSItemProvider,
        typeIdentifier: String,
        maximumByteCount: Int
    ) async -> AutomaticPasteboardFileLoadResult {
        guard provider.hasRepresentationConforming(
            toTypeIdentifier: typeIdentifier,
            fileOptions: []
        ) else {
            return .representationUnavailable
        }

        return await load { completion in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else {
                    let cocoaError = error as NSError?
                    if cocoaError?.domain == NSItemProvider.errorDomain,
                       cocoaError?.code == NSItemProvider.ErrorCode
                       .clipKittyUnavailableCoercionRawValue
                    {
                        completion(.representationUnavailable)
                    } else {
                        completion(.temporarilyUnavailable)
                    }
                    return
                }
                completion(AutomaticPasteboardBoundedFileReader.read(
                    from: url,
                    maximumByteCount: maximumByteCount
                ))
            }
        } ?? .temporarilyUnavailable
    }

    private static func loadData(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async -> Data? {
        await load { completion in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                completion(data)
            }
        }
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await load { completion in
            provider.loadObject(ofClass: URL.self) { url, _ in
                completion(url)
            }
        }
    }

    private static func loadString(from provider: NSItemProvider) async -> String? {
        await load { completion in
            provider.loadObject(ofClass: NSString.self) { string, _ in
                completion(string as? String)
            }
        }
    }

    private static func load<Value>(
        start: (@escaping @Sendable (Value?) -> Void) -> Progress?
    ) async -> Value? {
        let operation = AutomaticPasteboardAsyncLoad<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard operation.install(continuation) else { return }
                operation.install(start { value in
                    operation.finish(value)
                })
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

// MARK: - Clipboard Service

@MainActor
final class iOSClipboardService {
    private let settings: iOSSettingsStore

    /// Match the desktop ingestion ceilings. A pasteboard owner can advertise
    /// arbitrarily large values; bounding automatic ingest avoids unbounded store
    /// growth and image-processing memory spikes.
    private static let automaticPasteboardLimits = AutomaticPasteboardLimits.standardInbound

    init(settings: iOSSettingsStore) {
        self.settings = settings
    }

    /// The current pasteboard generation. Reading `changeCount` never triggers
    /// the system paste-consent alert, unlike reading the pasteboard contents.
    var pasteboardChangeCount: Int {
        UIPasteboard.general.changeCount
    }

    /// Validates one clip before copying it as a native pasteboard item.
    /// Images retain their original UTI and bytes, including animation, rather
    /// than being decoded and flattened through `UIImage` on the main actor.
    @discardableResult
    func copy(content: ClipboardContent) async -> Bool {
        await copy(contents: [content])
    }

    /// Copies a selection as one native multi-item pasteboard transaction.
    /// Every item is bounded and validated off-main before the system
    /// pasteboard is mutated, so an unsupported item cannot leave the user's
    /// clipboard partially replaced.
    @discardableResult
    func copy(contents: [ClipboardContent]) async -> Bool {
        guard let prepared = await PasteboardItemEncoder.prepareAll(contents),
              !Task.isCancelled
        else {
            return false
        }

        let pasteboard = UIPasteboard.general
        let previousGeneration = pasteboard.changeCount
        pasteboard.items = prepared.pasteboardItems
        acknowledgeLocalWrite(
            to: pasteboard,
            previousGeneration: previousGeneration
        )
        return true
    }

    /// Records a pasteboard generation as deliberately handled by ClipKitty.
    /// Passing the generation observed before an asynchronous operation avoids
    /// acknowledging an unrelated write that arrived while that work ran.
    @discardableResult
    func acknowledgeCurrentPasteboardGeneration(
        ifUnchangedFrom expectedGeneration: Int? = nil
    ) -> Bool {
        let generation = UIPasteboard.general.changeCount
        guard expectedGeneration == nil || expectedGeneration == generation else {
            return false
        }
        settings.lastIngestedPasteboardChangeCount = generation
        return true
    }

    func readCurrentClipboard() -> PasteboardContent? {
        let pasteboard = UIPasteboard.general
        let availableTypes = allTypeIdentifiers(on: pasteboard)

        // Skip content the source marked as secret or machine-generated
        // (passwords, OTPs, tokens) unless the user has opted in to capturing
        // sensitive clips. Mirrors the macOS default of ignoring
        // `org.nspasteboard.ConcealedType` / `AutoGeneratedType`.
        if !settings.captureSensitiveClips, isConcealed(availableTypes) {
            return nil
        }

        if pasteboard.hasImages, let image = pasteboard.image {
            return .image(image)
        }
        if pasteboard.hasURLs, let url = pasteboard.url {
            return .link(url)
        }
        if pasteboard.hasStrings, let string = pasteboard.string, !string.isEmpty {
            return .text(string)
        }
        return nil
    }

    /// Reads a stable, Sendable snapshot for unattended Auto-Add. Only
    /// metadata and the first item's provider are captured on the main actor;
    /// cross-process value loading then suspends through `NSItemProvider`.
    func readCurrentClipboardForAutomaticIngest() async -> AutomaticPasteboardReadResult {
        let pasteboard = UIPasteboard.general
        var availableTypes = allTypeIdentifiers(on: pasteboard)

        guard !availableTypes.isEmpty else { return .ignored }
        if !settings.captureSensitiveClips, isConcealed(availableTypes) {
            return .ignored
        }

        guard let provider = pasteboard.itemProviders.first else {
            return .temporarilyUnavailable
        }
        // A provider can expose a more complete ordered type list than the
        // pasteboard preflight. Append only missing identifiers so the source's
        // fidelity order and first-item semantics remain intact.
        for identifier in provider.registeredTypeIdentifiers
            where !availableTypes.contains(identifier)
        {
            availableTypes.append(identifier)
        }
        if !settings.captureSensitiveClips, isConcealed(availableTypes) {
            return .ignored
        }

        return await AutomaticPasteboardLoader.load(
            snapshot: AutomaticPasteboardSnapshot(
                typeIdentifiers: availableTypes,
                itemProvider: provider
            ),
            limits: Self.automaticPasteboardLimits
        )
    }

    /// Type identifiers a source uses to flag pasteboard content that should not
    /// be captured by clipboard history. `ConcealedType` marks secrets (password
    /// managers set it); `AutoGeneratedType` and `TransientType` mark content
    /// written by automation or not meant to persist.
    private static let concealedTypeIdentifiers: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.AutoGeneratedType",
        "org.nspasteboard.TransientType",
    ]

    /// First-item representation identifiers without materializing values.
    /// The value getters below also read the first item; inspecting types across
    /// later items would misclassify a leading text item in a multi-item paste.
    /// `numberOfItems` and `types(forItemSet:)` are documented safe preflights.
    private func allTypeIdentifiers(on pasteboard: UIPasteboard) -> [String] {
        guard pasteboard.numberOfItems > 0 else { return [] }
        return pasteboard.types(forItemSet: IndexSet(integer: 0))?.first
            ?? pasteboard.types
    }

    private func isConcealed(_ availableTypes: [String]) -> Bool {
        availableTypes.contains { Self.concealedTypeIdentifiers.contains($0) }
    }

    private func acknowledgeLocalWrite(
        to pasteboard: UIPasteboard,
        previousGeneration: Int
    ) {
        guard let writtenGeneration = PasteboardLocalWriteAcknowledgement.generation(
            before: previousGeneration,
            after: pasteboard.changeCount
        ) else { return }
        acknowledgeCurrentPasteboardGeneration(ifUnchangedFrom: writtenGeneration)
    }
}
