import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import LinkPresentation

/// Fetches link metadata using Apple's LinkPresentation framework
@MainActor
public final class LinkMetadataFetcher {
    /// In-flight fetch tasks keyed by item ID (prevents duplicate fetches)
    private var activeFetches: [String: Task<FetchedLinkMetadata?, Never>] = [:]

    public init() {}

    /// Fetch metadata for a URL, caching by item ID to prevent duplicate requests
    public func fetchMetadata(for url: String, itemId: String) async -> FetchedLinkMetadata? {
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

        let taskId = ObjectIdentifier(task as AnyObject)
        activeFetches[itemId] = task
        let result = await task.value
        // Check if we're still the active fetch for this itemId (re-entrancy protection)
        if let currentTask = activeFetches[itemId], ObjectIdentifier(currentTask as AnyObject) == taskId {
            activeFetches.removeValue(forKey: itemId)
        }

        return result
    }

    /// Cancel any in-flight fetch for an item
    public func cancelFetch(for itemId: String) {
        activeFetches[itemId]?.cancel()
        activeFetches.removeValue(forKey: itemId)
    }

    /// Cancel all in-flight fetches (cleanup on deinit)
    public func cancelAllFetches() {
        for (_, task) in activeFetches {
            task.cancel()
        }
        activeFetches.removeAll()
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
        case let (t?, img?):
            return .titleAndImage(title: t, imageData: img, description: description)
        }
    }

    /// Crop image to at most 3:2 aspect ratio, center-cropping excess height.
    private static func clampImageTo3x2(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        guard w > 0, h > 0 else { return nil }

        let minRatio: CGFloat = 3.0 / 2.0
        let ratio = w / h
        guard ratio < minRatio else { return nil } // already wide enough

        let croppedH = w / minRatio
        let cropY = (h - croppedH) / 2.0
        let cropRect = CGRect(x: 0, y: cropY, width: w, height: croppedH)

        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }

        let jpegData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            jpegData as CFMutableData, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cropped, [
            kCGImageDestinationLossyCompressionQuality: 0.85,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return jpegData as Data
    }
}

public enum FetchedLinkMetadata: Equatable {
    case titleOnly(title: String, description: String?)
    case imageOnly(imageData: Data, description: String?)
    case titleAndImage(title: String, imageData: Data, description: String?)

    public var title: String? {
        switch self {
        case let .titleOnly(title, _), let .titleAndImage(title, _, _):
            return title
        case .imageOnly:
            return nil
        }
    }

    public var description: String? {
        switch self {
        case let .titleOnly(_, desc), let .imageOnly(_, desc), let .titleAndImage(_, _, desc):
            return desc
        }
    }

    public var imageData: Data? {
        switch self {
        case let .imageOnly(data, _), let .titleAndImage(_, data, _):
            return data
        case .titleOnly:
            return nil
        }
    }
}
