import Foundation
import GRDB

// MARK: - Content Types with Associated Data

/// Type-safe content representation that ensures only valid states are possible
public enum ClipboardContent: Sendable, Equatable {
    case text(String)
    case link(url: String, metadataState: LinkMetadataState)
    case image(data: Data, description: String)

    /// The searchable/displayable text content
    public var textContent: String {
        switch self {
        case .text(let text):
            return text
        case .link(let url, _):
            return url
        case .image(_, let description):
            return description
        }
    }

    public var icon: String {
        switch self {
        case .text: return "doc.text"
        case .link: return "link"
        case .image: return "photo"
        }
    }

    /// Database storage type string
    var databaseType: String {
        switch self {
        case .text: return "text"
        case .link: return "link"
        case .image: return "image"
        }
    }

    /// Reconstruct from database row
    static func from(
        databaseType: String,
        content: String,
        imageData: Data?,
        linkTitle: String?,
        linkImageData: Data?
    ) -> ClipboardContent {
        switch databaseType {
        case "link":
            let metadataState: LinkMetadataState
            if linkTitle != nil || linkImageData != nil {
                metadataState = .loaded(LinkMetadata(title: linkTitle, imageData: linkImageData))
            } else {
                metadataState = .pending
            }
            return .link(url: content, metadataState: metadataState)
        case "image":
            return .image(data: imageData ?? Data(), description: content)
        default:
            return .text(content)
        }
    }
}

/// Metadata fetch state for links - distinguishes between not-yet-fetched, loading, loaded, and failed
public enum LinkMetadataState: Sendable, Equatable {
    case pending
    case loaded(LinkMetadata)
    case failed

    public var metadata: LinkMetadata? {
        if case .loaded(let metadata) = self {
            return metadata
        }
        return nil
    }

    public var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    public var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}

/// Metadata content for links
public struct LinkMetadata: Sendable, Equatable, Codable {
    public let title: String?
    public let imageData: Data?

    public init(title: String?, imageData: Data?) {
        self.title = title
        self.imageData = imageData
    }

    public var isEmpty: Bool {
        title == nil && imageData == nil
    }
}

// MARK: - Clipboard Item

