// ClipKittyRust Swift Extensions
//
// Swift-specific extensions that cannot be implemented in Rust:
// - RelativeDateTimeFormatter for timeAgo
// - UTType mappings
// - Sendable/Identifiable conformances
// - Swift Data type conversions
//
// ┌─────────────────────────────────────────────────────────────────────────────┐
// │ DEPENDENCY MAP - Update these files together:                               │
// │                                                                             │
// │ rust-core/src/clipkitty_core.udl    ← FFI type definitions (source of truth)│
// │   ↓ generates via UniFFI                                                    │
// │ Sources/ClipKittyRustWrapper/clipkitty_core.swift  ← Auto-generated types   │
// │   ↓ extended by                                                             │
// │ THIS FILE (ClipKittyRust.swift)     ← Manual Swift extensions               │
// │                                                                             │
// │ When modifying:                                                             │
// │ • Add/remove enum case in .udl → Update switch statements below             │
// │ • Add/remove struct field in .udl → Update property accessors below         │
// │ • Add new type in .udl → Add Sendable conformance at bottom                 │
// │ • Rename type in .udl → Update extension declarations below                 │
// └─────────────────────────────────────────────────────────────────────────────┘

import Foundation
import UniformTypeIdentifiers
import AppKit

// MARK: - ClipboardItem Extensions
// Extends: ClipboardItem from clipkitty_core.udl

extension ClipboardItem {
    /// Convert Unix timestamp to Date
    public var timestamp: Date {
        Date(timeIntervalSince1970: TimeInterval(itemMetadata.timestampUnix))
    }


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

    /// Stable identifier for SwiftUI
    public var stableId: String {
        String(itemMetadata.itemId)
    }

    /// Display text with whitespace normalization and truncation
    public var displayText: String {
        let text = itemMetadata.preview
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
}

// MARK: - ItemMetadata Extensions
// Extends: ItemMetadata from clipkitty_core.udl

extension ItemMetadata {
    /// Convert Unix timestamp to Date
    public var timestamp: Date {
        Date(timeIntervalSince1970: TimeInterval(timestampUnix))
    }

    /// Convenience accessor for source app bundle ID (Swift naming convention)
    public var sourceAppBundleID: String? {
        sourceAppBundleId
    }

    /// Stable identifier for SwiftUI
    public var stableId: String {
        String(itemId)
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
}

// MARK: - ItemIcon Extensions
// Extends: ItemIcon from clipkitty_core.udl

extension ItemIcon {
    /// Get the SF Symbol name for this icon
    public var sfSymbolName: String? {
        switch self {
        case .symbol(let iconType):
            return iconType.sfSymbolName
        case .colorSwatch, .thumbnail:
            return nil
        }
    }

    /// Get color from RGBA value for color swatches
    public var swatchColor: NSColor? {
        guard case .colorSwatch(let rgba) = self else { return nil }
        let r = CGFloat((rgba >> 24) & 0xFF) / 255.0
        let g = CGFloat((rgba >> 16) & 0xFF) / 255.0
        let b = CGFloat((rgba >> 8) & 0xFF) / 255.0
        let a = CGFloat(rgba & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: a)
    }

    /// Get thumbnail image from bytes
    public var thumbnailImage: NSImage? {
        guard case .thumbnail(let bytes) = self else { return nil }
        return NSImage(data: Data(bytes))
    }
}

// MARK: - IconType Extensions
// Extends: IconType from clipkitty_core.udl

extension IconType {
    /// SF Symbol name for each icon type
    public var sfSymbolName: String {
        switch self {
        case .text: return "doc.text"
        case .link: return "link"
        case .email: return "envelope"
        case .phone: return "phone"
        case .address: return "map"
        case .dateType: return "calendar"
        case .transit: return "tram"
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
        case .address: return .vCard
        case .dateType: return .calendarEvent
        case .transit: return .text
        case .image: return .image
        case .color: return .text
        }
    }
}

// MARK: - ItemMatch Extensions
// Extends: ItemMatch from clipkitty_core.udl

extension ItemMatch {
    /// Convenience accessor for item ID
    public var itemId: Int64 {
        itemMetadata.itemId
    }

