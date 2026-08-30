import Foundation
import UniformTypeIdentifiers

/// One dropped item, reduced to the clip shapes ClipKitty can store.
enum DroppedClipPayload: Equatable {
    case image(data: Data, analysis: PasteboardImageAnalysis)
    case url(URL)
    case text(String)

    var byteCount: Int {
        switch self {
        case let .image(data, _): data.count
        case let .url(url): url.absoluteString.utf8.count
        case let .text(text): text.utf8.count
        }
    }
}

/// One set of shared ceilings for every payload accepted by a window drop.
/// Tests can inject smaller values without allocating tens of megabytes.
struct DroppedClipPolicy: Equatable {
    static let standard = DroppedClipPolicy(
        maximumItemCount: iOSTransferLimits.maximumItemCount,
        maximumTextByteCount: iOSTransferLimits.maximumTextByteCount,
        maximumImageByteCount: iOSTransferLimits.maximumImageByteCount,
        maximumAggregateByteCount: iOSTransferLimits.maximumAggregateByteCount
    )

    let maximumItemCount: Int
    let maximumTextByteCount: Int
    let maximumImageByteCount: Int
    let maximumAggregateByteCount: Int

    init(
        maximumItemCount: Int,
        maximumTextByteCount: Int,
        maximumImageByteCount: Int,
        maximumAggregateByteCount: Int
    ) {
        self.maximumItemCount = max(0, maximumItemCount)
        self.maximumTextByteCount = max(0, maximumTextByteCount)
        self.maximumImageByteCount = max(0, maximumImageByteCount)
        self.maximumAggregateByteCount = max(0, maximumAggregateByteCount)
    }

    var loaderLimits: AutomaticPasteboardLimits {
        AutomaticPasteboardLimits(
            maximumTextByteCount: maximumTextByteCount,
            maximumImageByteCount: maximumImageByteCount
        )
    }

    /// Restricts the next provider to the bytes that are still available to
    /// this batch. Applying the aggregate remainder before materialization is
    /// important for file representations: their length can be rejected
    /// without allocating or decoding a second full-size image.
    func limitingNextPayload(to remainingByteCount: Int) -> DroppedClipPolicy {
        let remainingByteCount = max(0, remainingByteCount)
        return DroppedClipPolicy(
            maximumItemCount: maximumItemCount,
            maximumTextByteCount: min(maximumTextByteCount, remainingByteCount),
            maximumImageByteCount: min(maximumImageByteCount, remainingByteCount),
            maximumAggregateByteCount: min(
                maximumAggregateByteCount,
                remainingByteCount
            )
        )
    }

    func boundedProviders(_ providers: [NSItemProvider]) -> [NSItemProvider] {
        Array(providers.prefix(maximumItemCount))
    }
}

struct DroppedClipBatchBudget {
    let policy: DroppedClipPolicy
    private(set) var acceptedByteCount = 0

    init(policy: DroppedClipPolicy = .standard) {
        self.policy = policy
    }

    var remainingByteCount: Int {
        guard acceptedByteCount <= policy.maximumAggregateByteCount else { return 0 }
        return policy.maximumAggregateByteCount - acceptedByteCount
    }

    var nextPayloadPolicy: DroppedClipPolicy {
        policy.limitingNextPayload(to: remainingByteCount)
    }

    mutating func admit(_ payload: DroppedClipPayload) -> Bool {
        let byteCount = payload.byteCount
        guard byteCount >= 0,
              acceptedByteCount <= policy.maximumAggregateByteCount,
              byteCount <= policy.maximumAggregateByteCount - acceptedByteCount
        else { return false }
        acceptedByteCount += byteCount
        return true
    }
}

/// Process-wide identity gate behind the single active drop task. Every iPad
/// window reaches the same shared instance, so separate drop targets cannot
/// each materialize an aggregate-size batch. Exact identity also means a stale
/// completion can never clear a newer batch's lease.
@MainActor
final class DroppedClipIngestAdmission {
    static let shared = DroppedClipIngestAdmission()

    private(set) var activeRequestID: UUID?

    func admit(requestID: UUID) -> Bool {
        guard activeRequestID == nil else { return false }
        activeRequestID = requestID
        return true
    }

    func owns(requestID: UUID) -> Bool {
        activeRequestID == requestID
    }

    @discardableResult
    func finish(requestID: UUID) -> Bool {
        guard activeRequestID == requestID else { return false }
        activeRequestID = nil
        return true
    }
}

/// Classifies and loads the `NSItemProvider`s handed to the window's
/// drop-to-add target (`AddClipDropTarget`), separated from the saving side
/// so the provider juggling is unit-testable with synthetic providers.
enum DroppedClipReader {
    /// Types the drop target advertises. Anything conforming to one of these
    /// can become a clip; notably absent are non-image files — the iOS app
    /// has no file clips (the feed filters them out), and a dropped file's
    /// URL is dead outside its source app's sandbox anyway.
    static let acceptedTypes: [UTType] = [.image, .url, .plainText]

    /// True for drags that started on one of ClipKitty's own cards (in this
    /// process — including another window of the app on iPad). Those already
    /// live in the store; re-adding them would just mint duplicates.
    static func isInternalDrag(_ provider: NSItemProvider) -> Bool {
        provider.registeredTypeIdentifiers.contains(DragItemProvider.internalDragMarker)
    }

    /// Loads the best-fitting payload from one provider: image beats URL
    /// beats text, matching how much meaning each representation preserves
    /// (an image dragged from Safari also carries its page URL; the image is
    /// the thing the user grabbed).
    static func load(
        from provider: NSItemProvider,
        policy: DroppedClipPolicy = .standard
    ) async -> DroppedClipPayload? {
        let result = await AutomaticPasteboardLoader.load(
            snapshot: AutomaticPasteboardSnapshot(
                typeIdentifiers: provider.registeredTypeIdentifiers,
                itemProvider: provider
            ),
            limits: policy.loaderLimits
        )
        guard !Task.isCancelled else { return nil }

        switch result {
        case let .content(.image(data, analysis)):
            return .image(data: data, analysis: analysis)
        case let .content(.link(url)):
            // A non-image file drop (a PDF or text file from Files) reaches
            // here as a file URL. Its sandbox path is useless after the drop.
            return url.isFileURL ? nil : .url(url)
        case let .content(.text(text)):
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : .text(text)
        case .ignored, .temporarilyUnavailable:
            return nil
        }
    }
}
