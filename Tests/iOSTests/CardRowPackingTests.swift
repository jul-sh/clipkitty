@testable import ClipKittyiOS
import ClipKittyRust
import ClipKittyShared
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

    /// Rows never exceed the card cap, even when everything would fit width-wise.
    func testRowsRespectMaxCardsPerRow() {
        let rows = (1 ... 7).map { textRow("t\($0)", text: "hi") }

        let chunks = CardRowChunk.pack(rows, rowWidth: 10000)

        XCTAssertTrue(chunks.allSatisfy { $0.rows.count <= JustifiedCardRow.maxCardsPerRow })
        XCTAssertEqual(chunks.flatMap { $0.rows.map(\.id) }, rows.map(\.id))
    }
}
