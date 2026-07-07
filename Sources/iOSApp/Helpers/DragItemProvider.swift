import ClipKittyRust
import UIKit
import UniformTypeIdentifiers

enum DragItemProvider {
    /// Type identifier registered on every card drag, visible only within
    /// this process, so the window's drop-to-add target
    /// (`AddClipDropTarget`) can recognize ClipKitty's own drags and ignore
    /// them: re-dropping an existing clip onto the feed must not duplicate
    /// it. Deliberately undeclared as a UTType — receivers match it by exact
    /// identifier, never by conformance.
    static let internalDragMarker = "com.eviljuliette.clipkitty.internal-drag"

    /// Builds an NSItemProvider that lazily fetches the full clipboard item
    /// by id when a drop target requests the data. This lets us start the drag
    /// immediately without having pre-loaded the full content into the card.
    @MainActor
    static func make(itemId: String, fetch: @escaping @Sendable (String) async -> ClipboardItem?) -> NSItemProvider {
        let provider = NSItemProvider()

        provider.registerDataRepresentation(
            forTypeIdentifier: internalDragMarker,
            visibility: .ownProcess
        ) { completion in
            completion(Data(), nil)
            return nil
        }

        // Register every type we might drop as. The drop target picks the best
        // match. Load handlers only fire for the chosen type, so there's no
        // wasted work.
        register(provider, type: .plainText, itemId: itemId, fetch: fetch) { item in
            switch item.content {
            case let .text(value): return value.data(using: .utf8)
            case let .color(value): return value.data(using: .utf8)
            case let .link(url, _): return url.data(using: .utf8)
            case let .image(_, description, _): return description.data(using: .utf8)
            case .file: return nil
            }
        }

        register(provider, type: .utf8PlainText, itemId: itemId, fetch: fetch) { item in
            switch item.content {
            case let .text(value): return value.data(using: .utf8)
            case let .color(value): return value.data(using: .utf8)
            case let .link(url, _): return url.data(using: .utf8)
            case let .image(_, description, _): return description.data(using: .utf8)
            case .file: return nil
            }
        }

        register(provider, type: .url, itemId: itemId, fetch: fetch) { item in
            guard case let .link(url, _) = item.content, let linkURL = URL(string: url) else { return nil }
            return try? NSKeyedArchiver.archivedData(withRootObject: linkURL, requiringSecureCoding: true)
        }

        register(provider, type: .png, itemId: itemId, fetch: fetch) { item in
            guard case let .image(data, _, _) = item.content else { return nil }
            if let uiImage = UIImage(data: data), let png = uiImage.pngData() { return png }
            return data
        }

        return provider
    }

    private static func register(
        _ provider: NSItemProvider,
        type: UTType,
        itemId: String,
        fetch: @escaping @Sendable (String) async -> ClipboardItem?,
        extract: @escaping @Sendable (ClipboardItem) -> Data?
    ) {
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            Task {
                guard let item = await fetch(itemId), let data = extract(item) else {
                    completion(nil, NSError(domain: "ClipKittyDrag", code: 1, userInfo: [NSLocalizedDescriptionKey: "No data for \(type.identifier)"]))
                    return
                }
                completion(data, nil)
            }
            return nil
        }
    }
}
