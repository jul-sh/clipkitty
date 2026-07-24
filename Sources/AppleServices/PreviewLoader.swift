import ClipKittyCore
import ClipKittyRust
import ClipKittyStore
import Foundation

@MainActor
public final class PreviewLoader {
    private let repository: ClipboardRepository
    #if ENABLE_LINK_PREVIEWS
        private let linkMetadataFetcher: LinkMetadataFetcher
    #endif

    #if ENABLE_LINK_PREVIEWS
        public init(
            repository: ClipboardRepository,
            linkMetadataFetcher: LinkMetadataFetcher? = nil
        ) {
            self.repository = repository
            self.linkMetadataFetcher = linkMetadataFetcher ?? LinkMetadataFetcher()
        }
    #else
        public init(repository: ClipboardRepository) {
            self.repository = repository
        }
    #endif

    public func fetchItem(id: String) async -> ClipboardItem? {
        await repository.fetchItem(id: id)
    }

    #if ENABLE_LINK_PREVIEWS
        public func refreshLinkMetadata(url: String, itemId: String) async -> ClipboardItem? {
            let metadata = await linkMetadataFetcher.fetchMetadata(for: url, itemId: itemId)
            _ = await repository.updateLinkMetadata(
                itemId: itemId,
                title: metadata?.title ?? "",
                description: metadata?.description,
                imageData: metadata?.imageData
            )
            return await repository.fetchItem(id: itemId)
        }
    #endif
}
