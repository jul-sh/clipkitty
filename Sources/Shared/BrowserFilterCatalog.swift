import ClipKittyRust
import Foundation

/// Semantic identity of a user-facing browser filter.
///
/// `all` is the absence of a filter: it never surfaces as a typed suggestion
/// and never renders as an applied chip; clearing the applied chip returns
/// the browser to `all`.
public enum BrowserFilterKind: String, CaseIterable, Sendable {
    case all
    case bookmarks
    case text
    case images
    case links
    case colors
    case files
}

/// One user-facing filter: presentation metadata, the backend query mapping,
/// and the aliases the typed-filter recognizer matches against.
public struct BrowserFilterDescriptor: Equatable, Sendable {
    public let kind: BrowserFilterKind
    /// The exact filter submitted with `SearchRequest(text:filter:)`.
    public let queryFilter: ItemQueryFilter
    /// Localized display title, e.g. shown in the suggestion and applied chips.
    public let title: String
    /// Stable, locale-invariant suffix for accessibility identifiers.
    public let identifierSuffix: String
    /// SF Symbol name representing the filter.
    public let symbolName: String
    /// Lowercased alias strings the typed-filter recognizer matches by prefix.
    ///
    /// Locale rule: the canonical English aliases are ALWAYS present, in every
    /// locale, so screenshot/video automation and muscle memory stay
    /// locale-invariant; the localized display title is included in addition.
    /// Tests assert the English aliases so this rule cannot silently regress.
    public let searchAliases: [String]
}

/// The single source of truth for user-facing filters on every platform.
///
/// `Files` support is compiled per target (`ENABLE_FILE_CLIPBOARD_ITEMS`), and
/// that flag is not defined for this shared module, so availability is data:
/// each platform constructs the catalog with its own capability.
public struct BrowserFilterCatalog: Sendable {
    /// Filters a user can actively select, in display order.
    /// Excludes `all` (the no-filter state); `files` is gated on availability.
    public let selectableFilters: [BrowserFilterDescriptor]

    public init(includesFileItems: Bool) {
        var descriptors: [BrowserFilterDescriptor] = [
            Self.bookmarks, Self.text, Self.images, Self.links, Self.colors,
        ]
        if includesFileItems {
            descriptors.append(Self.files)
        }
        self.init(selectableFilters: descriptors)
    }

    /// Test seam: lets unit tests exercise resolver rules — most importantly
    /// ambiguity, which the shipping English alias set deliberately cannot
    /// produce — with synthetic descriptor sets.
    init(selectableFilters: [BrowserFilterDescriptor]) {
        self.selectableFilters = selectableFilters
    }

    public func descriptor(for kind: BrowserFilterKind) -> BrowserFilterDescriptor {
        switch kind {
        case .all: return Self.all
        case .bookmarks: return Self.bookmarks
        case .text: return Self.text
        case .images: return Self.images
        case .links: return Self.links
        case .colors: return Self.colors
        case .files: return Self.files
        }
    }

    /// The descriptor for an active query filter, or nil when no chip should
    /// render (`all`, or a filter this platform cannot select).
    public func appliedDescriptor(for filter: ItemQueryFilter) -> BrowserFilterDescriptor? {
        selectableFilters.first { $0.queryFilter == filter }
    }

    // MARK: - Descriptors

    private static let all = BrowserFilterDescriptor(
        kind: .all,
        queryFilter: .all,
        title: String(localized: "All"),
        identifierSuffix: "all",
        symbolName: "clock.arrow.trianglehead.counterclockwise.rotate.90",
        searchAliases: []
    )

    private static let bookmarks = BrowserFilterDescriptor(
        kind: .bookmarks,
        queryFilter: .tagged(tag: .bookmark),
        title: String(localized: "Bookmarks"),
        identifierSuffix: "bookmarks",
        symbolName: "bookmark.fill",
        searchAliases: aliases(["bookmarks", "bookmark", "favorites", "favourites", "saved"], title: String(localized: "Bookmarks"))
    )

    private static let text = BrowserFilterDescriptor(
        kind: .text,
        queryFilter: .contentType(contentType: .text),
        title: String(localized: "Text"),
        identifierSuffix: "text",
        symbolName: "doc.text",
        searchAliases: aliases(["text"], title: String(localized: "Text"))
    )

