import Foundation
import ImageIO
import Vision

enum ImageDescriptionGenerator {
    static func generateDescription(from imageData: Data) async -> String? {
        guard let cgImage = cgImage(from: imageData) else { return nil }
        return await classifyImageDescription(from: cgImage)
    }

    private static func cgImage(from imageData: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func classifyImageDescription(from cgImage: CGImage) async -> String {
        let request = ClassifyImageRequest()
        do {
            let results = try await request.perform(on: cgImage, orientation: .up)
            let labels = results
                .filter { $0.confidence >= 0.35 }
                .prefix(3)
                .map { $0.identifier }
            guard !labels.isEmpty else { return "Image" }
            let list = ListFormatter().string(from: labels) ?? labels.joined(separator: ", ")
            return "Image: \(list)"
        } catch {
            logInfo("Vision classifyImageRequest failed: \(error)")
            return "Image"
        }
    }
}
