import SwiftUI
import UIKit

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

/// One-shot guard so a racing decode and its timeout can share a checked
/// continuation: whichever finishes first resumes it, the loser no-ops.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
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
        let image = await Self.decodeOffPool(data)
        guard let image else { return }
        DecodedImageCache.setImage(image, forKey: cacheKey, cost: data.count)

        // A cancelled task here almost always means the data was re-keyed
        // mid-decode: CardImagePreview's thumbnail -> full-resolution upgrade
        // lands, cancelling the thumbnail decode. This result is still the
        // best frame available until the replacement decode finishes, so
        // publish it unless a newer image already got there first. Discarding
        // it is how iPhone captures shipped placeholder cards: the cancelled
        // 64px thumbnail decode left nothing on screen for the full-res
        // decode's entire queue-plus-decode latency.
        if Task.isCancelled {
            if decodedImage == nil { decodedImage = image }
        } else {
            decodedImage = image
        }
    }

    /// Decodes on a GCD queue, never on the Swift Concurrency cooperative
    /// pool, and always resumes within `timeout` even if the decode wedges.
    ///
    /// `preparingForDisplay()` can block indefinitely: HEIC decodes go
    /// through VideoToolbox's HEVC codec, and on HEVC-less hosts (the iOS
    /// simulator inside a virtualized CI runner) `VCPHEVC.videocodec` parks
    /// forever in a `dispatch_semaphore_wait` that never signals. Run on a
    /// detached Task, each wedged decode permanently occupies one of the
    /// cooperative pool's per-core threads; a screenful of image cards then
    /// starves the pool and every async task in the app — including the
    /// accessibility machinery, which is how the iPad screenshot CI job died
    /// with "Timed out while evaluating UI query" while the main thread sat
    /// idle. A wedged decode must cost at most one background GCD thread,
    /// with the caller falling back to the placeholder/thumbnail.
    /// The timeout is a wedge net, not a pacing deadline: it starts when the
    /// work is *enqueued*, and under a burst (the Images filter realizes a
    /// screenful of cards at once) later decodes legitimately spend many
    /// seconds queued behind earlier ones on a few-core CI host. 60s is far
    /// beyond any real decode+wait, while still eventually reclaiming the
    /// continuation if a codec parks forever.
    private static func decodeOffPool(
        _ data: Data,
        timeout: TimeInterval = 60
    ) async -> UIImage? {
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let image = UIImage(data: data)
                let prepared = image?.preparingForDisplay() ?? image
                if once.claim() {
                    continuation.resume(returning: prepared)
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if once.claim() {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
