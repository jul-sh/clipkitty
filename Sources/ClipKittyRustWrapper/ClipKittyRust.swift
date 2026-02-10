// ClipKittyRust Swift Extensions
// Manual extensions for UniFFI-generated types from clipkitty_core.udl
// Provides: Date conversions, UTType mappings, Identifiable/Sendable conformances

import Foundation
import UniformTypeIdentifiers
import AppKit

// MARK: - ClipboardItem Extensions

extension ClipboardItem {
    /// Convenience accessor for source app
    public var sourceApp: String? {
        itemMetadata.sourceApp
    }

    /// Convenience accessor for source app bundle ID (Swift naming convention)
    public var sourceAppBundleID: String? {
        itemMetadata.sourceAppBundleId
    }

    /// The raw text content for searching and display
    public var textContent: String {
        content.textContent
    }

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
        case .email: return "envelope"
        case .phone: return "phone"
        case .image: return "photo"
        case .color: return "paintpalette"
        }
    }

    /// UTType for the content (used for system icons)
    public var utType: UTType {
        switch self {
        case .text: return .text
        case .link: return .url
        case .email: return .emailMessage
        case .phone: return .vCard
        case .image: return .image
        case .color: return .text
        }
    }
}

// MARK: - ItemMatch Extensions

extension ItemMatch {
    /// Convenience accessor for item ID
    public var itemId: Int64 {
        itemMetadata.itemId
    }
}

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
        case .email(let address):
            return address
        case .phone(let number):
            return number
        case .image(_, let description):
            return description
        }
    }
}

// MARK: - HighlightRange Extensions

extension HighlightRange {
    /// Convert to NSRange for use with NSAttributedString
    public var nsRange: NSRange {
        NSRange(location: Int(start), length: Int(end - start))
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
