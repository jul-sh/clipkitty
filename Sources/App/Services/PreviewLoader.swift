import Foundation
import ClipKittyRust

@MainActor
final class PreviewLoader {
    private let repository: ClipboardRepository
    private let linkMetadataFetcher: LinkMetadataFetcher

    init(
        repository: ClipboardRepository,
        linkMetadataFetcher: LinkMetadataFetcher? = nil
    ) {
        self.repository = repository
        self.linkMetadataFetcher = linkMetadataFetcher ?? LinkMetadataFetcher()
    }

    func fetchItem(id: Int64) async -> ClipboardItem? {
        await repository.fetchItem(id: id)
    }

    func refreshLinkMetadata(url: String, itemId: Int64) async -> ClipboardItem? {
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
