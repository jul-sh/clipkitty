import AppKit
import Foundation
@preconcurrency import LinkPresentation

/// Fetches link metadata using Apple's LinkPresentation framework
@MainActor
final class LinkMetadataFetcher {
    /// In-flight fetch tasks keyed by item ID (prevents duplicate fetches)
    private var activeFetches: [Int64: Task<FetchedLinkMetadata?, Never>] = [:]

    /// Fetch metadata for a URL, caching by item ID to prevent duplicate requests
    func fetchMetadata(for url: String, itemId: Int64) async -> FetchedLinkMetadata? {
        // Return if already fetching
        if let existingTask = activeFetches[itemId] {
            return await existingTask.value
        }

        guard let urlObj = URL(string: url) else { return nil }

        let task = Task<FetchedLinkMetadata?, Never> { @MainActor in
            let provider = LPMetadataProvider()
            provider.shouldFetchSubresources = true

            do {
                let metadata = try await provider.startFetchingMetadata(for: urlObj)
                return await Self.convert(metadata)
            } catch {
                return nil
            }
        }

        activeFetches[itemId] = task
        let result = await task.value
        activeFetches.removeValue(forKey: itemId)

        return result
    }

    /// Cancel any in-flight fetch for an item
    func cancelFetch(for itemId: Int64) {
        activeFetches[itemId]?.cancel()
        activeFetches.removeValue(forKey: itemId)
    }

    private static func convert(_ metadata: LPLinkMetadata) async -> FetchedLinkMetadata? {
        let title = metadata.title

        // LPMetadataProvider doesn't directly expose og:description
        let description: String? = nil

        // Fetch image data and clamp to 3:2 aspect ratio (no taller)
        var imageData: Data?
        if let imageProvider = metadata.imageProvider {
            let rawData: Data? = await withCheckedContinuation { continuation in
                imageProvider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                    continuation.resume(returning: data)
                }
            }
            imageData = rawData.flatMap { Self.clampImageTo3x2($0) } ?? rawData
        }

        // Return nil if we got nothing useful
        switch (title, imageData) {
        case (nil, nil):
            return nil
        case (let t?, nil):
            return .titleOnly(title: t, description: description)
        case (nil, let img?):
            return .imageOnly(imageData: img, description: description)
        case (let t?, let img?):
            return .titleAndImage(title: t, imageData: img, description: description)
        }
    }

    /// Crop image to at most 3:2 aspect ratio, center-cropping excess height.
    private static func clampImageTo3x2(_ data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let rep = image.representations.first else { return nil }
        let w = CGFloat(rep.pixelsWide)
        let h = CGFloat(rep.pixelsHigh)
        guard w > 0 && h > 0 else { return nil }

        let minRatio: CGFloat = 3.0 / 2.0
        let ratio = w / h
        guard ratio < minRatio else { return nil } // already wide enough

        let croppedH = w / minRatio
        let cropY = (h - croppedH) / 2.0
        let cropRect = CGRect(x: 0, y: cropY, width: w, height: croppedH)

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)?
            .cropping(to: cropRect) else { return nil }

        let cropped = NSBitmapImageRep(cgImage: cgImage)
        return cropped.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}

enum FetchedLinkMetadata: Sendable, Equatable {
    case titleOnly(title: String, description: String?)
    case imageOnly(imageData: Data, description: String?)
    case titleAndImage(title: String, imageData: Data, description: String?)

    var title: String? {
        switch self {
        case .titleOnly(let title, _), .titleAndImage(let title, _, _):
            return title
        case .imageOnly:
            return nil
        }
    }

    var description: String? {
        switch self {
        case .titleOnly(_, let desc), .imageOnly(_, let desc), .titleAndImage(_, _, let desc):
            return desc
        }
    }

    var imageData: Data? {
        switch self {
        case .imageOnly(let data, _), .titleAndImage(_, let data, _):
            return data
        case .titleOnly:
            return nil
        }
    }
}
