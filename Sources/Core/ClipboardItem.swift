import Foundation
import GRDB

// MARK: - Content Types with Associated Data

/// Type-safe content representation that ensures only valid states are possible
public enum ClipboardContent: Sendable, Equatable {
    case text(String)
    case link(url: String, metadataState: LinkMetadataState)
    case email(address: String)
    case phone(number: String)
    case address(String)
    case date(String)
    case transit(String)
    case image(data: Data, description: String)

    /// The searchable/displayable text content
    public var textContent: String {
        switch self {
        case .text(let text):
            return text
        case .link(let url, _):
            return url
        case .email(let address):
            return address
        case .phone(let number):
            return number
        case .address(let address):
            return address
        case .date(let dateString):
            return dateString
        case .transit(let transitInfo):
            return transitInfo
        case .image(_, let description):
            return description
        }
    }

    public var icon: String {
        switch self {
        case .text: return "doc.text"
        case .link: return "link"
        case .email: return "envelope"
        case .phone: return "phone"
        case .address: return "map"
        case .date: return "calendar"
        case .transit: return "tram"
        case .image: return "photo"
        }
    }

    /// Database storage type string
    var databaseType: String {
        switch self {
        case .text: return "text"
        case .link: return "link"
        case .email: return "email"
        case .phone: return "phone"
        case .address: return "address"
        case .date: return "date"
        case .transit: return "transit"
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
            // nil = pending (never fetched)
            // empty string with no image = failed (fetched but no data)
            // non-empty or has image = loaded
            if let title = linkTitle {
                if title.isEmpty && linkImageData == nil {
                    metadataState = .failed
                } else {
                    metadataState = .loaded(LinkMetadata(title: title.isEmpty ? nil : title, imageData: linkImageData))
                }
            } else {
                metadataState = .pending
            }
            return .link(url: content, metadataState: metadataState)
        case "image":
            return .image(data: imageData ?? Data(), description: content)
        case "email":
            return .email(address: content)
        case "phone":
            return .phone(number: content)
        case "address":
            return .address(content)
        case "date":
            return .date(content)
        case "transit":
            return .transit(content)
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

}

/// Metadata content for links
public struct LinkMetadata: Sendable, Equatable, Codable {
    public let title: String?
    public let imageData: Data?

    public init(title: String?, imageData: Data?) {
        self.title = title
        self.imageData = imageData
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

    /// Stable identifier for SwiftUI
    public var stableId: String {
        if let id = id {
            return String(id)
        }
        return contentHash
    }

    // MARK: - Initialization

    /// Create a text item (auto-detects common structured content)
    public init(text: String, sourceApp: String? = nil, timestamp: Date = Date()) {
        self.id = nil
        self.contentHash = Self.hash(text)
        self.timestamp = timestamp
        self.sourceApp = sourceApp
        self.content = Self.detectContent(from: text)
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

    private static func detectContent(from text: String) -> ClipboardContent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(location: 0, length: trimmed.utf16.count)

        if let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue |
                NSTextCheckingResult.CheckingType.phoneNumber.rawValue |
                NSTextCheckingResult.CheckingType.date.rawValue |
                NSTextCheckingResult.CheckingType.address.rawValue |
                NSTextCheckingResult.CheckingType.transitInformation.rawValue
        ),
           let match = detector.firstMatch(in: trimmed, options: [], range: range),
           match.range.length == range.length {
            if match.resultType == .link, let url = match.url {
                if url.scheme == "mailto" {
                    let address: String = {
                        if !url.path.isEmpty {
                            return url.path
                        }
                        let raw = url.absoluteString
                        if raw.lowercased().hasPrefix("mailto:") {
                            let withoutScheme = String(raw.dropFirst("mailto:".count))
                            return withoutScheme.split(separator: "?", maxSplits: 1).first.map(String.init) ?? trimmed
                        }
                        return trimmed
                    }()
                    return .email(address: address)
                }
                if isURL(trimmed) {
                    return .link(url: trimmed, metadataState: .pending)
                }
            }

            if match.resultType == .phoneNumber, let number = match.phoneNumber {
                return .phone(number: number)
            }

            if match.resultType == .date, match.date != nil {
                return .date(trimmed)
            }

            if match.resultType == .address, match.addressComponents != nil {
                return .address(trimmed)
            }

            if match.resultType == .transitInformation {
                return .transit(trimmed)
            }
        }

        return .text(text)
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

        case .email(let address):
            container["content"] = address
            container["imageData"] = nil as Data?
            container["linkTitle"] = nil as String?
            container["linkImageData"] = nil as Data?

        case .phone(let number):
            container["content"] = number
            container["imageData"] = nil as Data?
            container["linkTitle"] = nil as String?
            container["linkImageData"] = nil as Data?

        case .address(let address):
            container["content"] = address
            container["imageData"] = nil as Data?
            container["linkTitle"] = nil as String?
            container["linkImageData"] = nil as Data?

        case .date(let dateString):
            container["content"] = dateString
            container["imageData"] = nil as Data?
            container["linkTitle"] = nil as String?
            container["linkImageData"] = nil as Data?

        case .transit(let transitInfo):
            container["content"] = transitInfo
            container["imageData"] = nil as Data?
            container["linkTitle"] = nil as String?
            container["linkImageData"] = nil as Data?

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

// MARK: - FTS Table

public struct ClipboardItemFTS: TableRecord {
    public static let databaseTableName = "items_fts"
}
