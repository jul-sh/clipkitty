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
        let image = await Task.detached(priority: .utility) { [data] in
            let image = UIImage(data: data)
            return image?.preparingForDisplay() ?? image
        }.value
        guard !Task.isCancelled, let image else { return }
        DecodedImageCache.setImage(image, forKey: cacheKey, cost: data.count)
        decodedImage = image
    }
}
