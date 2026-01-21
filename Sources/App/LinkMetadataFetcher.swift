import Foundation
import AppKit
import ClipKittyRust

/// Fetches Open Graph metadata from URLs
actor LinkMetadataFetcher {
    static let shared = LinkMetadataFetcher()

    private init() {}

    func fetch(url urlString: String) async -> LinkMetadataState? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else {
                return nil
            }

            let title = extractOGTag(from: html, property: "og:title") ?? extractTitle(from: html)
            let imageURL = extractOGTag(from: html, property: "og:image")

            var imageData: Data? = nil
            if let imageURLString = imageURL, let imgURL = URL(string: imageURLString) {
                if let (imgData, _) = try? await URLSession.shared.data(from: imgURL) {
                    imageData = compressImage(imgData)
                }
            }

            let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedTitle = trimmedTitle?.isEmpty == true ? nil : trimmedTitle
            if normalizedTitle == nil && imageData == nil {
                return nil
            }
            return .loaded(title: normalizedTitle, imageData: imageData.map { Array($0) })
        } catch {
            return nil
        }
    }

    private func extractOGTag(from html: String, property: String) -> String? {
        // Pattern: <meta property="og:title" content="...">
        let patterns = [
            "<meta[^>]*property=[\"']\(property)[\"'][^>]*content=[\"']([^\"']+)[\"']",
            "<meta[^>]*content=[\"']([^\"']+)[\"'][^>]*property=[\"']\(property)[\"']"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                return String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func extractTitle(from html: String) -> String? {
        let pattern = "<title[^>]*>([^<]+)</title>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func compressImage(_ data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }

        // Resize to max 400px for preview
        let maxSize: CGFloat = 400
        let size = image.size
        var newSize = size

        if size.width > maxSize || size.height > maxSize {
            let ratio = min(maxSize / size.width, maxSize / size.height)
            newSize = NSSize(width: size.width * ratio, height: size.height * ratio)
        }

        let resizedImage = NSImage(size: newSize)
        resizedImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize))
        resizedImage.unlockFocus()

        guard let tiffData = resizedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            return nil
        }

        return jpegData
    }
}
