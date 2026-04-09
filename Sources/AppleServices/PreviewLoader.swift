import ClipKittyRust
import ClipKittyShared
import Foundation

@MainActor
public final class PreviewLoader {
    private let repository: ClipboardRepository
    #if ENABLE_LINK_PREVIEWS
        private let linkMetadataFetcher: LinkMetadataFetcher
    #endif

    public init(
        repository: ClipboardRepository
        #if ENABLE_LINK_PREVIEWS
            , linkMetadataFetcher: LinkMetadataFetcher? = nil
        #endif
    ) {
        self.repository = repository
        #if ENABLE_LINK_PREVIEWS
            self.linkMetadataFetcher = linkMetadataFetcher ?? LinkMetadataFetcher()
        #endif
    }

    public func fetchItem(id: String) async -> ClipboardItem? {
        await repository.fetchItem(id: id)
    }

    #if ENABLE_LINK_PREVIEWS
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
    #endif
}
