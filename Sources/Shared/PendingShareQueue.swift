import Foundation

/// Lightweight file-based queue for passing items into the main app from the
/// share extension without opening the database. Items are written as files
/// in the App Group container and picked up by the main app on activation.
public enum PendingShareQueue {
    private static let pendingDirName = "pending"
    private static let manifestFilename = "manifest.json"
    private static let imageFilename = "image.bin"
    private static let thumbnailFilename = "thumbnail.bin"

    // MARK: - Item Model

    private enum Manifest: Codable {
        case text(String)
        case url(String)
        case image

        private enum CodingKeys: String, CodingKey {
            case type, text, url
        }

        init(from decoder: Decoder) throws {
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

        func encode(to encoder: Encoder) throws {
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

    /// A dequeued item whose payload contains exactly the data its variant needs.
    public enum DequeuedItem {
        case text(String)
        case url(String)
        case image(data: Data, thumbnail: Data?)
    }

    // MARK: - Enqueue (extensions)

    public static func enqueueText(
        _ text: String,
        in baseDirectory: URL? = nil
    ) throws {
        try writeManifest(.text(text), in: baseDirectory)
    }

    public static func enqueueURL(
        _ url: String,
        in baseDirectory: URL? = nil
    ) throws {
        try writeManifest(.url(url), in: baseDirectory)
    }

    public static func enqueueImage(
        imageData: Data,
        thumbnail: Data?,
        in baseDirectory: URL? = nil
    ) throws {
        try publishItem(in: baseDirectory) { directory in
            let data = try JSONEncoder().encode(Manifest.image)
            try writeProtected(data, to: directory.appendingPathComponent(manifestFilename))
            try writeProtected(imageData, to: directory.appendingPathComponent(imageFilename))
            if let thumbnail {
                try writeProtected(thumbnail, to: directory.appendingPathComponent(thumbnailFilename))
            }
        }
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

        // UUID-named directories are complete, atomically published items.
        // Dot-prefixed staging directories belong to an active or interrupted
        // writer and must never be consumed as corrupt input.
        for itemDir in entries where UUID(uuidString: itemDir.lastPathComponent) != nil {
            let manifestURL = itemDir.appendingPathComponent(manifestFilename)
            guard let manifestData = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData)
            else {
                // Incomplete or corrupt entry; clean it up
                try? fm.removeItem(at: itemDir)
                continue
            }

            let item: DequeuedItem
            switch manifest {
            case let .text(text):
                item = .text(text)
            case let .url(url):
                item = .url(url)
            case .image:
                guard let imageData = try? Data(
                    contentsOf: itemDir.appendingPathComponent(imageFilename)
                ) else {
                    try? fm.removeItem(at: itemDir)
                    continue
                }
                let thumbnail = try? Data(
                    contentsOf: itemDir.appendingPathComponent(thumbnailFilename)
                )
                item = .image(data: imageData, thumbnail: thumbnail)
            }

            results.append(item)
            try? fm.removeItem(at: itemDir)
        }

        // Remove the pending directory itself if now empty
        if (try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil))?.isEmpty == true {
            try? fm.removeItem(at: baseDir)
        }

        return results
    }

    // MARK: - Private

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

    private static func publishItem(
        in baseDirectory: URL?,
        write: (URL) throws -> Void
    ) throws {
        guard let baseDir = pendingDirectory(in: baseDirectory) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "App Group container unavailable",
            ])
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let itemID = UUID().uuidString
        let stagingDirectory = baseDir.appendingPathComponent(".\(itemID).staging", isDirectory: true)
        let publishedDirectory = baseDir.appendingPathComponent(itemID, isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        // Harden the queued item directory so its clip-bearing files are
        // unreadable while the device is locked. `.completeUnlessOpen` lets an
        // already-open handle keep working across a lock. Best-effort; iOS-only
        // because this file also compiles for macOS, which has no such API.
        #if os(iOS)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: stagingDirectory.path
            )
        #endif

        do {
            try write(stagingDirectory)
            // Publishing is one same-directory rename, so the reader can see
            // either no item or the complete item, never a partial payload.
            try fileManager.moveItem(at: stagingDirectory, to: publishedDirectory)
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    private static func writeManifest(_ manifest: Manifest, in baseDirectory: URL?) throws {
        try publishItem(in: baseDirectory) { directory in
            let data = try JSONEncoder().encode(manifest)
            try writeProtected(data, to: directory.appendingPathComponent(manifestFilename))
        }
    }

    /// Writes `data` with file-level data protection so the on-disk clip is
    /// unreadable while the device is locked. `.completeFileProtectionUnlessOpen`
    /// mirrors the directory protection above. iOS-only; the writing option is
    /// meaningless on macOS, which also compiles this file.
    private static func writeProtected(_ data: Data, to url: URL) throws {
        #if os(iOS)
            try data.write(to: url, options: [.completeFileProtectionUnlessOpen])
        #else
            try data.write(to: url)
        #endif
    }
}
