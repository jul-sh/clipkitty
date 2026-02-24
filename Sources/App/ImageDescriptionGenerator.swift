import Foundation
import ImageIO
import Vision

struct ImageDescriptionGenerator {

    private enum VisionProcessingResult {
        case success(labels: [String], recognizedText: String?)
        case cancelled
        case failed(Error)
    }

    struct Configuration {
        /// Minimum confidence to accept a label (0.0 - 1.0).
        var minConfidence: Float = 0.35

        /// Maximum number of classification labels to include.
        var maxLabelCount: Int = 100

        /// Maximum number of characters for the recognized text before truncating.
        var maxTextLength: Int = 50_000
    }

    static func generateDescription(from imageData: Data, config: Configuration = .init()) async -> String? {
        // 1. Create source to read properties efficiently
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }

        // 2. Extract EXIF orientation so Vision reads the image "right side up"
        let orientation = CGImagePropertyOrientation(source: source)

        // 3. Create the underlying CGImage
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        // 4. Run Vision requests
        return await processImage(cgImage, orientation: orientation, config: config)
    }

    private static func processImage(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation,
        config: Configuration
    ) async -> String? {

        // Setup Requests
        let labelRequest = VNClassifyImageRequest()
        let textRequest = VNRecognizeTextRequest()

        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true

        // Run blocking Vision work in a detached task
        let result = await Task.detached(priority: .userInitiated) {
            () -> VisionProcessingResult in

            if Task.isCancelled { return .cancelled }

            let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])

            do {
                try handler.perform([labelRequest, textRequest])

                if Task.isCancelled { return .cancelled }

                // Process Labels
                let labels = (labelRequest.results ?? [])
                    .filter { $0.confidence >= config.minConfidence }
                    .map { $0.identifier }
                    .prefix(config.maxLabelCount) // Limit count

                // Process Text
                let strings = (textRequest.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                // Join lines naturally with spaces
                let text = strings.isEmpty ? nil : strings.joined(separator: " ")

                return .success(labels: Array(labels), recognizedText: text)

            } catch {
                return .failed(error)
            }
        }.value

        switch result {
        case .success(let labels, let recognizedText):
            return formatOutput(labels: labels, text: recognizedText, config: config)
        case .cancelled:
            return nil
        case .failed(let error):
            // Optionally log: print("Vision processing failed: \(error)")
            return nil
        }
    }

    private static func formatOutput(labels: [String], text: String?, config: Configuration) -> String {
        var parts: [String] = []

        // Format Labels
        if !labels.isEmpty {
            let list = labels.formatted(.list(type: .and, width: .standard))
            parts.append(list)
        }

        // Format Text with Truncation
        if let text, !text.isEmpty {
            let truncated: String
            if text.count > config.maxTextLength {
                truncated = "\(text.prefix(config.maxTextLength))…"
            } else {
                truncated = text
            }
            parts.append(truncated)
        }

        return parts.joined(separator: ". ")
    }
}

// MARK: - Helpers

extension CGImagePropertyOrientation {
    init(source: CGImageSource) {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        if let rawValue = properties?[kCGImagePropertyOrientation] as? UInt32,
           let orientation = CGImagePropertyOrientation(rawValue: rawValue) {
            self = orientation
        } else {
            self = .up
        }
    }
}
