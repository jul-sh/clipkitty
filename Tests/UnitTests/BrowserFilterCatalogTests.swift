@testable import ClipKittyBrowser
import ClipKittyRust
import XCTest

final class BrowserFilterCatalogTests: XCTestCase {
    private let catalog = BrowserFilterCatalog(includesFileItems: true)
    private let catalogWithoutFiles = BrowserFilterCatalog(includesFileItems: false)

    // MARK: - Catalog contents

    func testSelectableFiltersExcludeAllAndGateFiles() {
        XCTAssertEqual(
            catalog.selectableFilters.map(\.kind),
            [.bookmarks, .text, .images, .links, .colors, .files]
        )
        XCTAssertEqual(
            catalogWithoutFiles.selectableFilters.map(\.kind),
            [.bookmarks, .text, .images, .links, .colors]
        )
    }

    func testQueryFilterMappings() {
        XCTAssertEqual(catalog.descriptor(for: .all).queryFilter, .all)
        XCTAssertEqual(catalog.descriptor(for: .bookmarks).queryFilter, .tagged(tag: .bookmark))
        XCTAssertEqual(catalog.descriptor(for: .text).queryFilter, .contentType(contentType: .text))
        XCTAssertEqual(catalog.descriptor(for: .images).queryFilter, .contentType(contentType: .images))
        XCTAssertEqual(catalog.descriptor(for: .links).queryFilter, .contentType(contentType: .links))
        XCTAssertEqual(catalog.descriptor(for: .colors).queryFilter, .contentType(contentType: .colors))
        XCTAssertEqual(catalog.descriptor(for: .files).queryFilter, .contentType(contentType: .files))
    }

    func testAppliedDescriptorLookup() {
        XCTAssertNil(catalog.appliedDescriptor(for: .all), "Unfiltered search renders no chip")
        XCTAssertEqual(catalog.appliedDescriptor(for: .tagged(tag: .bookmark))?.kind, .bookmarks)
        XCTAssertEqual(catalog.appliedDescriptor(for: .contentType(contentType: .images))?.kind, .images)
        XCTAssertNil(
            catalogWithoutFiles.appliedDescriptor(for: .contentType(contentType: .files)),
            "Platforms without file items render no chip for a files filter"
        )
    }

    /// Automation rule: English aliases work in EVERY locale, so screenshot
    /// and intro-video flows type the same trigger regardless of locale. A
    /// failure here means the automation contract broke.
    func testCanonicalEnglishAliasesAreAlwaysPresent() {
        let expected: [BrowserFilterKind: String] = [
            .bookmarks: "bookmarks",
            .text: "text",
            .images: "images",
            .links: "links",
            .colors: "colors",
            .files: "files",
        ]
        for (kind, alias) in expected {
            XCTAssertTrue(
                catalog.descriptor(for: kind).searchAliases.contains(alias),
                "\(kind) lost its canonical English alias '\(alias)'"
            )
        }
    }

    func testLocalizedTitleIsAnAlias() {
        for descriptor in catalog.selectableFilters {
            XCTAssertTrue(
                descriptor.searchAliases.contains(descriptor.title.lowercased()),
                "\(descriptor.kind) must match its display title"
            )
        }
    }

    /// Guards the determinism of typed matching: no two filters may share a
    /// two-character alias prefix, otherwise short triggers turn ambiguous
    /// and stop surfacing.
    func testNoTwoFiltersShareATwoCharacterAliasPrefix() {
        var owners: [String: BrowserFilterKind] = [:]
        for descriptor in catalog.selectableFilters {
            for alias in descriptor.searchAliases where alias.count >= 2 {
                let prefix = String(alias.prefix(2))
                if let owner = owners[prefix], owner != descriptor.kind {
                    XCTFail("Prefix '\(prefix)' is claimed by both \(owner) and \(descriptor.kind)")
                }
                owners[prefix] = descriptor.kind
            }
        }
    }

    // MARK: - Typed suggestion resolution

