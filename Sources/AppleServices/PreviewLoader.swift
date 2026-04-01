import ClipKittyRust
import ClipKittyShared
import Foundation

@MainActor
public final class PreviewLoader {
    private let repository: ClipboardRepository
    private let linkMetadataFetcher: LinkMetadataFetcher

    public init(
        repository: ClipboardRepository,
        linkMetadataFetcher: LinkMetadataFetcher? = nil
    ) {
        self.repository = repository
        self.linkMetadataFetcher = linkMetadataFetcher ?? LinkMetadataFetcher()
    }

    public func fetchItem(id: String) async -> ClipboardItem? {
        await repository.fetchItem(id: id)
    }

    public func refreshLinkMetadata(url: String, itemId: String) async -> ClipboardItem? {
        guard let metadata = await linkMetadataFetcher.fetchMetadata(for: url, itemId: itemId) else {
            _ = await repository.updateLinkMetadata(
                itemId: itemId,
                title: "",
                description: nil,
                imageData: nil
            )
            return await repository.fetchItem(id: itemId)
        }

        _ = await repository.updateLinkMetadata(
            itemId: itemId,
            title: metadata.title,
            description: metadata.description,
            imageData: metadata.imageData
        )
        return await repository.fetchItem(id: itemId)
    }
}
