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

// MARK: - ClipboardItem Extensions
// Extends: ClipboardItem from clipkitty_core.udl lines 30-37

extension ClipboardItem {
    /// Convert Unix timestamp to Date
    public var timestamp: Date {
        Date(timeIntervalSince1970: TimeInterval(timestampUnix))
    }

    /// Convenience accessor for source app bundle ID (Swift naming convention)
    public var sourceAppBundleID: String? {
        sourceAppBundleId
    }

    /// The raw text content for searching and display (wraps Rust method)
    public var textContent: String {
        content.textContent
    }

    /// Icon for the content type (wraps Rust method)
    public var icon: String {
        content.icon
    }

    /// Stable identifier for SwiftUI (wraps Rust method)
    public var stableId: String {
        if let id = id {
            return String(id)
        }
        return contentHash
    }

    /// Display text with whitespace normalization and truncation (wraps Rust method)
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
}

// MARK: - ClipboardContent Extensions
// Extends: ClipboardContent from clipkitty_core.udl lines 17-27
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
// Extends: LinkMetadataState from clipkitty_core.udl lines 9-14
// SYNC: Case names must match .udl enum variants exactly

extension LinkMetadataState {
    /// Convenience accessor for loaded metadata title
    public var title: String? {
        switch self {
        case .loaded(let title, _):
            return title
        case .pending, .failed:
            return nil
        }
    }

    /// Convenience accessor for loaded metadata image data as Swift Data
    public var imageData: Data? {
        switch self {
        case .loaded(_, let imageData):
            return imageData.map { Data($0) }
        case .pending, .failed:
            return nil
        }
    }

    /// Convert to database storage format (title, imageData)
    public var databaseFields: (String?, Data?) {
        switch self {
        case .pending:
            return (nil, nil)
        case .failed:
            return ("", nil)
        case .loaded(let title, let imageData):
            return (title, imageData.map { Data($0) })
        }
    }

    /// Check if metadata has any content
    public var hasContent: Bool {
        if case .loaded(let title, let imageData) = self {
            return title != nil || imageData != nil
        }
        return false
    }
}

// MARK: - Protocol Conformances
// SYNC: Add Sendable conformance for any new type added to clipkitty_core.udl
// Types from .udl: ClipboardItem, ClipboardContent, LinkMetadataState,
//                  FetchResult, SearchResult, SearchMatch, HighlightRange, ClipboardStore

extension ClipboardItem: Identifiable {}

// Sendable conformances - Rust ClipboardStore uses internal locking (RwLock)
// See: rust-core/src/store.rs lines 313-314 for Send+Sync impl
extension ClipboardItem: @unchecked Sendable {}
extension ClipboardContent: @unchecked Sendable {}
extension LinkMetadataState: @unchecked Sendable {}
extension FetchResult: @unchecked Sendable {}       // .udl lines 58-61
extension SearchResult: @unchecked Sendable {}      // .udl lines 52-55
extension SearchMatch: @unchecked Sendable {}       // .udl lines 46-49
extension HighlightRange: @unchecked Sendable {}    // .udl lines 40-43
extension ClipboardStore: @unchecked Sendable {}    // .udl lines 73-121
