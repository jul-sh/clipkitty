import Foundation
import ImageIO
import Vision

enum ImageDescriptionGenerator {
    private final class CancellationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    static func generateDescription(from imageData: Data) async -> String? {
        guard let cgImage = cgImage(from: imageData) else { return nil }
        return await describeImage(from: cgImage)
    }

    private static func cgImage(from imageData: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func describeImage(from cgImage: CGImage) async -> String {
        async let labels = classifyImageLabels(from: cgImage)
        async let recognizedText = recognizeText(from: cgImage)
        let (labelResults, textResult) = await (labels, recognizedText)

        var parts: [String] = []
        if !labelResults.isEmpty {
            let list = ListFormatter().string(from: labelResults) ?? labelResults.joined(separator: ", ")
            parts.append("Image: \(list)")
        } else {
            parts.append("Image")
        }

        if let textResult, !textResult.isEmpty {
            parts.append("Text: \(textResult)")
        }

        return parts.joined(separator: ". ")
    }

    private static func classifyImageLabels(from cgImage: CGImage) async -> [String] {
        let request = ClassifyImageRequest()
        do {
            let results = try await request.perform(on: cgImage, orientation: .up)
            return results
                .filter { $0.confidence >= 0.35 }
                .prefix(3)
                .map { $0.identifier }
        } catch {
            logInfo("Vision classifyImageRequest failed: \(error)")
            return []
        }
    }

    private static func recognizeText(from cgImage: CGImage) async -> String? {
        if Task.isCancelled { return nil }
        let token = CancellationToken()

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    if token.isCancelled {
                        continuation.resume(returning: nil)
                        return
                    }

                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .fast
                    request.usesLanguageCorrection = true
                    let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
                    do {
                        try handler.perform([request])
                        if token.isCancelled {
                            continuation.resume(returning: nil)
                            return
                        }
                        let results = request.results ?? []
                        let strings = results
                            .compactMap { $0.topCandidates(1).first?.string }
                            .filter { !$0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty }
                            .prefix(3)
                        let combined = strings.joined(separator: " / ")
                        continuation.resume(returning: truncateText(combined, maxLength: 80))
                    } catch {
                        logInfo("Vision recognizeTextRequest failed: \(error)")
                        continuation.resume(returning: nil)
                    }
                }
            }
        }, onCancel: {
            token.cancel()
        })
    }

    private static func truncateText(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let index = text.index(text.startIndex, offsetBy: maxLength)
        return String(text[..<index]) + "..."
    }
}