public struct ClipboardItem: Identifiable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "items"

    public var id: Int64?
    public let content: ClipboardContent
    public let contentHash: String
    public let timestamp: Date
    public let sourceApp: String?

    // MARK: - Convenience Accessors

    /// The raw text content for searching and display
    public var textContent: String { content.textContent }

    /// Icon for the content type
    public var icon: String { content.icon }

    /// Link metadata (only available for links with loaded metadata)
    public var linkMetadata: LinkMetadata? {
        if case .link(_, let metadataState) = content {
            return metadataState.metadata
        }
        return nil
    }

    /// Image data (only available for images)
    public var imageData: Data? {
        if case .image(let data, _) = content {
            return data
        }
        return nil
    }

    /// Whether this is a link type
    public var isLink: Bool {
        if case .link = content { return true }
        return false
    }

    /// Whether this is an image type
    public var isImage: Bool {
        if case .image = content { return true }
        return false
    }

    /// Stable identifier for SwiftUI
    public var stableId: String {
        if let id = id {
            return String(id)
        }
        return contentHash
    }

    // MARK: - Initialization

    /// Create a text item (auto-detects links)
    public init(text: String, sourceApp: String? = nil, timestamp: Date = Date()) {
        self.id = nil
        self.contentHash = Self.hash(text)
        self.timestamp = timestamp
        self.sourceApp = sourceApp

        if Self.isURL(text) {
            self.content = .link(url: text, metadataState: .pending)
        } else {
            self.content = .text(text)
        }
    }

    /// Create an explicit link item
    public init(url: String, metadataState: LinkMetadataState = .pending, sourceApp: String? = nil, timestamp: Date = Date()) {
        self.id = nil
        self.contentHash = Self.hash(url)
        self.timestamp = timestamp
        self.sourceApp = sourceApp
        self.content = .link(url: url, metadataState: metadataState)
    }

    /// Create an image item
    public init(imageData: Data, sourceApp: String? = nil, timestamp: Date = Date()) {
        let description = "Image (\(imageData.count / 1024) KB)"
        self.id = nil
        self.contentHash = Self.hash(description + String(imageData.hashValue))
        self.timestamp = timestamp
        self.sourceApp = sourceApp
        self.content = .image(data: imageData, description: description)
    }

    /// Internal initializer for database reconstruction
    internal init(
        id: Int64?,
        content: ClipboardContent,
        contentHash: String,
        timestamp: Date,
        sourceApp: String?
    ) {
        self.id = id
        self.content = content
        self.contentHash = contentHash
        self.timestamp = timestamp
        self.sourceApp = sourceApp
    }

    // MARK: - Display Helpers

    public var displayText: String {
        let text = textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  ", with: " ")

        if singleLine.count > 200 {
            return String(singleLine.prefix(200)) + "…"
        }
        return singleLine
    }

    public var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }

    public var contentPreview: String {
        let text = textContent
        if text.count > 10000 {
            return String(text.prefix(10000)) + "\n\n[Content truncated - \(text.count) characters total]"
        }
        return text
    }

    // MARK: - URL Detection

    public static func isURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count < 2000, !trimmed.contains("\n") else { return false }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed) != nil
        }

        if trimmed.hasPrefix("www.") {
            return URL(string: "https://\(trimmed)") != nil
        }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return false
        }

        let range = NSRange(location: 0, length: trimmed.utf16.count)
        guard let match = detector.firstMatch(in: trimmed, options: [], range: range) else {
            return false
        }

        guard match.range.length == range.length else { return false }

        if let url = match.url {
            return url.scheme == "http" || url.scheme == "https"
        }

        return false
    }

    // MARK: - Hashing

    private static func hash(_ string: String) -> String {
        var hasher = Hasher()
        hasher.combine(string)
        return String(hasher.finalize())
    }

    // MARK: - GRDB PersistableRecord

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["contentHash"] = contentHash
        container["timestamp"] = timestamp
        container["sourceApp"] = sourceApp
        container["contentType"] = content.databaseType

        switch content {
        case .text(let text):
            container["content"] = text
            container["imageData"] = nil as Data?
            container["linkTitle"] = nil as String?
            container["linkImageData"] = nil as Data?

        case .link(let url, let metadataState):
            container["content"] = url
            container["imageData"] = nil as Data?
            container["linkTitle"] = metadataState.metadata?.title
            container["linkImageData"] = metadataState.metadata?.imageData

        case .image(let data, let description):
            container["content"] = description
            container["imageData"] = data
            container["linkTitle"] = nil as String?
            container["linkImageData"] = nil as Data?
        }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - GRDB FetchableRecord

    public init(row: Row) throws {
        id = row["id"]
        contentHash = row["contentHash"]
        timestamp = row["timestamp"]
        sourceApp = row["sourceApp"]

        content = ClipboardContent.from(
            databaseType: row["contentType"] ?? "text",
            content: row["content"],
            imageData: row["imageData"],
            linkTitle: row["linkTitle"],
            linkImageData: row["linkImageData"]
        )
    }
}

// MARK: - Mutating Link Metadata

extension ClipboardItem {
    /// Returns a copy with updated link metadata (only for link items)
    public func withLinkMetadataState(_ metadataState: LinkMetadataState) -> ClipboardItem {
        guard case .link(let url, _) = content else { return self }
        return ClipboardItem(
            id: id,
            content: .link(url: url, metadataState: metadataState),
            contentHash: contentHash,
            timestamp: timestamp,
            sourceApp: sourceApp
        )
    }
}

// MARK: - FTS Table

public struct ClipboardItemFTS: TableRecord {
    public static let databaseTableName = "items_fts"
}
