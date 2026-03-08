import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Image Ingest Result

struct ImageIngestResult: Sendable {
    let compressedData: Data
    let thumbnail: Data?
    let isAnimated: Bool
}

// MARK: - Image Ingest Service

/// Service for image compression, thumbnail generation, and format conversion.
enum ImageIngestService {
    private static let maxAnimatedFrames = 50
    private static let maxAnimatedDuration: Double = 3.0

    static func processImage(rawData: Data, isAnimated: Bool, quality: CGFloat, maxPixels: Int) -> ImageIngestResult? {
        let thumbnail = generateThumbnail(rawData)
        if isAnimated {
            guard let (data, actuallyAnimated) = compressToAnimatedHEIC(rawData, quality: quality, maxPixels: maxPixels) else { return nil }
            return ImageIngestResult(compressedData: data, thumbnail: thumbnail, isAnimated: actuallyAnimated)
        } else {
            guard let data = compressToHEIC(rawData, quality: quality, maxPixels: maxPixels) else { return nil }
            return ImageIngestResult(compressedData: data, thumbnail: thumbnail, isAnimated: false)
        }
    }

    static func generateThumbnail(_ imageData: Data, maxSize: Int = 64) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              let resized = resizeCGImage(cgImage, maxWidth: maxSize, maxHeight: maxSize, quality: .medium) else { return nil }
        return encodeCGImage(resized, type: "public.jpeg" as CFString, quality: 0.6)
    }

    static func convertAnimatedHEICToGIF(_ heicData: Data) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(heicData as CFData, nil) else { return nil }
        let frameCount = CGImageSourceGetCount(imageSource)
        guard frameCount > 1 else { return nil }

        let gifData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(gifData as CFMutableData, UTType.gif.identifier as CFString, frameCount, nil) else { return nil }

        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

        for i in 0..<frameCount {
            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, i, nil) else { continue }
            var delay: Double = 0.1
            if let props = CGImageSourceCopyPropertiesAtIndex(imageSource, i, nil) as? [CFString: Any],
               let heicsProps = props[kCGImagePropertyHEICSDictionary] as? [CFString: Any],
               let d = heicsProps[kCGImagePropertyHEICSDelayTime] as? Double { delay = d }
            CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return gifData as Data
    }

    private static func compressToHEIC(_ imageData: Data, quality: CGFloat, maxPixels: Int) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }
        let pixels = cgImage.width * cgImage.height
        let image: CGImage
        if pixels > maxPixels {
            let scale = sqrt(Double(maxPixels) / Double(pixels))
            guard let resized = resizeCGImage(cgImage, maxWidth: max(1, Int(Double(cgImage.width) * scale)), maxHeight: max(1, Int(Double(cgImage.height) * scale))) else { return nil }
            image = resized
        } else { image = cgImage }
        return encodeCGImage(image, type: "public.heic" as CFString, quality: quality)
    }

    private static func compressToAnimatedHEIC(_ gifData: Data, quality: CGFloat, maxPixels: Int) -> (Data, Bool)? {
        guard let imageSource = CGImageSourceCreateWithData(gifData as CFData, nil) else { return nil }
        let frameCount = CGImageSourceGetCount(imageSource)
        if frameCount <= 1 {
            guard let staticData = compressToHEIC(gifData, quality: quality, maxPixels: maxPixels) else { return nil }
            return (staticData, false)
        }

        var frameDelays: [Double] = (0..<frameCount).map { gifFrameDelay(source: imageSource, index: $0) }
        let totalDuration = frameDelays.reduce(0, +)

        let framesToKeep: [Int]
        let adjustedDelays: [Double]

        if totalDuration > maxAnimatedDuration || frameCount > maxAnimatedFrames {
            let targetCount = max(2, min(maxAnimatedFrames, Int(Double(frameCount) * (maxAnimatedDuration / totalDuration))))
            let step = Double(frameCount - 1) / Double(targetCount - 1)
            framesToKeep = (0..<targetCount).map { min(Int(Double($0) * step), frameCount - 1) }
            let scale = min(1.0, maxAnimatedDuration / totalDuration)
            adjustedDelays = framesToKeep.map { frameDelays[$0] * scale }
        } else {
            framesToKeep = Array(0..<frameCount)
            adjustedDelays = frameDelays
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.heics" as CFString, framesToKeep.count, nil),
              let firstCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }

        let pixels = firstCGImage.width * firstCGImage.height
        let needsResize = pixels > maxPixels
        let scale = needsResize ? sqrt(Double(maxPixels) / Double(pixels)) : 1.0
        let targetW = needsResize ? max(1, Int(Double(firstCGImage.width) * scale)) : firstCGImage.width
        let targetH = needsResize ? max(1, Int(Double(firstCGImage.height) * scale)) : firstCGImage.height

        for (idx, frameIndex) in framesToKeep.enumerated() {
            guard !Task.isCancelled, let cgImage = CGImageSourceCreateImageAtIndex(imageSource, frameIndex, nil) else { continue }
            let finalImage = needsResize ? (resizeCGImage(cgImage, maxWidth: targetW, maxHeight: targetH) ?? cgImage) : cgImage
            CGImageDestinationAddImage(destination, finalImage, [
                kCGImageDestinationLossyCompressionQuality: quality,
                kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSLoopCount: 0, kCGImagePropertyHEICSDelayTime: adjustedDelays[idx]]
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data, true)
    }

    private static func gifFrameDelay(source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifProps = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        if let d = gifProps[kCGImagePropertyGIFUnclampedDelayTime] as? Double, d > 0 { return d }
        if let d = gifProps[kCGImagePropertyGIFDelayTime] as? Double, d > 0 { return d }
        return 0.1
    }

    private static func resizeCGImage(_ cgImage: CGImage, maxWidth: Int, maxHeight: Int, quality: CGInterpolationQuality = .high) -> CGImage? {
        let w = cgImage.width, h = cgImage.height
        guard w > maxWidth || h > maxHeight else { return cgImage }
        let scale = min(Double(maxWidth) / Double(w), Double(maxHeight) / Double(h))
        let newW = max(1, Int(Double(w) * scale)), newH = max(1, Int(Double(h) * scale))
        guard let ctx = CGContext(data: nil, width: newW, height: newH, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = quality
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }

    private static func encodeCGImage(_ cgImage: CGImage, type: CFString, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
