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

        decodedImage = nil
        let image = await Self.decodeOffPool(data)
        guard !Task.isCancelled, let image else { return }
        DecodedImageCache.setImage(image, forKey: cacheKey, cost: data.count)
        decodedImage = image
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
    private static func decodeOffPool(
        _ data: Data,
        timeout: TimeInterval = 15
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
