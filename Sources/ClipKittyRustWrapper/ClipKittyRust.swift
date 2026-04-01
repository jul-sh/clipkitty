// ClipKittyRust Swift Extensions
// Manual extensions for UniFFI-generated types from purr
// Provides: Date conversions, UTType mappings, Identifiable/Sendable conformances

import Foundation
import Foundation
import UniformTypeIdentifiers

// MARK: - ClipboardItem Extensions

extension ClipboardItem {
    @MainActor
    private static let timeAgoFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    @MainActor
    public var timeAgo: String {
        let timestamp = Date(timeIntervalSince1970: TimeInterval(itemMetadata.timestampUnix))
        return Self.timeAgoFormatter.localizedString(for: timestamp, relativeTo: Date())
    }
}

// MARK: - IconType Extensions

public extension IconType {
    /// SF Symbol name for each icon type
    var sfSymbolName: String {
        switch self {
        case .text: return "doc.text"
        case .link: return "link"
        case .image: return "photo"
        case .color: return "paintpalette"
        case .file: return "doc"
        }
    }

    /// UTType for the content (used for system icons)
    var utType: UTType {
        switch self {
        case .text: return .text
        case .link: return .url
        case .image: return .image
        case .color: return .text
        case .file: return .fileURL
        }
    }
}

// MARK: - ItemMatch Extensions

// MARK: - ClipboardContent Extensions

public extension ClipboardContent {
    /// The searchable/displayable text content
    var textContent: String {
        switch self {
        case let .text(value):
            return value
        case let .color(value):
            return value
        case let .link(url, _):
            return url
        case let .image(_, description, _):
            // Avoid "Image: Image" when using the default description
            if description == "Image" {
                return String(localized: "Image")
            }
            return "\(String(localized: "Image:")) \(description)"
        case let .file(displayName, _):
            return displayName
        }
    }
}

// MARK: - Utf16HighlightRange Extensions

public extension Utf16HighlightRange {
    var nsRange: NSRange {
        NSRange(location: Int(utf16Start), length: Int(utf16End - utf16Start))
    }
}

// MARK: - FileStatus Extensions

public extension FileStatus {
    /// Convert to database string representation (mirrors Rust's to_database_str)
    func toDatabaseStr() -> String {
        switch self {
        case .available:
            return "available"
        case let .moved(newPath):
            return "moved:\(newPath)"
        case .trashed:
            return "trashed"
        case .missing:
            return "missing"
        }
    }
}

// MARK: - Protocol Conformances

extension ClipboardItem: Identifiable {
    public var id: Int64 { itemMetadata.itemId }
}

extension ItemMetadata: Identifiable {
    public var id: Int64 { itemId }
}

extension ItemMatch: Identifiable {
    public var id: Int64 { itemMetadata.itemId }
}
