import ClipKittyBrowser
@testable import ClipKittyiOS
import ClipKittyRust
import XCTest

final class CardRowPackingTests: XCTestCase {
    private let rowWidth: CGFloat = 1000

    private func textRow(_ id: String, text: String = "short clip") -> DisplayRow {
        DisplayRow(
            metadata: ItemMetadata(
                itemId: id,
                icon: .symbol(iconType: .text),
                sourceApp: nil,
                sourceAppBundleId: nil,
                timestampUnix: 0,
                tags: []
            ),
            presentation: .baseline(excerpt: BaselineExcerpt(text: text))
        )
    }

    private func imageRow(_ id: String) -> DisplayRow {
        DisplayRow(
            metadata: ItemMetadata(
                itemId: id,
                icon: .thumbnail(bytes: Data([0x01])),
                sourceApp: nil,
                sourceAppBundleId: nil,
                timestampUnix: 0,
                tags: []
            ),
            presentation: .baseline(excerpt: BaselineExcerpt(text: ""))
        )
    }

    private func linkRow(_ id: String, url: String = "https://developer.apple.com/documentation/swiftui") -> DisplayRow {
        DisplayRow(
            metadata: ItemMetadata(
                itemId: id,
                icon: .symbol(iconType: .link),
                sourceApp: nil,
                sourceAppBundleId: nil,
                timestampUnix: 0,
                tags: []
            ),
            presentation: .baseline(excerpt: BaselineExcerpt(text: url))
        )
    }

    /// Flattening the packed rows must always reproduce the feed order
    /// exactly; packing may only insert row breaks, never reorder clips.
    func testPackingPreservesFeedOrder() {
        let rows = [
            textRow("t1"), textRow("t2"), imageRow("i1"), textRow("t3"),
            imageRow("i2"), imageRow("i3"), textRow("t4"),
        ]

        let chunks = CardRowChunk.pack(rows, rowWidth: rowWidth)

        XCTAssertEqual(
            chunks.flatMap { $0.rows.map(\.id) },
            rows.map(\.id)
        )
    }

    /// Image clips pack next to adjacent text clips like any other card.
    func testImageSharesRowWithAdjacentText() {
        let rows = [imageRow("i1"), textRow("t1")]

        let chunks = CardRowChunk.pack(rows, rowWidth: rowWidth)

        XCTAssertEqual(chunks.map { $0.rows.map(\.id) }, [["i1", "t1"]])
    }

    /// The iPad-feed scenario that motivated packing slack: a height-capped
    /// image, a bare link, and a one-line text clip fill one row of three
    /// instead of stopping at two with visible spare width.
    func testImageLinkAndShortTextFillOneRow() {
        let rows = [
            imageRow("i1"),
            linkRow("l1"),
            textRow("t1", text: "The quick brown fox jumps over the lazy dog"),
        ]

        let chunks = CardRowChunk.pack(rows, rowWidth: rowWidth)

        XCTAssertEqual(chunks.map { $0.rows.map(\.id) }, [["i1", "l1", "t1"]])
    }

    /// Rows never exceed the card cap, even when everything would fit width-wise.
    func testRowsRespectMaxCardsPerRow() {
        let rows = (1 ... 7).map { textRow("t\($0)", text: "hi") }

        let chunks = CardRowChunk.pack(rows, rowWidth: 10000)

        XCTAssertTrue(chunks.allSatisfy { $0.rows.count <= JustifiedCardRow.maxCardsPerRow })
        XCTAssertEqual(chunks.flatMap { $0.rows.map(\.id) }, rows.map(\.id))
    }
}
