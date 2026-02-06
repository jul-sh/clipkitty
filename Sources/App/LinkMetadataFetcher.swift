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

        // Fetch image data using async continuation
        var imageData: Data?
        if let imageProvider = metadata.imageProvider {
            imageData = await withCheckedContinuation { continuation in
                imageProvider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                    continuation.resume(returning: data)
                }
            }
        }

        // Return nil if we got nothing useful
        if title == nil && imageData == nil {
            return nil
        }

        return FetchedLinkMetadata(
            title: title,
            description: description,
            imageData: imageData
        )
    }
}

struct FetchedLinkMetadata: Sendable {
    let title: String?
    let description: String?
    let imageData: Data?
}