    private static let images = BrowserFilterDescriptor(
        kind: .images,
        queryFilter: .contentType(contentType: .images),
        title: String(localized: "Images"),
        identifierSuffix: "images",
        symbolName: "photo",
        searchAliases: aliases(["images", "image", "photos", "photo", "pictures", "picture", "pics"], title: String(localized: "Images"))
    )

    private static let links = BrowserFilterDescriptor(
        kind: .links,
        queryFilter: .contentType(contentType: .links),
        title: String(localized: "Links"),
        identifierSuffix: "links",
        symbolName: "link",
        searchAliases: aliases(["links", "link", "urls", "url", "https"], title: String(localized: "Links"))
    )

    private static let colors = BrowserFilterDescriptor(
        kind: .colors,
        queryFilter: .contentType(contentType: .colors),
        title: String(localized: "Colors"),
        identifierSuffix: "colors",
        symbolName: "paintpalette",
        searchAliases: aliases(["colors", "color", "colours", "colour"], title: String(localized: "Colors"))
    )

    private static let files = BrowserFilterDescriptor(
        kind: .files,
        queryFilter: .contentType(contentType: .files),
        title: String(localized: "Files"),
        identifierSuffix: "files",
        symbolName: "folder",
        searchAliases: aliases(["files", "file", "documents", "document"], title: String(localized: "Files"))
    )

    /// English aliases plus the lowercased localized title, deduplicated while
    /// preserving order.
    private static func aliases(_ english: [String], title: String) -> [String] {
        var seen = Set<String>()
        return (english + [title.lowercased()]).filter { seen.insert($0).inserted }
    }
}

// MARK: - Typed-filter recognition

/// A filter suggestion resolved from the raw search text, surfaced as the
/// pending chip above the results list.
public struct TypedFilterSuggestion: Equatable, Sendable {
    public let kind: BrowserFilterKind
    /// The whitespace-delimited token, as typed, that triggered the match.
    public let matchedToken: String
    /// The search text with the trigger token (and its leading whitespace)
    /// removed — this becomes the query when the suggestion is committed, so
    /// applying a filter never consumes unrelated search text.
    public let remainingSearchText: String

    public init(kind: BrowserFilterKind, matchedToken: String, remainingSearchText: String) {
        self.kind = kind
        self.matchedToken = matchedToken
        self.remainingSearchText = remainingSearchText
    }
}

extension BrowserFilterCatalog {
    /// Minimum typed length before a suggestion surfaces. Single characters
    /// are too eager: nearly every query starts with a letter that prefixes
    /// some alias.
    private static let minimumTriggerLength = 2

    /// Resolves the pending filter suggestion for the current search state.
    ///
    /// Deterministic rules, in order:
    /// 1. Only one filter at a time: while ANY filter is applied, nothing is
    ///    suggested — the user removes the chip before choosing another.
    /// 2. The trigger token is the LAST whitespace-separated token of the raw
    ///    text; earlier tokens are never consumed.
    /// 3. The token must be at least ``minimumTriggerLength`` characters.
    /// 4. Matching is case-insensitive prefix matching over each descriptor's
    ///    ``BrowserFilterDescriptor/searchAliases``.
    /// 5. The match must be unambiguous: tokens matching aliases of more than
    ///    one filter kind produce no suggestion.
    public func typedSuggestion(searchText: String, appliedFilter: ItemQueryFilter) -> TypedFilterSuggestion? {
        guard appliedFilter == .all else { return nil }
        guard let token = searchText.split(whereSeparator: \.isWhitespace).last,
              token.count >= Self.minimumTriggerLength
        else {
            return nil
        }

        let needle = token.lowercased()
        let matches = selectableFilters.filter { descriptor in
            descriptor.searchAliases.contains { $0.hasPrefix(needle) }
        }
        guard let match = matches.first, matches.count == 1 else { return nil }

        var remaining = searchText[...]
        while remaining.last?.isWhitespace == true {
            remaining = remaining.dropLast()
        }
        remaining = remaining.dropLast(token.count)
        while remaining.last?.isWhitespace == true {
            remaining = remaining.dropLast()
        }

        return TypedFilterSuggestion(
            kind: match.kind,
            matchedToken: String(token),
            remainingSearchText: String(remaining)
        )
    }
}
