import Foundation

/// Lightweight file-based queue for passing items into the main app from the
/// share extension without opening the database. Items are written as files
/// in the App Group container and picked up by the main app on activation.
public enum PendingShareQueue {
    private static let pendingDirName = "pending"
    private static let manifestFilename = "manifest.json"
    private static let imageFilename = "image.bin"
    private static let thumbnailFilename = "thumbnail.bin"

    /// Shared ceilings for producers and consumers of the App Group queue.
    /// Keeping them in the core module prevents the share extension and main
    /// app from silently accepting different amounts of untrusted data.
    public enum Limits {
        public static let maximumItemCount = 50
        public static let maximumTextByteCount = 10 * 1024 * 1024
        public static let maximumImageByteCount = 50 * 1024 * 1024
        public static let maximumAggregateByteCount = 50 * 1024 * 1024
        public static let maximumThumbnailByteCount = 1024 * 1024
        public static let maximumManifestByteCount = maximumTextByteCount + (64 * 1024)
    }

    /// Rejections happen before a staging directory is created, so a caller
    /// cannot leave an unreadable or permanently over-budget queue item behind.
    public enum EnqueueError: Error, Equatable, Sendable {
        case itemTooLarge
        case aggregateTooLarge
        case metadataTooLarge
    }

    // MARK: - Item Model

    private enum Manifest: Codable {
        case text(String)
        case url(String)
        case image(isAnimated: Bool)

