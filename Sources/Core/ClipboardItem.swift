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

    /// Database field values: (content, imageData, linkTitle, linkImageData)
    /// Extracts the appropriate fields for each content type
    var databaseFields: (String, Data?, String?, Data?) {
        switch self {
        case .text(let text):
            return (text, nil, nil, nil)
        case .link(let url, let metadataState):
            // Encode metadata state: nil = pending, empty = failed, value = loaded
            let (title, imageData): (String?, Data?) = metadataState.databaseFields
            return (url, nil, title, imageData)
        case .email(let address):
            return (address, nil, nil, nil)
        case .phone(let number):
            return (number, nil, nil, nil)
        case .address(let address):
            return (address, nil, nil, nil)
        case .date(let dateString):
            return (dateString, nil, nil, nil)
        case .transit(let transitInfo):
            return (transitInfo, nil, nil, nil)
        case .image(let data, let description):
            return (description, data, nil, nil)
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
            let metadataState = LinkMetadataState.fromDatabase(title: linkTitle, imageData: linkImageData)
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

/// Metadata fetch state for links - distinguishes between not-yet-fetched, loaded, and failed
/// Uses sum type to make invalid states unrepresentable
public enum LinkMetadataState: Sendable, Equatable {
    case pending
    case loaded(title: String?, imageData: Data?)
    case failed

    /// Convenience accessor for loaded metadata
    public var title: String? {
        switch self {
        case .loaded(let title, _):
            return title
        case .pending, .failed:
            return nil
        }
    }

    public var imageData: Data? {
        switch self {
        case .loaded(_, let imageData):
            return imageData
        case .pending, .failed:
            return nil
        }
    }

    /// Check if metadata has any content
    public var hasContent: Bool {
        if case .loaded(let title, let imageData) = self {
            return title != nil || imageData != nil
        }
        return false
    }

    /// Database encoding: nil title = pending, empty title with no image = failed, otherwise = loaded
    public var databaseFields: (String?, Data?) {
        switch self {
        case .pending:
            return (nil, nil)
        case .failed:
            return ("", nil)
        case .loaded(let title, let imageData):
            return (title ?? "", imageData)
        }
    }

    public static func fromDatabase(title: String?, imageData: Data?) -> LinkMetadataState {
        switch (title, imageData) {
        case (nil, nil):
            return .pending
        case ("", nil):
            return .failed
        case (let title, let imageData):
            return .loaded(title: title?.isEmpty == true ? nil : title, imageData: imageData)
        }
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
        let description = "Image"
        self.id = nil
        self.contentHash = Self.hash(description + String(imageData.hashValue))
        self.timestamp = timestamp
        self.sourceApp = sourceApp
        self.content = .image(data: imageData, description: description)
    }

    /// Initializer with explicit content - used for in-place updates
    public init(
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
        let text = textContent
        let maxChars = 200
        var result = String()
        result.reserveCapacity(maxChars + 1)

        var index = text.startIndex
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }

        var count = 0
        var lastWasSpace = false
        var hasMore = false

        while index < text.endIndex, count < maxChars {
            var character = text[index]
            if character == "\n" || character == "\t" || character == "\r" {
                character = " "
            }
            if character == " " {
                if lastWasSpace {
                    index = text.index(after: index)
                    continue
                }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }

            result.append(character)
            count += 1
            index = text.index(after: index)
        }

        if index < text.endIndex {
            hasMore = true
        }

        return hasMore ? result + "…" : result
    }

    @MainActor
    private static let timeAgoFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    @MainActor
    public var timeAgo: String {
        Self.timeAgoFormatter.localizedString(for: timestamp, relativeTo: Date())
    }

    public var contentPreview: String {
        textContent
    }

    public var searchPreview: String {
        let text = textContent
        let maxChars = 10000
        if let endIndex = text.index(text.startIndex, offsetBy: maxChars, limitedBy: text.endIndex) {
            let preview = String(text[..<endIndex])
            if endIndex < text.endIndex {
                return preview + "\n\n[Content truncated]"
            }
            return preview
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

        // Extract content-specific fields based on content type
        let (text, imageData, linkTitle, linkImageData) = content.databaseFields
        container["content"] = text
        container["imageData"] = imageData
        container["linkTitle"] = linkTitle
        container["linkImageData"] = linkImageData
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
