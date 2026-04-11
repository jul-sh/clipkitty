import Foundation

/// Lightweight file-based queue for passing shared items from the share extension
/// to the main app without opening the database. Items are written as files in the
/// App Group container and picked up by the main app on activation.
public enum PendingShareQueue {
    private static let pendingDirName = "pending"
    private static let manifestFilename = "manifest.json"
    private static let imageFilename = "image.bin"
    private static let thumbnailFilename = "thumbnail.bin"

    // MARK: - Item Model

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
                self = .text(try container.decode(String.self, forKey: .text))
            case "url":
                self = .url(try container.decode(String.self, forKey: .url))
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

    /// A dequeued item with its associated binary data already loaded.
    public struct DequeuedItem {
        public let item: PendingItem
        public let imageData: Data?
        public let thumbnailData: Data?
    }

    // MARK: - Enqueue (share extension)

    public static func enqueueText(_ text: String) throws {
        try writeManifest(.text(text))
    }

    public static func enqueueURL(_ url: String) throws {
        try writeManifest(.url(url))
    }

    public static func enqueueImage(imageData: Data, thumbnail: Data?) throws {
        let dir = try createItemDirectory()
        let manifest = PendingItem.image
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: dir.appendingPathComponent(manifestFilename))
        try imageData.write(to: dir.appendingPathComponent(imageFilename))
        if let thumbnail {
            try thumbnail.write(to: dir.appendingPathComponent(thumbnailFilename))
        }
    }

    // MARK: - Dequeue (main app)

    /// Reads all pending items and removes them from disk. Safe to call from any thread.
    public static func dequeueAll() -> [DequeuedItem] {
        guard let baseDir = pendingDirectory() else { return [] }
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
                  let item = try? JSONDecoder().decode(PendingItem.self, from: manifestData)
            else {
                // Incomplete or corrupt entry; clean it up
                try? fm.removeItem(at: itemDir)
                continue
            }

            let imageData: Data?
            let thumbnailData: Data?
            if case .image = item {
                imageData = try? Data(contentsOf: itemDir.appendingPathComponent(imageFilename))
                thumbnailData = try? Data(contentsOf: itemDir.appendingPathComponent(thumbnailFilename))
            } else {
                imageData = nil
                thumbnailData = nil
            }

            results.append(DequeuedItem(item: item, imageData: imageData, thumbnailData: thumbnailData))
            try? fm.removeItem(at: itemDir)
        }

        // Remove the pending directory itself if now empty
        if (try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil))?.isEmpty == true {
            try? fm.removeItem(at: baseDir)
        }

        return results
    }

    // MARK: - Private

    private static func pendingDirectory() -> URL? {
        guard let groupDir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DatabasePath.appGroupId
        ) else { return nil }
        return groupDir
            .appendingPathComponent("ClipKitty", isDirectory: true)
            .appendingPathComponent(pendingDirName, isDirectory: true)
    }

    private static func createItemDirectory() throws -> URL {
        guard let baseDir = pendingDirectory() else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "App Group container unavailable",
            ])
        }
        let itemDir = baseDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
        return itemDir
    }

    private static func writeManifest(_ item: PendingItem) throws {
        let dir = try createItemDirectory()
        let data = try JSONEncoder().encode(item)
        try data.write(to: dir.appendingPathComponent(manifestFilename))
    }
}
