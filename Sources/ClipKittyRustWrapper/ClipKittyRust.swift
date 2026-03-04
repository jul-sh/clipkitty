// ClipKittyRust Swift Extensions
// Manual extensions for UniFFI-generated types from purr
// Provides: Date conversions, UTType mappings, Identifiable/Sendable conformances

import Foundation
import UniformTypeIdentifiers
import AppKit

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

extension IconType {
    /// SF Symbol name for each icon type
    public var sfSymbolName: String {
        switch self {
        case .text: return "doc.text"
        case .link: return "link"
        case .image: return "photo"
        case .color: return "paintpalette"
        case .file: return "doc"
        }
    }

    /// UTType for the content (used for system icons)
    public var utType: UTType {
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

extension ClipboardContent {
    /// The searchable/displayable text content
    public var textContent: String {
        switch self {
        case .text(let value):
            return value
        case .color(let value):
            return value
        case .link(let url, _):
            return url
        case .image(_, let description, _):
            // Avoid "Image: Image" when using the default description
            if description == "Image" {
                return String(localized: "Image")
            }
            return "\(String(localized: "Image:")) \(description)"
        case .file(let displayName, _):
            return displayName
        }
    }
}

// MARK: - HighlightRange Extensions

extension HighlightRange {
    /// Convert to NSRange for use with NSAttributedString.
    /// IMPORTANT: Rust returns char indices (Unicode scalar values), but NSString/NSAttributedString
    /// uses UTF-16 code units. For ASCII text they're the same, but for text with emojis or other
    /// characters outside the BMP (Basic Multilingual Plane), they differ.
    /// Use `nsRange(in:)` instead for correct handling of Unicode text.
    @available(*, deprecated, message: "Use nsRange(in:) for correct Unicode handling")
    public var nsRange: NSRange {
        NSRange(location: Int(start), length: Int(end - start))
    }

    /// Convert Rust char indices to NSRange (UTF-16 code unit indices) for the given text.
    /// This correctly handles emojis and other characters that take 2 UTF-16 code units.
    public func nsRange(in text: String) -> NSRange {
        let scalars = Array(text.unicodeScalars)
        let startIdx = Int(start)
        let endIdx = Int(end)

        // Bounds check against Unicode scalar count (matches Rust's .chars() counting)
        guard startIdx >= 0, endIdx <= scalars.count, startIdx <= endIdx else {
            return NSRange(location: NSNotFound, length: 0)
        }

        // Convert scalar index to UTF-16 index by summing UTF-16 lengths of preceding scalars
        var utf16Start = 0
        for i in 0..<startIdx {
            utf16Start += scalars[i].utf16.count
        }

        var utf16Length = 0
        for i in startIdx..<endIdx {
            utf16Length += scalars[i].utf16.count
        }

        return NSRange(location: utf16Start, length: utf16Length)
    }
}

// MARK: - FileStatus Extensions

extension FileStatus {
    /// Convert to database string representation (mirrors Rust's to_database_str)
    public func toDatabaseStr() -> String {
        switch self {
        case .available:
            return "available"
        case .moved(let newPath):
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
