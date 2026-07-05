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

    /// An image clip surrounded by text gets its own row rather than being
    /// pulled next to a distant image (which would reorder the feed).
    func testImageBetweenTextsBecomesSoloRow() {
        let rows = [textRow("t1"), imageRow("i1"), textRow("t2")]

        let chunks = CardRowChunk.pack(rows, rowWidth: rowWidth)

        XCTAssertEqual(chunks.map { $0.rows.map(\.id) }, [["t1"], ["i1"], ["t2"]])
    }

    /// Adjacent image clips share a media row.
    func testAdjacentImagesShareARow() {
        let rows = [imageRow("i1"), imageRow("i2"), textRow("t1")]

        let chunks = CardRowChunk.pack(rows, rowWidth: rowWidth)

        XCTAssertEqual(chunks.map { $0.rows.map(\.id) }, [["i1", "i2"], ["t1"]])
    }

    /// Rows never mix media and text cards, and never exceed the cap.
    func testRowsAreFamilyHomogeneousAndCapped() {
        let rows = [
            textRow("t1"), textRow("t2"), textRow("t3"), textRow("t4"),
            imageRow("i1"), imageRow("i2"), imageRow("i3"), imageRow("i4"),
        ]

        let chunks = CardRowChunk.pack(rows, rowWidth: rowWidth)

        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.rows.count, JustifiedCardRow.maxCardsPerRow)
            let families = Set(chunk.rows.map { CardRowFamily(row: $0) == .media })
            XCTAssertEqual(families.count, 1, "row mixes media and text cards")
        }
    }
}
