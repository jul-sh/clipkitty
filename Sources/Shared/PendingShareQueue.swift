import Foundation

/// Lightweight file-based queue for passing items into the main app from its
/// extensions (share sheet, keyboard) without opening the database. Items are
/// written as files in the App Group container and picked up by the main app
/// on activation.
public enum PendingShareQueue {
    private static let pendingDirName = "pending"
    private static let manifestFilename = "manifest.json"
    private static let imageFilename = "image.bin"
    private static let thumbnailFilename = "thumbnail.bin"

    // MARK: - Item Model

    /// Which surface captured the item. Decides the source-app label the item
    /// gets when saved: keyboard captures are clipboard content (labelled like
    /// auto-add's "Pasteboard"), share-sheet items keep "Share Sheet".
    public enum Origin: String, Codable {
        case shareSheet
        case keyboard
    }

    public enum PendingItem: Codable {
        case text(String)
        case url(String)
        case image

        private enum CodingKeys: String, CodingKey {
            case type, text, url
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                self = try .text(container.decode(String.self, forKey: .text))
            case "url":
                self = try .url(container.decode(String.self, forKey: .url))
            case "image":
                self = .image
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown pending item type: \(type)"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .text(text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case let .url(url):
                try container.encode("url", forKey: .type)
                try container.encode(url, forKey: .url)
            case .image:
                try container.encode("image", forKey: .type)
            }
        }
    }

    /// On-disk manifest: the item plus where it came from. `origin` is
    /// optional so manifests written before it existed still decode (they
    /// could only have come from the share sheet).
    private struct Manifest: Codable {
        let item: PendingItem
        let origin: Origin?
    }

    /// A dequeued item with its associated binary data already loaded.
    public struct DequeuedItem {
        public let item: PendingItem
        public let origin: Origin
        public let imageData: Data?
        public let thumbnailData: Data?
    }

    // MARK: - Enqueue (extensions)

    public static func enqueueText(
        _ text: String,
        origin: Origin = .shareSheet,
        in baseDirectory: URL? = nil
    ) throws {
        try writeManifest(.text(text), origin: origin, in: baseDirectory)
    }

    public static func enqueueURL(
        _ url: String,
        origin: Origin = .shareSheet,
        in baseDirectory: URL? = nil
    ) throws {
        try writeManifest(.url(url), origin: origin, in: baseDirectory)
    }

    public static func enqueueImage(
        imageData: Data,
        thumbnail: Data?,
        origin: Origin = .shareSheet,
        in baseDirectory: URL? = nil
    ) throws {
        let dir = try createItemDirectory(in: baseDirectory)
        let manifest = Manifest(item: .image, origin: origin)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: dir.appendingPathComponent(manifestFilename))
        try imageData.write(to: dir.appendingPathComponent(imageFilename))
        if let thumbnail {
            try thumbnail.write(to: dir.appendingPathComponent(thumbnailFilename))
        }
    }

    // MARK: - Peek (keyboard extension)

    /// A pending item read without being removed. The keyboard shows its own
    /// captures at the top of the strip until the app ingests them; full image
    /// bytes stay on disk (`imageFileURL`) so drags can read them lazily.
    public struct PeekedItem: Identifiable {
        /// The queue entry's directory name — stable across reads.
        public let id: String
        public let item: PendingItem
        public let origin: Origin
        public let thumbnailData: Data?
        public let imageFileURL: URL?
        public let enqueuedAt: Date
    }

    /// Reads all pending items without removing them, newest first.
    public static func peekAll(in baseDirectory: URL? = nil) -> [PeekedItem] {
        guard let baseDir = pendingDirectory(in: baseDirectory) else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return [] }

        var results: [PeekedItem] = []
        for itemDir in entries {
            let manifestURL = itemDir.appendingPathComponent(manifestFilename)
            guard let manifestData = try? Data(contentsOf: manifestURL),
                  let manifest = decodeManifest(manifestData)
            else { continue }

            let thumbnailData: Data?
            let imageFileURL: URL?
            if case .image = manifest.item {
                thumbnailData = try? Data(contentsOf: itemDir.appendingPathComponent(thumbnailFilename))
                imageFileURL = itemDir.appendingPathComponent(imageFilename)
            } else {
                thumbnailData = nil
                imageFileURL = nil
            }

            let createdAt = (try? itemDir.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            results.append(PeekedItem(
                id: itemDir.lastPathComponent,
                item: manifest.item,
                origin: manifest.origin ?? .shareSheet,
                thumbnailData: thumbnailData,
                imageFileURL: imageFileURL,
                enqueuedAt: createdAt ?? Date()
            ))
        }
        return results.sorted { $0.enqueuedAt > $1.enqueuedAt }
    }

    // MARK: - Dequeue (main app)

    /// Reads all pending items and removes them from disk. Safe to call from any thread.
    public static func dequeueAll(in baseDirectory: URL? = nil) -> [DequeuedItem] {
        guard let baseDir = pendingDirectory(in: baseDirectory) else { return [] }
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseDir.path) else { return [] }

        guard let entries = try? fm.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var results: [DequeuedItem] = []

        for itemDir in entries {
            let manifestURL = itemDir.appendingPathComponent(manifestFilename)
            guard let manifestData = try? Data(contentsOf: manifestURL),
                  let manifest = decodeManifest(manifestData)
            else {
                // Incomplete or corrupt entry; clean it up
                try? fm.removeItem(at: itemDir)
                continue
            }

            let imageData: Data?
            let thumbnailData: Data?
            if case .image = manifest.item {
                imageData = try? Data(contentsOf: itemDir.appendingPathComponent(imageFilename))
                thumbnailData = try? Data(contentsOf: itemDir.appendingPathComponent(thumbnailFilename))
            } else {
                imageData = nil
                thumbnailData = nil
            }

            results.append(DequeuedItem(
                item: manifest.item,
                origin: manifest.origin ?? .shareSheet,
                imageData: imageData,
                thumbnailData: thumbnailData
            ))
            try? fm.removeItem(at: itemDir)
        }

        // Remove the pending directory itself if now empty
        if (try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil))?.isEmpty == true {
            try? fm.removeItem(at: baseDir)
        }

        return results
    }

    // MARK: - Private

    /// New manifests wrap the item (`{"item": ..., "origin": ...}`); pre-origin
    /// manifests were a bare `PendingItem`, so fall back to that shape.
    private static func decodeManifest(_ data: Data) -> Manifest? {
        let decoder = JSONDecoder()
        if let manifest = try? decoder.decode(Manifest.self, from: data) {
            return manifest
        }
        if let item = try? decoder.decode(PendingItem.self, from: data) {
            return Manifest(item: item, origin: nil)
        }
        return nil
    }

    private static func pendingDirectory(in baseDirectory: URL?) -> URL? {
        let groupDir: URL
        if let baseDirectory {
            groupDir = baseDirectory
        } else if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DatabasePath.appGroupId
        ) {
            groupDir = container
        } else {
            return nil
        }
        return groupDir
            .appendingPathComponent("ClipKitty", isDirectory: true)
            .appendingPathComponent(pendingDirName, isDirectory: true)
    }

    private static func createItemDirectory(in baseDirectory: URL?) throws -> URL {
        guard let baseDir = pendingDirectory(in: baseDirectory) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "App Group container unavailable",
            ])
        }
        let itemDir = baseDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
        return itemDir
    }

    private static func writeManifest(_ item: PendingItem, origin: Origin, in baseDirectory: URL?) throws {
        let dir = try createItemDirectory(in: baseDirectory)
        let data = try JSONEncoder().encode(Manifest(item: item, origin: origin))
        try data.write(to: dir.appendingPathComponent(manifestFilename))
    }
}
