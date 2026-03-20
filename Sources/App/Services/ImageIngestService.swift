import AppKit
import Foundation
import ImageIO

struct ProcessedImageIngest {
    let compressedData: Data
    let thumbnailData: Data?
    let isAnimated: Bool
}

enum ImageIngestService {
    static func process(
        rawImageData: Data,
        isAnimated: Bool,
        quality: CGFloat,
        maxPixels: Int,
        thumbnailGenerator: @escaping @Sendable (Data) -> Data?,
        heicCompressor: @escaping @Sendable (Data, CGFloat, Int) -> Data?,
        animatedHeicCompressor: @escaping @Sendable (Data, CGFloat, Int) -> (Data, Bool)?
    ) async -> ProcessedImageIngest? {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let thumbnail = thumbnailGenerator(rawImageData)

                if isAnimated {
                    guard let (compressedData, isActuallyAnimated) = animatedHeicCompressor(rawImageData, quality, maxPixels) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: ProcessedImageIngest(
                        compressedData: compressedData,
                        thumbnailData: thumbnail,
                        isAnimated: isActuallyAnimated
                    ))
                    return
                }

                guard let compressedData = heicCompressor(rawImageData, quality, maxPixels) else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: ProcessedImageIngest(
                    compressedData: compressedData,
                    thumbnailData: thumbnail,
                    isAnimated: false
                ))
            }
        }
    }
}
