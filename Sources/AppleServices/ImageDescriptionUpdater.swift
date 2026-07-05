import ClipKittyShared
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

    @discardableResult
    public func update(itemId: String, imageData: Data) async -> Result<Bool, ClipboardError> {
        guard !itemId.isEmpty else { return .success(false) }
        guard let description = await generator(imageData) else { return .success(false) }

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
