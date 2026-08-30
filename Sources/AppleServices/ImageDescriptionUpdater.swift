import ClipKittyCore
import ClipKittyStore
import Foundation

public struct ImageDescriptionUpdater {
    private let repository: ClipboardRepository
    private let generator: (Data) async -> String?

    public init(
        repository: ClipboardRepository,
        generator: @escaping (Data) async -> String? = { data in
            await ImageDescriptionGenerator.generateDescription(from: data)
        }
    ) {
        self.repository = repository
        self.generator = generator
    }

    /// Lazily fetches the persisted image only when the caller's serial worker
    /// is ready to process this item. Queue owners can therefore retain a small
    /// item ID instead of keeping the original full-resolution `Data` alive.
    @discardableResult
    public func update(itemId: String) async -> Result<Bool, ClipboardError> {
        guard !itemId.isEmpty else { return .success(false) }
        guard !Task.isCancelled else { return .success(false) }
        guard let item = await repository.fetchItem(id: itemId) else {
            return .success(false)
        }
        // Fetching can outlive cancellation while the synchronous store read is
        // admitted. Do not hand its image bytes to Vision afterward.
        guard !Task.isCancelled else { return .success(false) }
        guard case let .image(imageData, _, _) = item.content else {
            return .success(false)
        }
        return await update(itemId: itemId, imageData: imageData)
    }

    @discardableResult
    public func update(itemId: String, imageData: Data) async -> Result<Bool, ClipboardError> {
        guard !itemId.isEmpty else { return .success(false) }
        guard !Task.isCancelled else { return .success(false) }
        guard let description = await generator(imageData) else { return .success(false) }
        // A foreground session can be revoked while Vision is working. Never
        // let a cancelled outgoing session touch its repository afterward.
        guard !Task.isCancelled else { return .success(false) }

        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success(false) }

        let result = await repository.updateImageDescription(itemId: itemId, description: trimmed)
        switch result {
        case .success:
            return .success(true)
        case let .failure(error):
            return .failure(error)
        }
    }
}