        private enum CodingKeys: String, CodingKey {
            case type, text, url, isAnimated
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
                // Queues written before animation metadata was added remain
                // readable. The main app validates the actual bytes again and
                // treats this value as advisory defense-in-depth metadata.
                self = try .image(
                    isAnimated: container.decodeIfPresent(
                        Bool.self,
                        forKey: .isAnimated
                    ) ?? false
                )
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
            case let .image(isAnimated):
                try container.encode("image", forKey: .type)
                try container.encode(isAnimated, forKey: .isAnimated)
            }
        }
    }

    /// A pending item keeps its durable queue identity separate from the
    /// payload variant so callers can acknowledge it only after persistence.
    public struct PendingItem: Sendable {
        public let id: UUID
        public let payload: Payload
    }

    public enum Payload: Sendable {
        case text(String)
        case url(String)
        case image(data: Data, thumbnail: Data?, isAnimated: Bool)
    }

    // MARK: - Enqueue (extensions)

    public static func enqueueText(
        _ text: String,
        in baseDirectory: URL? = nil
    ) throws {
        guard text.utf8.count <= Limits.maximumTextByteCount else {
            throw EnqueueError.itemTooLarge
        }
        guard serializedStringManifestFits(text) else {
            throw EnqueueError.metadataTooLarge
        }
        try writeManifest(.text(text), in: baseDirectory)
    }

    public static func enqueueURL(
        _ url: String,
        in baseDirectory: URL? = nil
    ) throws {
        guard url.utf8.count <= Limits.maximumTextByteCount else {
            throw EnqueueError.itemTooLarge
        }
        guard serializedStringManifestFits(url) else {
            throw EnqueueError.metadataTooLarge
        }
        try writeManifest(.url(url), in: baseDirectory)
    }

    public static func enqueueImage(
        imageData: Data,
        thumbnail: Data?,
        isAnimated: Bool = false,
        in baseDirectory: URL? = nil
    ) throws {
        guard imageData.count <= Limits.maximumImageByteCount,
              (thumbnail?.count ?? 0) <= Limits.maximumThumbnailByteCount
        else {
            throw EnqueueError.itemTooLarge
        }
        let thumbnailByteCount = thumbnail?.count ?? 0
        guard imageData.count <= Limits.maximumAggregateByteCount,
              thumbnailByteCount <= Limits.maximumAggregateByteCount - imageData.count
        else {
            throw EnqueueError.aggregateTooLarge
        }

        let manifestData = try encodedManifest(.image(isAnimated: isAnimated))
        try publishItem(in: baseDirectory) { directory in
            try writeProtected(
                manifestData,
                to: directory.appendingPathComponent(manifestFilename)
            )
            try writeProtected(imageData, to: directory.appendingPathComponent(imageFilename))
            if let thumbnail {
                try writeProtected(thumbnail, to: directory.appendingPathComponent(thumbnailFilename))
            }
        }
    }

    // MARK: - Dequeue (main app)

    /// Reads all durable pending items without removing them. Call
    /// `acknowledge` only after the item has been persisted successfully.
    public static func loadAll(in baseDirectory: URL? = nil) -> [PendingItem] {
        guard !currentTaskIsCancelled else { return [] }
        guard let baseDir = pendingDirectory(in: baseDirectory) else { return [] }
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseDir.path) else { return [] }

        guard let entries = try? fm.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: nil
        ).sorted(by: { lhs, rhs in
            lhs.lastPathComponent < rhs.lastPathComponent
        }) else { return [] }

        var results: [PendingItem] = []
        results.reserveCapacity(min(entries.count, Limits.maximumItemCount))
        var batchPayloadByteCount = 0

        // UUID-named directories are complete, atomically published items.
        // Dot-prefixed staging directories belong to an active or interrupted
        // writer and must never be consumed as corrupt input.
        for itemDir in entries {
            guard !currentTaskIsCancelled else { break }
            guard results.count < Limits.maximumItemCount else { break }
            guard let itemID = UUID(uuidString: itemDir.lastPathComponent) else { continue }
            let manifestURL = itemDir.appendingPathComponent(manifestFilename)
            guard let manifestData = readBoundedFile(
                at: manifestURL,
                maximumByteCount: Limits.maximumManifestByteCount,
                fileManager: fm
            ),
                !currentTaskIsCancelled,
                let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData)
            else {
                // Reads can fail transiently while protected files are locked.
                // Only an explicit acknowledgement may remove a published item.
                continue
            }

            let payload: Payload
            let payloadByteCount: Int
            switch manifest {
            case let .text(text):
                let textByteCount = text.utf8.count
                guard textByteCount <= Limits.maximumTextByteCount,
                      batchPayloadByteCount <= Limits.maximumAggregateByteCount - textByteCount
                else { continue }
                payload = .text(text)
                payloadByteCount = textByteCount
            case let .url(url):
                let urlByteCount = url.utf8.count
                guard urlByteCount <= Limits.maximumTextByteCount,
                      batchPayloadByteCount <= Limits.maximumAggregateByteCount - urlByteCount
                else { continue }
                payload = .url(url)
                payloadByteCount = urlByteCount
            case let .image(isAnimated):
                let remainingBatchBytes = Limits.maximumAggregateByteCount - batchPayloadByteCount
                guard let imageData = readBoundedFile(
                    at: itemDir.appendingPathComponent(imageFilename),
                    maximumByteCount: min(Limits.maximumImageByteCount, remainingBatchBytes),
                    fileManager: fm
                ) else { continue }

                let remainingThumbnailBytes = remainingBatchBytes - imageData.count
                let thumbnail = readBoundedFile(
                    at: itemDir.appendingPathComponent(thumbnailFilename),
                    maximumByteCount: min(
                        Limits.maximumThumbnailByteCount,
                        remainingThumbnailBytes
                    ),
                    fileManager: fm
                )
                payload = .image(
                    data: imageData,
                    thumbnail: thumbnail,
                    isAnimated: isAnimated
                )
                payloadByteCount = imageData.count + (thumbnail?.count ?? 0)
            }

            results.append(PendingItem(id: itemID, payload: payload))
            batchPayloadByteCount += payloadByteCount
        }

        return results
    }

    /// Removes one successfully persisted item from the durable queue.
    public static func acknowledge(_ item: PendingItem, in baseDirectory: URL? = nil) {
        guard let baseDir = pendingDirectory(in: baseDirectory) else { return }
        let fm = FileManager.default
        let itemDirectory = baseDir.appendingPathComponent(item.id.uuidString, isDirectory: true)
        try? fm.removeItem(at: itemDirectory)
    }

    // MARK: - Private

    private static var currentTaskIsCancelled: Bool {
        withUnsafeCurrentTask { task in
            task?.isCancelled == true
        }
    }

    /// Reads an immutable published queue file without trusting its contents or
    /// allocating beyond the caller's budget. The second size check catches a
    /// file replaced or changed between metadata preflight and the bounded read.
    private static func readBoundedFile(
        at url: URL,
        maximumByteCount: Int,
        fileManager: FileManager
    ) -> Data? {
        guard maximumByteCount >= 0,
              !currentTaskIsCancelled,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let sizeNumber = attributes[.size] as? NSNumber
        else { return nil }

        let size = sizeNumber.uint64Value
        guard size <= UInt64(maximumByteCount), size < UInt64(Int.max) else {
            return nil
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let expectedByteCount = Int(size)
        guard let data = try? handle.read(upToCount: expectedByteCount + 1),
              data.count == expectedByteCount,
              !currentTaskIsCancelled
        else { return nil }
        return data
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
        let data = try encodedManifest(manifest)
        try publishItem(in: baseDirectory) { directory in
            try writeProtected(data, to: directory.appendingPathComponent(manifestFilename))
        }
    }

    private static func encodedManifest(_ manifest: Manifest) throws -> Data {
        let data = try JSONEncoder().encode(manifest)
        guard data.count <= Limits.maximumManifestByteCount else {
            throw EnqueueError.metadataTooLarge
        }
        return data
    }

    /// Preflights JSON string escaping without allocating the encoded
    /// manifest. `JSONEncoder` can expand control-heavy text many times over;
    /// rejecting that expansion first keeps the encoder itself inside the same
    /// bounded memory envelope as the file writer.
    private static func serializedStringManifestFits(_ value: String) -> Bool {
        // Covers JSON punctuation, both keys, and their type discriminators.
        var byteCount = 128
        for scalar in value.unicodeScalars {
            let codePoint = scalar.value
            let scalarByteCount: Int
            if codePoint <= 0x1F || codePoint == 0x2028 || codePoint == 0x2029 {
                scalarByteCount = 6
            } else if codePoint == 0x22 || codePoint == 0x2F || codePoint == 0x5C {
                scalarByteCount = 2
            } else if codePoint <= 0x7F {
                scalarByteCount = 1
            } else if codePoint <= 0x7FF {
                scalarByteCount = 2
            } else if codePoint <= 0xFFFF {
                scalarByteCount = 3
            } else {
                scalarByteCount = 4
            }
            guard byteCount <= Limits.maximumManifestByteCount - scalarByteCount else {
                return false
            }
            byteCount += scalarByteCount
        }
        return true
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
