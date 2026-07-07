import Foundation
import UniformTypeIdentifiers

/// One dropped item, reduced to the clip shapes ClipKitty can store.
enum DroppedClipPayload: Equatable {
    case image(data: Data, isAnimated: Bool)
    case url(URL)
    case text(String)
}

/// Classifies and loads the `NSItemProvider`s handed to the window's
/// drop-to-add target (`AddClipDropTarget`), separated from the saving side
/// so the provider juggling is unit-testable with synthetic providers.
enum DroppedClipReader {
    /// Types the drop target advertises. Anything conforming to one of these
    /// can become a clip; notably absent are non-image files — the iOS app
    /// has no file clips (the feed filters them out), and a dropped file's
    /// URL is dead outside its source app's sandbox anyway.
    static let acceptedTypes: [UTType] = [.image, .url, .plainText]

    /// True for drags that started on one of ClipKitty's own cards (in this
    /// process — including another window of the app on iPad). Those already
    /// live in the store; re-adding them would just mint duplicates.
    static func isInternalDrag(_ provider: NSItemProvider) -> Bool {
        provider.registeredTypeIdentifiers.contains(DragItemProvider.internalDragMarker)
    }

    /// Loads the best-fitting payload from one provider: image beats URL
    /// beats text, matching how much meaning each representation preserves
    /// (an image dragged from Safari also carries its page URL; the image is
    /// the thing the user grabbed).
    static func load(from provider: NSItemProvider) async -> DroppedClipPayload? {
        // Registered identifiers are ordered highest-fidelity first, so the
        // first image-conforming one is the best image representation.
        if let imageType = provider.registeredTypeIdentifiers
            .compactMap({ UTType($0) })
            .first(where: { $0.conforms(to: .image) })
        {
            guard let data = await loadData(provider, type: imageType), !data.isEmpty else {
                return nil
            }
            return .image(data: data, isAnimated: imageType.conforms(to: .gif))
        }

        // A non-image file drop (a PDF or text file from Files) reaches here
        // as a file URL. Saving "file:///…" as a link clip is junk — the
        // path is unreadable outside the source app's sandbox — so decline.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return nil
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await loadURL(provider)
        {
            return url.isFileURL ? nil : .url(url)
        }

        if provider.canLoadObject(ofClass: NSString.self) {
            guard let text = await loadString(provider),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            return .text(text)
        }

        return nil
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private static func loadString(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                continuation.resume(returning: string as? String)
            }
        }
    }
}