    /// Stable identifier for SwiftUI
    public var stableId: String {
        itemMetadata.stableId
    }
}

// MARK: - ClipboardContent Extensions
// Extends: ClipboardContent from clipkitty_core.udl
// SYNC: Case names must match .udl enum variants exactly

extension ClipboardContent {
    /// Get image data as Swift Data type
    public var imageDataAsData: Data? {
        if case .image(let data, _) = self {
            return Data(data)
        }
        return nil
    }

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
        case .address(let value):
            return value
        case .date(let value):
            return value
        case .transit(let value):
            return value
        case .image(_, let description):
            return description
        }
    }

    public var icon: String {
        switch self {
        case .text: return "doc.text"
        case .color: return "paintpalette"
        case .link: return "link"
        case .email: return "envelope"
        case .phone: return "phone"
        case .address: return "map"
        case .date: return "calendar"
        case .transit: return "tram"
        case .image: return "photo"
        }
    }

    /// UTType for the content (used for system icons)
    public var utType: UTType {
        switch self {
        case .text: return .text
        case .color: return .text
        case .link: return .url
        case .email: return .emailMessage
        case .phone: return .vCard
        case .address: return .vCard
        case .date: return .calendarEvent
        case .transit: return .text
        case .image: return .image
        }
    }
}

// MARK: - LinkMetadataState Extensions
// Extends: LinkMetadataState from clipkitty_core.udl
// SYNC: Case names must match .udl enum variants exactly

extension LinkMetadataState {
    /// Convenience accessor for loaded metadata title
    public var title: String? {
        switch self {
        case .loaded(let title, _, _):
            return title
        case .pending, .failed:
            return nil
        }
    }

    /// Convenience accessor for loaded metadata description
    public var description: String? {
        switch self {
        case .loaded(_, let description, _):
            return description
        case .pending, .failed:
            return nil
        }
    }

    /// Convenience accessor for loaded metadata image data as Swift Data
    public var imageData: Data? {
        switch self {
        case .loaded(_, _, let imageData):
            return imageData.map { Data($0) }
        case .pending, .failed:
            return nil
        }
    }

    /// Convert to database storage format (title, description, imageData)
    public var databaseFields: (String?, String?, Data?) {
        switch self {
        case .pending:
            return (nil, nil, nil)
        case .failed:
            return ("", nil, nil)
        case .loaded(let title, let description, let imageData):
            return (title, description, imageData.map { Data($0) })
        }
    }

    /// Check if metadata has any content
    public var hasContent: Bool {
        if case .loaded(let title, let description, let imageData) = self {
            return title != nil || description != nil || imageData != nil
        }
        return false
    }
}

// MARK: - HighlightRange Extensions
// Extends: HighlightRange from clipkitty_core.udl

extension HighlightRange {
    /// Convert to NSRange for use with NSAttributedString
    public var nsRange: NSRange {
        NSRange(location: Int(start), length: Int(end - start))
    }
}

// MARK: - Protocol Conformances
// SYNC: Add Sendable conformance for any new type added to clipkitty_core.udl
// Note: UniFFI already generates Sendable conformances for most types in Swift 6+,
// but we add @unchecked Sendable for older Swift versions and consistency

// Note: Identifiable conformance with `id` property
// ClipboardItem, ItemMetadata, and ItemMatch all use itemId as identifier

extension ClipboardItem: Identifiable {
    public var id: Int64 { itemMetadata.itemId }
}

extension ItemMetadata: Identifiable {
    public var id: Int64 { itemId }
}

extension ItemMatch: Identifiable {
    public var id: Int64 { itemMetadata.itemId }
}

// Note: ClipboardStore already declares Sendable conformance in the generated file
