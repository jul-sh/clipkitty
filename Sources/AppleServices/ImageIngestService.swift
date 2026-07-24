import CoreGraphics
import Foundation

public struct ProcessedImageIngest: Sendable {
    public let compressedData: Data
    public let thumbnailData: Data?
    public let isAnimated: Bool

    public init(compressedData: Data, thumbnailData: Data?, isAnimated: Bool) {
        self.compressedData = compressedData
        self.thumbnailData = thumbnailData
        self.isAnimated = isAnimated
    }
}

public enum ImageIngestService {
    public static func process(
        rawImageData: Data,
        isAnimated: Bool,
        quality: CGFloat,
        maxPixels: Int,
        thumbnailGenerator: @escaping @Sendable (Data) -> Data?,
        heicCompressor: @escaping @Sendable (Data, CGFloat, Int) -> Data?,
        animatedHeicCompressor: @escaping @Sendable (Data, CGFloat, Int) -> (Data, Bool)?
    ) async -> ProcessedImageIngest? {
        await Task.detached(priority: .userInitiated) {
            let thumbnail = thumbnailGenerator(rawImageData)

            if isAnimated {
                guard let (compressedData, isActuallyAnimated) = animatedHeicCompressor(
                    rawImageData,
                    quality,
                    maxPixels
                ) else {
                    return nil
                }
                return ProcessedImageIngest(
                    compressedData: compressedData,
                    thumbnailData: thumbnail,
                    isAnimated: isActuallyAnimated
                )
            }

            guard let compressedData = heicCompressor(rawImageData, quality, maxPixels) else {
                return nil
            }
            return ProcessedImageIngest(
                compressedData: compressedData,
                thumbnailData: thumbnail,
                isAnimated: false
            )
        }.value
    }
}
