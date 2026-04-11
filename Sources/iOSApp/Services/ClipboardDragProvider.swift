import ClipKittyRust
import Foundation
import UniformTypeIdentifiers

/// Creates drag `NSItemProvider`s that lazily fetch the full `ClipboardItem`
/// only when the drop destination requests a representation.
///
/// This avoids eagerly loading full item content (e.g. image data) just to
/// start a drag. The fetch result is memoized so multiple UTType requests
/// from the same destination don't trigger multiple repository reads.
enum ClipboardDragProviderFactory {
    /// Build an `NSItemProvider` for a clipboard item, fetching content lazily.
    ///
    /// - Parameters:
    ///   - metadata: Lightweight metadata available from the display row.
    ///   - fetch: Async closure that loads the full `ClipboardItem` from the repository.
    /// - Returns: An `NSItemProvider` configured with lazy representations, or `nil`
    ///   if the item type is known to be unsupported (e.g. files).
    static func makeProvider(
        metadata: ItemMetadata,
        fetch: @escaping @Sendable () async -> ClipboardItem?
    ) -> NSItemProvider? {
        // File items are unsupported on iPhone — fail fast without creating a provider.
        if case .symbol(.file) = metadata.icon {
            return nil
        }

        let advertisedTypes = advertisedUTTypes(for: metadata)
        guard !advertisedTypes.isEmpty else { return nil }

        let provider = NSItemProvider()
        let cache = FetchCache(fetch: fetch)

        for utType in advertisedTypes {
            provider.registerDataRepresentation(for: utType, visibility: .all) { completion in
                Task {
                    guard let item = await cache.fetchOnce() else {
                        completion(nil, DragExportError.fetchFailed)
                        return
                    }
                    let payload = ClipboardExportPayload(content: item.content)
                    let data = payload.representationData(for: utType)
                    if let data {
                        completion(data, nil)
                    } else {
                        completion(nil, DragExportError.unsupportedRepresentation)
                    }
                }
                return nil
            }
        }

        return provider
    }

    // MARK: - UTType Advertisement

    /// Determine which UTTypes to advertise based on lightweight metadata,
    /// without loading the full item content.
    private static func advertisedUTTypes(for metadata: ItemMetadata) -> [UTType] {
        switch metadata.icon {
        case let .symbol(iconType):
            switch iconType {
            case .text, .color:
                return [.plainText]
            case .link:
                return [.url, .plainText]
            case .image:
                // Advertise generic image; the actual type is resolved at fetch time.
                return [.image]
            case .file:
                return []
            }
        case .colorSwatch:
            return [.plainText]
        case .thumbnail:
            return [.image]
        }
    }
}

// MARK: - Representation Data

private extension ClipboardExportPayload {
    /// Produce raw bytes for a specific UTType representation.
    func representationData(for utType: UTType) -> Data? {
        switch self {
        case let .text(value):
            if utType.conforms(to: .plainText) {
                return value.data(using: .utf8)
            }
            return nil

        case let .color(value):
            if utType.conforms(to: .plainText) {
                return value.data(using: .utf8)
            }
            return nil

        case let .url(url, fallbackText):
            if utType.conforms(to: .url) {
                return url.absoluteString.data(using: .utf8)
            }
            if utType.conforms(to: .plainText) {
                return fallbackText.data(using: .utf8)
            }
            return nil

        case let .image(data, _, _):
            if utType.conforms(to: .image) {
                return data
            }
            return nil

        case .unsupported:
            return nil
        }
    }
}

// MARK: - Fetch Cache

/// Actor that ensures the fetch closure runs at most once, memoizing the result.
private actor FetchCache {
    private let fetch: @Sendable () async -> ClipboardItem?
    private var result: ClipboardItem??

    init(fetch: @escaping @Sendable () async -> ClipboardItem?) {
        self.fetch = fetch
    }

    func fetchOnce() async -> ClipboardItem? {
        if let cached = result {
            return cached
        }
        let item = await fetch()
        result = .some(item)
        return item
    }
}

// MARK: - Errors

private enum DragExportError: Error {
    case fetchFailed
    case unsupportedRepresentation
}
