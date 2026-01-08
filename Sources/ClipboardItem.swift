import Foundation
import GRDB

/// Content type for clipboard items
enum ContentType: String, Codable, DatabaseValueConvertible {
    case text
    case link
    case image

    var icon: String {
        switch self {
        case .text: return "doc.text"
        case .link: return "link"
        case .image: return "photo"
        }
    }
}

struct ClipboardItem: Identifiable, Sendable, Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "items"

    var id: Int64?
    let content: String
    let contentHash: String
    let timestamp: Date
    let sourceApp: String?
    let contentType: ContentType
    let imageData: Data?

    // Link metadata (for URLs)
    var linkTitle: String?
    var linkImageData: Data?

    // Stable identifier for SwiftUI - uses contentHash as fallback when id is nil
    var stableId: String {
        if let id = id {
            return String(id)
        }
        return contentHash
    }

    init(content: String, sourceApp: String? = nil, contentType: ContentType? = nil, imageData: Data? = nil, linkTitle: String? = nil, linkImageData: Data? = nil) {
        self.id = nil
        self.content = content
        self.contentHash = ClipboardItem.hash(content)
        self.timestamp = Date()
        self.sourceApp = sourceApp
        self.imageData = imageData
        self.linkTitle = linkTitle
        self.linkImageData = linkImageData

        // Auto-detect content type if not provided
        if let type = contentType {
            self.contentType = type
        } else if imageData != nil {
            self.contentType = .image
        } else if ClipboardItem.isURL(content) {
            self.contentType = .link
        } else {
            self.contentType = .text
        }
    }

    static func isURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return false }
        return url.scheme == "http" || url.scheme == "https" ||
               trimmed.hasPrefix("www.") || trimmed.contains("://")
    }

    var displayText: String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let singleLine = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  ", with: " ")

        if singleLine.count > 200 {
            return String(singleLine.prefix(200)) + "…"
        }
        return singleLine
    }

    var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }

    var contentPreview: String {
        if content.count > 10000 {
            return String(content.prefix(10000)) + "\n\n[Content truncated - \(content.count) characters total]"
        }
        return content
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    private static func hash(_ string: String) -> String {
        var hasher = Hasher()
        hasher.combine(string)
        return String(hasher.finalize())
    }
}

struct ClipboardItemFTS: TableRecord {
    static let databaseTableName = "items_fts"
}