    /// Exercises the ambiguity rule directly. The shipping English alias set
    /// deliberately has no cross-kind prefix collisions (guarded above), so
    /// this uses the internal test seam with synthetic descriptors — the rule
    /// still matters for localized titles, which can collide in any locale.
    func testAmbiguousPrefixDoesNotSurfaceASuggestion() {
        let tags = BrowserFilterDescriptor(
            kind: .links,
            queryFilter: .contentType(contentType: .links),
            title: "Tags",
            identifierSuffix: "tags",
            symbolName: "tag",
            searchAliases: ["tags"]
        )
        let tables = BrowserFilterDescriptor(
            kind: .colors,
            queryFilter: .contentType(contentType: .colors),
            title: "Tables",
            identifierSuffix: "tables",
            symbolName: "tablecells",
            searchAliases: ["tables"]
        )
        let ambiguous = BrowserFilterCatalog(selectableFilters: [tags, tables])

        XCTAssertNil(
            ambiguous.typedSuggestion(searchText: "ta", appliedFilter: .all),
            "A prefix matching aliases of two filter kinds must surface nothing"
        )
        // One more character disambiguates and the suggestion returns.
        XCTAssertEqual(ambiguous.typedSuggestion(searchText: "tag", appliedFilter: .all)?.kind, .links)
        XCTAssertEqual(ambiguous.typedSuggestion(searchText: "tab", appliedFilter: .all)?.kind, .colors)
    }

    func testUniquePrefixSurfacesSuggestion() {
        let suggestion = catalog.typedSuggestion(searchText: "ima", appliedFilter: .all)
        XCTAssertEqual(suggestion?.kind, .images)
        XCTAssertEqual(suggestion?.matchedToken, "ima")
        XCTAssertEqual(suggestion?.remainingSearchText, "")
    }

    func testSingleCharacterDoesNotSurface() {
        XCTAssertNil(catalog.typedSuggestion(searchText: "i", appliedFilter: .all))
    }

    func testNonMatchingTokenDoesNotSurface() {
        XCTAssertNil(catalog.typedSuggestion(searchText: "important", appliedFilter: .all))
        XCTAssertNil(catalog.typedSuggestion(searchText: "docker", appliedFilter: .all))
    }

    func testOnlyLastTokenTriggers() {
        XCTAssertNil(
            catalog.typedSuggestion(searchText: "image docker", appliedFilter: .all),
            "Earlier tokens must never trigger"
        )
        let suggestion = catalog.typedSuggestion(searchText: "docker image", appliedFilter: .all)
        XCTAssertEqual(suggestion?.kind, .images)
        XCTAssertEqual(suggestion?.matchedToken, "image")
        XCTAssertEqual(suggestion?.remainingSearchText, "docker")
    }

    func testCommitConsumesOnlyTriggerTokenAndTrailingWhitespace() {
        let suggestion = catalog.typedSuggestion(searchText: "a  b   image  ", appliedFilter: .all)
        XCTAssertEqual(suggestion?.remainingSearchText, "a  b", "Inner whitespace is preserved verbatim")
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(catalog.typedSuggestion(searchText: "IMA", appliedFilter: .all)?.kind, .images)
        XCTAssertEqual(catalog.typedSuggestion(searchText: "Book", appliedFilter: .all)?.kind, .bookmarks)
    }

    func testSynonymAliasesResolve() {
        XCTAssertEqual(catalog.typedSuggestion(searchText: "photo", appliedFilter: .all)?.kind, .images)
        XCTAssertEqual(catalog.typedSuggestion(searchText: "pictures", appliedFilter: .all)?.kind, .images)
        XCTAssertEqual(catalog.typedSuggestion(searchText: "pics", appliedFilter: .all)?.kind, .images)
        XCTAssertEqual(catalog.typedSuggestion(searchText: "url", appliedFilter: .all)?.kind, .links)
        XCTAssertEqual(catalog.typedSuggestion(searchText: "https", appliedFilter: .all)?.kind, .links)
        XCTAssertEqual(catalog.typedSuggestion(searchText: "favorite", appliedFilter: .all)?.kind, .bookmarks)
    }

    func testNoSuggestionSurfacesWhileAnyFilterIsApplied() {
        XCTAssertNil(catalog.typedSuggestion(
            searchText: "images",
            appliedFilter: .contentType(contentType: .images)
        ))
        // One filter at a time: a DIFFERENT filter's alias is also silent
        // until the applied chip is removed.
        XCTAssertNil(catalog.typedSuggestion(
            searchText: "links",
            appliedFilter: .contentType(contentType: .images)
        ))
        XCTAssertNil(catalog.typedSuggestion(
            searchText: "links",
            appliedFilter: .tagged(tag: .bookmark)
        ))
    }

    func testFilesAliasRequiresAvailability() {
        XCTAssertEqual(catalog.typedSuggestion(searchText: "files", appliedFilter: .all)?.kind, .files)
        XCTAssertNil(catalogWithoutFiles.typedSuggestion(searchText: "files", appliedFilter: .all))
    }

    func testEmptyAndWhitespaceTextDoesNotSurface() {
        XCTAssertNil(catalog.typedSuggestion(searchText: "", appliedFilter: .all))
        XCTAssertNil(catalog.typedSuggestion(searchText: "   ", appliedFilter: .all))
    }
}
